using Gurobi, JuMP
include("inner_op.jl")

getthreads() = haskey(ENV, "SLURM_JOB_CPUS_PER_NODE") ? parse(Int, ENV["SLURM_JOB_CPUS_PER_NODE"]) : 0

###########################
# FUNCTION oa_formulation
###########################
"""Computes the minimum regression error with Ridge regularization subject an explicit
cardinality constraint using cutting-planes.

w^* := arg min  ∑_i ℓ(y_i, x_i^T w) +1/(2γ) ||w||^2
           st.  ||w||_0 = k

INPUTS
  ℓ           - LossFunction to use
  Y           - Vector of outputs. For classification, use ±1 labels
  X           - Array of inputs
  k           - Sparsity parameter
  γ           - ℓ2-regularization parameter
  indices0    - (optional) Initial solution
  ΔT_max      - (optional) Maximum running time in seconds for the MIP solver. Default is 60s
  gap         - (optional) MIP solver accuracy

OUTPUT
  indices     - Indicates which features are used as regressors
  w           - Regression coefficients
  Δt          - Computational time (in seconds)
  status      - Solver status at termination
  Gap         - Optimality gap at termination
  cutCount    - Number of cuts needed in the cutting-plane algorithm
  """
function oa_formulation(ℓ::LossFunction, Y, X, k::Int, γ::Float64;
          indices0=find(x-> x<k/size(X,2), rand(size(X,2))), ΔT_max=60, Gap=0e-3)

  n = size(Y, 1)
  p = size(X, 2)
  #Info array
  # bbdata = Array[]

  miop = Model(solver=GurobiSolver(MIPGap=Gap, TimeLimit=ΔT_max,
                OutputFlag=0, LazyConstraints=1, Threads=getthreads()))

  s0 = zeros(p); s0[indices0]=1
  c0, ∇c0 = inner_op(ℓ, Y, X, s0, γ)

  # Optimization variables
  # @variable(miop, s[j=1:p], Bin)
  @variable(miop, s[j=1:p], Bin, start=s0[j])
  @variable(miop, t>=0)

  # Objective
  @objective(miop, Min, t)

  # Constraints
  @constraint(miop, sum(s)<=k)

  cutCount=1; bestObj=c0; bestSolution=s0[:];
  @constraint(miop, t>= c0 + dot(∇c0, s-s0))

  # Outer approximation method for Convex Integer Optimization (CIO)
  function outer_approximation(cb)
    cutCount += 1
    c, ∇c = inner_op(ℓ, Y, X, getvalue(s), γ)
    if c<bestObj
      bestObj = c; bestSolution=getvalue(s)[:]
    end
    @lazyconstraint(cb, t>=c + dot(∇c, s-getvalue(s)))
  end
  addlazycallback(miop, outer_approximation)

  # # Information saving
  # function infocallback(cb)
  #     node      = MathProgBase.cbgetexplorednodes(cb)
  #     obj       = MathProgBase.cbgetobj(cb)
  #     bestbound = MathProgBase.cbgetbestbound(cb)
  #     push!(bbdata, Array([node, obj, bestbound]))
  # end
  # addinfocallback(miop, infocallback, when = :Intermediate)

  tic()
  status = solve(miop)
  Δt = toc()

  if status != :Optimal
    Gap = 1 - getobjectivebound(miop) /  getobjectivevalue(miop)
  end

  if status == :Optimal
    bestSolution = getvalue(s)[:]
  end
  # Find selected regressors and run a standard linear regression with Tikhonov
  # regularization
  indices = find(s->s>0.5, bestSolution)
  w = recover_primal(ℓ, Y, X[:, indices], γ)

  gc()

  return indices, w, Δt, status, Gap, cutCount
end