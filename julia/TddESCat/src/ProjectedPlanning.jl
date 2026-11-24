const ConcreteAction = Tuple{Int,Int,Int}

struct ObservedGoal
    role_color::UInt8
    role_geometry::Vector{Pixel}
    marker::MotionShape
    cue_color::Union{Nothing,UInt8}
    pixel_distance::Int
end

function bind_observed_goal(frame, config)
    groups = small_components(frame)
    roles = filter(s -> first(s)[3] == config["role_color"], groups)
    marks = filter(s -> first(s)[3] == config["marker_color"], groups)
    length(roles) == length(marks) == 1 || return nothing
    cue = get(config,"cue_color",nothing)
    marker = only(marks)
    distance = 1 + get(config,"marker_gap",0)*support_grid(marker).unit
    return ObservedGoal(first(only(roles))[3],geometry(only(roles)),marker,
        isnothing(cue) ? nothing : UInt8(cue),distance)
end

function goal_truth(goal::ObservedGoal, frame)
    groups = small_components(frame)
    goal.marker in groups || return unknown_truth
    roles = filter(s -> first(s)[3] == goal.role_color && geometry(s) == goal.role_geometry, groups)
    length(roles) == 1 || return unknown_truth
    !isnothing(goal.cue_color) && goal.cue_color ∉ frame && return disproven
    nearby = any(abs(x-u)+abs(y-v) <= goal.pixel_distance
        for (x,y,_) in goal.marker for (u,v,_) in only(roles))
    return nearby ? proven : disproven
end

function project_frame(choice, before)
    rule = choice.model.rule
    patch = rule.patch
    (isnothing(patch) || !choice.model.condition.complete) && return nothing
    size(before) == patch.shape || return nothing
    moved = filter(part -> part.family == :translation, choice.fragments)
    shift = (0,0)
    if !isempty(moved)
        offsets = [part.value .- source for (part,source) in zip(moved,rule.anchors)]
        length(offsets) == length(moved) == length(rule.anchors) || return nothing
        allequal(offsets) || return nothing
        shift = first(moved).value
    end
    target = copy(before)
    touched = Set{Pixel}()
    for (changes,(dx,dy)) in ((patch.moving,shift),(patch.fixed,(0,0)))
        for (u,v,old,new) in changes
            x,y = u+dx,v+dy
            checkbounds(Bool,before,y+1,x+1) && before[y+1,x+1] == old || return nothing
            (x,y) ∉ touched || return nothing
            push!(touched,(x,y))
            target[y+1,x+1] = new
        end
    end
    observed = measure_joint((model=rule,fragments=choice.fragments),target)
    !isempty(observed.assessments) && all(==("supported"),values(observed.assessments)) || return nothing
    return target
end

function compatible_frame_projection(supports, expected, frame)
    matched = nothing
    for choice in supports
        choice.expected == expected || continue
        predicted = project_frame(choice,frame)
        isnothing(predicted) && continue
        if isnothing(matched)
            matched = (choice=choice,frame=predicted,conflict=false)
        elseif predicted != matched.frame
            return (choice=nothing,frame=nothing,conflict=true)
        end
    end
    return isnothing(matched) ? (choice=nothing,frame=nothing,conflict=false) : matched
end

struct ProjectedState
    frame::Matrix{UInt8}
    actions::Vector{Int}
    history::Vector{Int}
end

struct ProjectedEdge
    target::Int
    rule::String
    expected::Dict{String,Any}
end

struct GoalProjection
    model::PlanningModel{Int,ConcreteAction,String}
    states::Vector{ProjectedState}
    edges::Dict{Tuple{Int,ConcreteAction},ProjectedEdge}
    goals::Set{Int}
    gaps::Vector{NamedTuple}
    work::Int
    level::Int
end

struct GoalCursor
    projection::GoalProjection
    node::PolicyNode{Int,ConcreteAction,String}
    root_command::String
    state::Int
    index::DependencyIndex
    definitions::Vector{String}
end

plan_ref(kind, root, state) = "$kind:$root:$state"

function index_observed_policy(projection, node, root)
    index = DependencyIndex()
    state = 1
    prior = nothing
    while !isnothing(node.action)
        binding = plan_ref("binding",root,state)
        relation = plan_ref("relation",root,state)
        condition = plan_ref("condition",root,state)
        if !isnothing(prior)
            track_reads!(index,binding,[prior])
        end
        edge = projection.edges[(state,node.action)]
        track_reads!(index,relation,[binding,edge.rule])
        track_reads!(index,condition,[relation])
        prior = track_reads!(index,plan_ref("pending_action",root,state),[condition])
        state = edge.target
        node = only(values(node.branches))
    end
    return index
end

function goal_invalidation!(cursor::GoalCursor, kind)
    origin = plan_ref(kind,cursor.root_command,cursor.state)
    return Dict("origin"=>origin,"invalidated"=>invalidate_dependents!(cursor.index,[origin]),
        "retained_definitions"=>cursor.definitions)
end

frame_key(frame) = content_hash(vec(frame))
state_key(state) = (frame_key(state.frame), Tuple(state.actions), Tuple(state.history))

function project_goal_model(knowledge, obs, history, goal, limits, match_limit)
    initial = ProjectedState(last(obs.frames),sort(obs.available_actions),copy(history))
    states = [initial]
    ids = Dict{Tuple{String,Tuple,Tuple},Int}(state_key(initial)=>1)
    depths = [0]
    model_versions = Dict(rule.rule.id=>active_id(rule) for rule in knowledge.active)
    enabled = Dict{Int,Set{ConcreteAction}}()
    effects = Dict{Tuple{Int,ConcreteAction},SuccessorScope{Int}}()
    edges = Dict{Tuple{Int,ConcreteAction},ProjectedEdge}()
    goals = Set{Int}()
    gaps = NamedTuple[]
    work = 0
    index = 1
    while index <= length(states)
        state = states[index]
        reached = goal_truth(goal,state.frame)
        if reached == proven
            push!(goals,index)
        elseif depths[index] < limits.depth && work < limits.work
            view = (frames=[state.frame],available_actions=state.actions)
            decision = ranked_public_actions(knowledge,view,state.history,Dict{ConcreteAction,Int}(),
                match_limit; composing=true)
            enabled[index] = Set(action_key(item.action) for item in decision.ranked)
            for item in decision.ranked
                action = action_key(item.action)
                if work == limits.work
                    push!(gaps,(state=index,action,reason="projection_work_limit"))
                    break
                end
                work += 1
                choice = item.chosen
                predicted = item.projection
                if isnothing(predicted)
                    reason = isnothing(choice) ? item.reason : "unproved_frame_projection"
                    push!(gaps,(state=index,action,reason))
                    continue
                end
                advanced = [state.history;action[1]]
                next_history = last(advanced,min(limits.history,length(advanced)))
                after = ProjectedState(predicted,state.actions,next_history)
                key = state_key(after)
                target = get(ids,key,0)
                if target == 0
                    if length(states) == limits.states
                        push!(gaps,(state=index,action,reason="projection_state_limit"))
                        continue
                    end
                    push!(states,after)
                    push!(depths,depths[index]+1)
                    target = ids[key] = length(states)
                end
                rule = choice.model.rule.id
                edges[(index,action)] = ProjectedEdge(target,rule,choice.expected)
                effects[(index,action)] = SuccessorScope(Set([target]),proven,true,Set([rule]))
            end
        else
            reason = work == limits.work ? "projection_work_limit" : "projection_depth_limit"
            push!(gaps,(state=index,action=nothing,reason))
        end
        index += 1
    end
    observations = Dict(i=>Set([frame_key(state.frame)]) for (i,state) in enumerate(states))
    model = PlanningModel(Set(1:length(states)),enabled,effects,observations,model_versions)
    return GoalProjection(model,states,edges,goals,gaps,work,obs.levels_completed)
end

function search_observed_goal(knowledge, obs, history, goal, limits, match_limit, command)
    projection = project_goal_model(knowledge,obs,last(history,min(limits.history,length(history))),
        goal,limits,match_limit)
    remaining = limits.work - projection.work
    remaining > 0 || return (cursor=nothing,projection,status="projection_work_limit",search_work=0)
    solved = solve_policy(projection.model,Set([1]),projection.goals;depth=limits.depth,max_work=remaining)
    cursor = nothing
    if !isnothing(solved.policy) && !isnothing(solved.policy.action)
        index = index_observed_policy(projection,solved.policy,command)
        refs = Set(ref for model in knowledge.active for ref in model.rule.references
            if haskey(solved.policy.dependencies,model.rule.id))
        cursor = GoalCursor(projection,solved.policy,command,1,index,sort!(collect(refs)))
    end
    return (; cursor, projection, solved.status, search_work=solved.work)
end

function live_goal_step(cursor::GoalCursor, knowledge, decision, obs)
    p = cursor.projection
    state = p.states[cursor.state]
    plan_ref("pending_action",cursor.root_command,cursor.state) ∉ cursor.index.invalid ||
        return (reason="invalidated_suffix",item=nothing)
    state.frame == last(obs.frames) && state.actions == sort(obs.available_actions) &&
        obs.levels_completed == p.level ||
        return (reason="public_observation_changed",item=nothing)
    active = Dict(item.rule.id=>active_id(item) for item in knowledge.active)
    all(get(active,rule,nothing) == version for (rule,version) in cursor.node.dependencies) ||
        return (reason="dependency_changed",item=nothing)
    edge = p.edges[(cursor.state,cursor.node.action)]
    selected = findfirst(decision.ranked) do item
        action_key(item.action) == cursor.node.action && !isnothing(item.chosen) &&
            item.chosen.model.rule.id == edge.rule && item.chosen.expected == edge.expected
    end
    isnothing(selected) && return (reason="live_binding_unproved",item=nothing)
    chosen = decision.ranked[selected]
    projected = chosen.projection
    projected == p.states[edge.target].frame || return (reason="frame_patch_changed",item=nothing)
    return (reason="ready",item=chosen)
end

function confirm_goal_step(cursor::GoalCursor, obs, assessment)
    p = cursor.projection
    edge = p.edges[(cursor.state,cursor.node.action)]
    after = p.states[edge.target]
    if isempty(assessment.assessments) || !all(==("supported"),values(assessment.assessments)) ||
        last(obs.frames) != after.frame
        binding_conflict = any(startswith(query,"selection-") && result == "refuted"
            for (query,result) in assessment.assessments)
        return (status="withdrawn_after_feedback",next=nothing,
            invalidation=goal_invalidation!(cursor,binding_conflict ? "binding" : "relation"))
    end
    if length(obs.frames) != 1 || obs.state == "GAME_OVER" || (obs.state == "WIN" && edge.target ∉ p.goals) ||
        (obs.state != "WIN" && (sort(obs.available_actions) != after.actions || obs.levels_completed != p.level))
        return (status="withdrawn_public_transition",next=nothing,
            invalidation=goal_invalidation!(cursor,"condition"))
    end
    live = continue_policy(p.model,cursor.node,frame_key(after.frame),Set([edge.target]))
    live.status == "ready" || return (status=live.status,next=nothing,
        invalidation=live.status == "achieved" ? nothing : goal_invalidation!(cursor,"condition"))
    return (status="supported",invalidation=nothing,
        next=GoalCursor(p,live.policy,cursor.root_command,edge.target,cursor.index,cursor.definitions))
end

function projected_trace(cursor::GoalCursor)
    trace = []
    p = cursor.projection
    id = cursor.state
    node = cursor.node
    while !isnothing(node.action)
        action = node.action
        edge = p.edges[(id,action)]
        push!(trace,Dict("before"=>id,"after"=>edge.target,"action"=>action,
            "rule"=>edge.rule,"expected"=>edge.expected))
        id = edge.target
        node = only(values(node.branches))
    end
    return trace
end

function public_projection_record(result)
    p = result.projection
    return Dict("status"=>result.status,"scope"=>"observed_frame_patches",
        "projection_work"=>p.work,"search_work"=>result.search_work,"gaps"=>p.gaps,
        "states"=>[Dict("id"=>i,"frame_sha256"=>frame_key(state.frame),
            "actions"=>state.actions,"goal"=>(i in p.goals)) for (i,state) in enumerate(p.states)],
        "edges"=>[Dict("before"=>index,"action"=>action,"after"=>edge.target,
            "rule"=>edge.rule,"expected"=>edge.expected)
            for ((index,action),edge) in sort!(collect(p.edges);by=first)],
        "steps"=>isnothing(result.cursor) ? [] : projected_trace(result.cursor),
        "readers"=>isnothing(result.cursor) ? Dict() :
            Dict(key=>sort!(collect(value)) for (key,value) in result.cursor.index.readers))
end

function choose_observed_goal_step(rec, knowledge, goal, goal_config, history, decision, pending, limits, match_limit)
    note = Dict{String,Any}("operation"=>"search_observed_goal","status"=>"unbound_observed_goal")
    isnothing(goal) && return (item=nothing,cursor=nothing,note)
    if !isnothing(pending)
        checked = live_goal_step(pending,knowledge,decision,rec.observation)
        note["status"] = checked.reason
        note["parent_command"] = pending.root_command
        if !isnothing(checked.item)
            note["operation"] = "revalidate_goal_suffix"
            return (item=merge(checked.item,(reason="revalidated_goal_policy",)),cursor=pending,note)
        end
        note["withdrawn_suffix"] = checked.reason
        note["invalidation"] = goal_invalidation!(pending,"condition")
    end
    budget = (depth=min(goal_config["depth"],rec.limit-rec.sent_count),work=goal_config["max_work"],
        states=get(goal_config,"max_states",96),history=max(1,maximum(get(limits,:history_lengths,(1,)))))
    id = command_id(rec.next_sequence)
    result = search_observed_goal(knowledge,rec.observation,history,goal,budget,match_limit,id)
    proof = public_projection_record(result)
    proof["before_ref"] = rec.before_ref
    proof["goal"] = Dict("relation"=>"distance_to_marker","role_color"=>goal.role_color,
        "marker"=>goal.marker,"maximum_pixel_distance"=>goal.pixel_distance)
    isnothing(goal.cue_color) || (proof["goal"]["cue_color"] = goal.cue_color)
    proof["budget"] = budget
    atomic_json(store_path(rec.store,"plans",id * ".json"),proof)
    note["status"] = result.status
    note["artifact"] = "plans/" * id * ".json"
    isnothing(result.cursor) && return (item=nothing,cursor=nothing,note)
    checked = live_goal_step(result.cursor,knowledge,decision,rec.observation)
    if isnothing(checked.item)
        note["status"] = checked.reason
        return (item=nothing,cursor=nothing,note)
    end
    note["operation"] = "freeze_observed_goal_policy"
    note["status"] = "ready"
    note["dependencies"] = result.cursor.node.dependencies
    return (item=merge(checked.item,(reason="observed_goal_policy",)),cursor=result.cursor,note)
end
