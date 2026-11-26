import PDDL
import SymbolicPlanners

function deterministic_fragment(model,belief)
    length(belief) == 1 || return nothing
    edges = NamedTuple[]
    for source in sort!(collect(model.states);by=repr)
        for action in sort!(collect(get(model.enabled,source,Set()));by=repr)
            scope = get(model.effects,(source,action),nothing)
            !isnothing(scope) && scope.domain == proven && scope.complete &&
                length(scope.states) == 1 || return nothing
            target = only(scope.states)
            target in model.states || throw(ArgumentError("A planning successor escaped its domain"))
            labels = get(model.observations,target,nothing)
            !isnothing(labels) && length(labels) == 1 || return nothing
            push!(edges,(;source,action,target,label=only(labels),reads=scope.dependencies))
        end
    end
    return edges
end

function deterministic_pddl_plan(model,belief,goals)
    edges = deterministic_fragment(model,belief)
    isnothing(edges) && return nothing
    root = only(belief)
    states = sort!(collect(model.states);by=repr)
    names = Dict(state => "s" * string(i) for (i,state) in enumerate(states))
    at(s) = "(" * names[s] * ")"
    actions = Dict{Symbol,NamedTuple}()
    declarations = String[]
    for (i,edge) in enumerate(edges)
        name = "step" * string(i)
        actions[Symbol(name)] = edge
        from,to = at(edge.source),at(edge.target)
        changes = from == to ? "" : "(not " * from * ") " * to
        goal = edge.target in goals ? "(achieved)" :
            edge.source in goals ? "(not (achieved))" : ""
        push!(declarations,"(:action $name :parameters () :precondition $from :effect (and $changes $goal))")
    end
    predicates = join(at.(states)," ")
    domain = PDDL.parse_domain(
        "(define (domain finite-relation) (:requirements :strips) " *
        "(:predicates $predicates (achieved)) $(join(declarations," ")))")
    initial = root in goals ? "$(at(root)) (achieved)" : at(root)
    problem = PDDL.parse_problem(
        "(define (problem relation-task) (:domain finite-relation) (:init $initial) (:goal (achieved)))")
    state = PDDL.initstate(domain,problem)
    planner = SymbolicPlanners.BreadthFirstPlanner()
    solution = planner(domain,state,SymbolicPlanners.MinStepsGoal(problem))
    solution.status == :success || return (;status=solution.status,path=NamedTuple[])
    path = NamedTuple[]
    cursor = root
    for action in solution.plan
        PDDL.available(domain,state,action) || error("Planner returned an unavailable action")
        edge = actions[action.name]
        edge.source == cursor || error("Planner path does not follow the typed transition")
        state = PDDL.transition(domain,state,action)
        PDDL.satisfy(domain,state,PDDL.parse_pddl(at(edge.target))) ||
            error("Planner successor did not satisfy its encoded output state")
        push!(path,edge)
        cursor = edge.target
    end
    cursor in goals && PDDL.satisfy(domain,state,PDDL.get_goal(problem)) ||
        error("Planner path did not establish its declared goal")
    return (;status=:success,path)
end

function policy_from_deterministic_plan(model::PlanningModel{S,A,O},belief,goals) where {S,A,O}
    result = deterministic_pddl_plan(model,belief,goals)
    isnothing(result) && return nothing
    result.status == :success || return (;status="no_policy_in_scope",policy=nothing,work=0)
    path = result.path
    target = isempty(path) ? only(belief) : last(path).target
    node = PolicyNode{S,A,O}(Set([target]),nothing,Dict(),Dict())
    for edge in Iterators.reverse(path)
        dependencies = merge(node.dependencies,Dict(ref=>model.versions[ref] for ref in edge.reads))
        node = PolicyNode{S,A,O}(Set([edge.source]),edge.action,Dict(edge.label=>node),dependencies)
    end
    return (status=isempty(path) ? "achieved" : "policy",policy=node,work=length(path),
        rank=length(path),backend="symbolic_planners")
end
