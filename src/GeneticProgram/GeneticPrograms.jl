
module GeneticPrograms

using ExprRules
using StatsBase, Random

using ExprOptimization: ExprOptAlgorithm, ExprOptResult, BoundedPriorityQueue, enqueue!
import ExprOptimization: optimize

export GeneticProgram

const OPERATORS = [:reproduction, :crossover, :mutation]

abstract type InitializationMethod end 
abstract type SelectionMethod end
abstract type TrackingMethod end

"""
    GeneticProgram

Genetic Programming.
# Arguments
- `pop_size::Int`: population size
- `iterations::Int`: number of iterations
- `max_depth::Int`: maximum depth of derivation tree
- `p_reproduction::Float64`: probability of reproduction operator
- `p_crossover::Float64`: probability of crossover operator
- `p_mutation::Float64`: probability of mutation operator
- `init_method::InitializationMethod`: initialization method
- `select_method::SelectionMethod`: selection method
- `track_method::TrackingMethod`: additional tracking, e.g., track top k exprs (default: no additional tracking) 
"""
struct GeneticProgram <: ExprOptAlgorithm
    pop_size::Int
    iterations::Int
    max_depth::Int
    p_operators::Weights
    init_method::InitializationMethod
    select_method::SelectionMethod
    track_method::TrackingMethod

    function GeneticProgram(
        pop_size::Int,                          #population size 
        iterations::Int,                        #number of generations 
        max_depth::Int,                         #maximum depth of derivation tree
        p_reproduction::Float64,                #probability of reproduction operator 
        p_crossover::Float64,                   #probability of crossover operator
        p_mutation::Float64;                    #probability of mutation operator 
        init_method::InitializationMethod=RandomInit(),      #initialization method 
        select_method::SelectionMethod=TournamentSelection(),   #selection method 
        track_method::TrackingMethod=NoTracking())   #tracking method 

        p_operators = Weights([p_reproduction, p_crossover, p_mutation])
        new(pop_size, iterations, max_depth, p_operators, init_method, select_method, track_method)
    end
end

"""
    RandomInit

Uniformly random initialization method.
"""
struct RandomInit <: InitializationMethod end

"""
    TournamentSelection

Tournament selection method with tournament size k.
"""
struct TournamentSelection <: SelectionMethod 
    k::Int
end
TournamentSelection() = TournamentSelection(2)

"""
    TruncationSelection

Truncation selection method keeping the top k individuals 
"""
struct TruncationSelection <: SelectionMethod 
    k::Int 
end
TruncationSelection() = TruncationSelection(100)

"""
    NoTracking

No additional tracking of expressions.
"""
struct NoTracking <: TrackingMethod end

"""
    TopKTracking

Track the top k expressions.
"""
struct TopKTracking <: TrackingMethod 
    k::Int
    q::BoundedPriorityQueue{RuleNode,Float64}

    function TopKTracking(k::Int)
        q = BoundedPriorityQueue{RuleNode,Float64}(k,Base.Order.Reverse) #lower is better
        obj = new(k, q)
        obj
    end
end

"""
    optimize(p::GeneticProgram, grammar::Grammar, typ::Symbol, loss::Function; kwargs...)

Expression tree optimization using genetic programming with parameters p, grammar 'grammar', and start symbol typ, and loss function 'loss'.  Loss function has the form: los::Float64=loss(node::RuleNode, grammar::Grammar).
"""
function optimize(p::GeneticProgram, grammar::Grammar, typ::Symbol, loss::Function; kwargs...) 
    genetic_program(p, grammar, typ, loss; kwargs...)
end

"""
    genetic_program(p::GeneticProgram, grammar::Grammar, typ::Symbol, loss::Function)

Strongly-typed genetic programming with parameters p, grammar 'grammar', start symbol typ, and loss function 'loss'. Loss funciton has the form: los::Float64=loss(node::RuleNode, grammar::Grammar). 
    
See: Montana, "Strongly-typed genetic programming", Evolutionary Computation, Vol 3, Issue 2, 1995.
Koza, "Genetic programming: on the programming of computers by means of natural selection", MIT Press, 1992 

Three operators are implemented: reproduction, crossover, and mutation.
"""
function genetic_program(p::GeneticProgram, grammar::Grammar, typ::Symbol, loss::Function; 
    verbose::Bool=false)
    dmap = mindepth_map(grammar)
    pop0 = initialize(p.init_method, p.pop_size, grammar, typ, dmap, p.max_depth)
    pop1 = Vector{RuleNode}(undef,p.pop_size)
    losses0 = Vector{Union{Float64,Missing}}(missing,p.pop_size)
    losses1 = Vector{Union{Float64,Missing}}(missing,p.pop_size)

    best_tree, best_loss = evaluate!(p, loss, grammar, pop0, losses0, pop0[1], Inf)
    for iter = 1:p.iterations
        verbose && println("iterations: $i of $(p.iterations)")
        fill!(losses1, missing)
        i = 0
        while i < p.pop_size
            op = sample(OPERATORS, p.p_operators)
            if op == :reproduction
                ind1,j = select(p.select_method, pop0, losses0)
                pop1[i+=1] = ind1
                losses1[i] = losses0[j]
            elseif op == :crossover
                ind1,_ = select(p.select_method, pop0, losses0)
                ind2,_ = select(p.select_method, pop0, losses0)
                child = crossover(ind1, ind2, grammar, p.max_depth)
                pop1[i+=1] = child
            elseif op == :mutation
                ind1,_ = select(p.select_method, pop0, losses0)
                child1 = mutation(ind1, grammar, dmap, p.max_depth)
                pop1[i+=1] = child1
            end
        end
        pop0, pop1 = pop1, pop0
        losses0, losses1 = losses1, losses0
        best_tree, best_loss = evaluate!(p, loss, grammar, pop0, losses0, best_tree, best_loss)
    end
    alg_result = Dict{Symbol,Any}()
    _add_result!(alg_result, p.track_method)
    ExprOptResult(best_tree, best_loss, get_executable(best_tree, grammar), alg_result)
end

"""
    _add_result!(d::Dict{Symbol,Any}, t::NoTracking)

Add tracking results to alg_result.  No op for NoTracking.
"""
_add_result!(d::Dict{Symbol,Any}, t::NoTracking) = nothing
"""
    _add_result!(d::Dict{Symbol,Any}, t::TopKTracking)

Add tracking results to alg_result. 
"""
function _add_result!(d::Dict{Symbol,Any}, t::TopKTracking)
    d[:top_k] = collect(t.q)
    d
end

"""
    initialize(::RandomInit, pop_size::Int, grammar::Grammar, typ::Symbol, dmap::AbstractVector{Int}, 
max_depth::Int)

Random population initialization.
"""
function initialize(::RandomInit, pop_size::Int, grammar::Grammar, typ::Symbol, 
    dmap::AbstractVector{Int}, max_depth::Int)
    [rand(RuleNode, grammar, typ, dmap, max_depth) for i = 1:pop_size]
end

"""
    select(p::TournamentSelection, pop::Vector{RuleNode}, losses::Vector{Union{Float64,Missing}})

Tournament selection.
"""
function select(p::TournamentSelection, pop::Vector{RuleNode}, 
    losses::Vector{Union{Float64,Missing}})
    ids = StatsBase.sample(1:length(pop), p.k; replace=false, ordered=true) 
    i = ids[1] #assumes pop is sorted
    pop[i], i
end

"""
    select(p::TruncationSelection, pop::Vector{RuleNode}, losses::Vector{Union{Float64,Missing}})

Truncation selection.
"""
function select(p::TruncationSelection, pop::Vector{RuleNode}, 
    losses::Vector{Union{Float64,Missing}})
    i = rand(1:p.k)  #assumes pop is sorted
    pop[i], i
end

"""
    evaluate!(p::GeneticProgram, loss::Function, grammar::Grammar, pop::Vector{RuleNode}, losses::Vector{Union{Float64,Missing}}, 
        best_tree::RuleNode, best_loss::Float64)

Evaluate the loss function for population and sort.  Update the globally best tree, if needed.
"""
function evaluate!(p::GeneticProgram, loss::Function, grammar::Grammar, pop::Vector{RuleNode}, 
    losses::Vector{Union{Float64,Missing}}, best_tree::RuleNode, best_loss::Float64)

    for i in eachindex(pop) 
        if ismissing(losses[i])
            losses[i] = loss(pop[i], grammar)
        end
    end
    perm = sortperm(losses)
    pop[:], losses[:] = pop[perm], losses[perm]
    if losses[1] < best_loss
        best_tree, best_loss = pop[1], losses[1]
    end
    _update_tracker!(p.track_method, pop, losses)
    (best_tree, best_loss)
end

"""
    _update_tracker!(t::NoTracking, pop::Vector{RuleNode}, losses::Vector{Union{Float64,Missing}}) 

Update the tracker.  No op for NoTracking.
"""
function _update_tracker!(t::NoTracking, pop::Vector{RuleNode}, 
    losses::Vector{Union{Float64,Missing}}) 
    nothing
end
"""
    _update_tracker!(t::TopKTracking, pop::Vector{RuleNode}, losses::Vector{Union{Float64,Missing}})

Update the tracker.  Track top k expressions. 
"""
function _update_tracker!(t::TopKTracking, pop::Vector{RuleNode}, 
    losses::Vector{Union{Float64,Missing}})
    n = 0
    for i = 1:length(pop)
        r = enqueue!(t.q, pop[i], losses[i])
        r >= 0 && (n += 1) #no clash, increment counter
        n >= t.k && break 
    end
end

"""
    crossover(a::RuleNode, b::RuleNode, grammar::Grammar)

Crossover genetic operator.  Pick a random node from 'a', then pick a random node from 'b' that has the same type, then replace the subtree 
"""
function crossover(a::RuleNode, b::RuleNode, grammar::Grammar, max_depth::Int=typemax(Int))
    child = deepcopy(a)
    crosspoint = sample(b)
    typ = return_type(grammar, crosspoint.ind)
    d_subtree = depth(crosspoint)
    d_max = max_depth + 1 - d_subtree 
    if d_max > 0 && contains_returntype(child, grammar, typ, d_max)
        loc = sample(NodeLoc, child, typ, grammar, d_max)
        insert!(child, loc, deepcopy(crosspoint))
    end
    child 
end

"""
    mutation(a::RuleNode, grammar::Grammar, dmap::AbstractVector{Int}, max_depth::Int=5)

Mutation genetic operator.  Pick a random node from 'a', then replace the subtree with a random one.
"""
function mutation(a::RuleNode, grammar::Grammar, dmap::AbstractVector{Int}, max_depth::Int=5)
    child = deepcopy(a)
    loc = sample(NodeLoc, child)
    mutatepoint = get(child, loc) 
    typ = return_type(grammar, mutatepoint.ind)
    d_node = node_depth(child, mutatepoint)
    d_max = max_depth + 1 - d_node
    if d_max > 0
        subtree = rand(RuleNode, grammar, typ, dmap, d_max)
        insert!(child, loc, subtree)
    end
    child
end

end #module
