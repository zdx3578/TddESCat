const ConcreteAction = Tuple{Int,Int,Int}

struct ObservedGoal
    role_color::UInt8
    role_geometry::Vector{Pixel}
    marker::MotionShape
    cue_color::Union{Nothing,UInt8}
    pixel_distance::Int
end

function bind_observed_goal(frame, config)
    groups = public_components(frame)
    roles = filter(s -> first(s)[3] == config["role_color"], groups)
    marks = filter(s -> first(s)[3] == config["marker_color"], groups)
    length(roles) == length(marks) == 1 || return nothing
    cue = get(config,"cue_color",nothing)
    marker = only(marks)
    distance = 1 + get(config,"marker_gap",0)*support_grid(marker).unit
    return ObservedGoal(first(only(roles))[3],geometry(only(roles)),marker,
        isnothing(cue) ? nothing : UInt8(cue),distance)
end

function observed_goal_relations(goal::ObservedGoal,frame)
    groups = public_components(frame)
    cue = isnothing(goal.cue_color) || goal.cue_color in frame ? proven : disproven
    unavailable = (near_marker=unknown_truth,cue_visible=cue)
    goal.marker in groups || return unavailable
    roles = filter(s -> first(s)[3] == goal.role_color && geometry(s) == goal.role_geometry, groups)
    length(roles) == 1 || return unavailable
    nearby = any(abs(x-u)+abs(y-v) <= goal.pixel_distance
        for (x,y,_) in goal.marker for (u,v,_) in only(roles))
    return (near_marker=nearby ? proven : disproven,cue_visible=cue)
end

function goal_truth(goal::ObservedGoal,frame)
    facts = observed_goal_relations(goal,frame)
    facts.near_marker == unknown_truth && return unknown_truth
    return all(==(proven),facts) ? proven : disproven
end

function project_frame(choice,before)
    patch = projection_patch(choice,before)
    return isnothing(patch) ? nothing : patch.frame
end

function compatible_frame_projection(supports,expected,frame;memory=ProjectionMemory(),history=Int[])
    matched = nothing
    probe = nothing
    unresolved = false
    for choice in supports
        choice.expected == expected || continue
        contract = projected_contract(memory,choice,frame,history)
        isnothing(contract) && continue
        if !projection_allowed(contract)
            isnothing(probe) && (probe = (choice,contract))
            unresolved = true
            continue
        end
        if isnothing(matched)
            matched = (choice,contract)
        elseif contract.frame != last(matched).frame
            return (choice=nothing,frame=nothing,contract=nothing,probe=nothing,conflict=true)
        end
    end
    if unresolved || isnothing(matched)
        return (choice=nothing,frame=nothing,contract=nothing,probe,conflict=false)
    end
    choice,contract = matched
    return (;choice,frame=contract.frame,contract,probe=(choice,contract),conflict=false)
end

function projected_program_ports(choice,frame)
    groups = public_components(frame)
    enclosed = [role.target for role in enclosure_pairs(groups)]
    ports = Any[]
    for (model,part) in zip(choice.model.rule.effects,choice.fragments)
        port = if part.family == :measurement
            (instance=part.instance,value=part.expected)
        elseif part.family == :count
            support = sort!(reduce(vcat,(s for s in groups if shape_template(s) == model.template);init=ColorCell[]))
            (instance=part.instance,count=part.expected,support)
        elseif part.family == :translation
            model_binding(model,groups,enclosed)
        elseif part.family == :selection
            part.basis
        else
            ColorCell[(x,y,UInt8(part.expected)) for (x,y,_) in part.basis]
        end
        isnothing(port) && return nothing
        push!(ports,port)
    end
    return ports
end

function forecast_program(knowledge,obs,history,cursor,coordinates,meters,accepts,reaches,steps_available)
    draft = ProgramCursor(cursor.program,cursor.next_step,copy(cursor.outputs))
    observation = obs
    sequence = NamedTuple[]
    previous = last(obs.frames)
    width = goal_history_width(knowledge)
    recent = copy(history)
    for i in 1:min(steps_available,length(draft.program.steps)-draft.next_step+1)
        decision = ranked_public_actions(knowledge,observation,recent,Dict{ConcreteAction,Int}(),
            coordinates;composing=true,programs_pending=true,program_cursor=draft,meters)
        item = current_program_step(draft,decision)
        isnothing(item) && return nothing
        frame = item.projection
        isnothing(frame) && return nothing
        accepts(i,previous,item,frame) || return nothing
        outputs = projected_program_ports(item.chosen,frame)
        isnothing(outputs) && return nothing
        push!(sequence,(;item,frame))
        recent = [recent;item.action["id"]]
        recent = last(recent,min(width,length(recent)))
        reaches(i,frame,recent) && return sequence
        draft.outputs = outputs
        draft.next_step += 1
        previous = frame
        observation = (frames=[frame],available_actions=obs.available_actions)
    end
    return nothing
end

function goal_program(knowledge,obs,history,cursor,coordinates,meters,goal,spatial,visual,
                      spatial_choice,primitive_limit,primitive)
    left = length(cursor.program.steps)-cursor.next_step+1
    if !isnothing(goal)
        path = forecast_program(knowledge,obs,history,cursor,coordinates,meters,
            (_,_,_,_)->true,(_,frame,_)->goal_truth(goal,frame) == proven,min(left,primitive_limit))
        if !isnothing(path)
            return (contract="distance_to_marker",target=goal.marker,role=nothing,path,continuation=nothing)
        end
        isnothing(primitive) && return nothing
        trace = projected_trace(primitive)
        targets = Dict(state_key(primitive.projection.states[step["after"]])=>(index,trace[index+1:end])
            for (index,step) in enumerate(trace[1:end-1]))
        successor = nothing
        function establishes_tail(index,frame,recent)
            key = state_key(ProjectedState(frame,sort(obs.available_actions),recent))
            target = get(targets,key,nothing)
            isnothing(target) && return false
            index == left && index <= first(target) || return false
            successor = last(target)
            return true
        end
        path = forecast_program(knowledge,obs,history,cursor,coordinates,meters,(_,_,_,_)->true,
            establishes_tail,min(left,primitive_limit))
        isnothing(path) && return nothing
        return (contract="goal_predecessor",target=frame_key(last(path).frame),role=nothing,path,
            continuation=successor)
    elseif !isnothing(spatial_choice) && !isnothing(visual.continuation) &&
            !get(spatial_choice,:executes_contact,true)
        left <= primitive_limit || return nothing
        tail = visual.continuation.steps
        length(tail) >= left-1 || return nothing
        left > 1 && any(step->!isnothing(step.contact),tail[1:left-1]) && return nothing
        actions = [spatial_choice.id;[step.action for step in tail[1:left-1]]]
        anchors = Pixel[spatial_choice.destination,(step.to for step in tail[1:left-1])...]
        accepts = (i,_,item,frame)-> item.action["id"] == actions[i] &&
            locate_role(frame,spatial.role) == anchors[i]
        path = forecast_program(knowledge,obs,history,cursor,coordinates,meters,
            accepts,(i,frame,_)->i == left && locate_role(frame,spatial.role) == last(anchors),left)
        isnothing(path) && return nothing
        return (contract="observed_route_waypoint",target=last(anchors),role=copy(spatial.role),path,
            continuation=nothing)
    end
    return nothing
end

function goal_program_record(forecast)
    return Dict("contract"=>forecast.contract,"target"=>forecast.target,"role"=>forecast.role,
        "continuation"=>forecast.continuation,
        "regression"=>get(forecast,:regression,nothing),
        "steps"=>[Dict("action"=>step.item.action,"frame_sha256"=>frame_key(step.frame),
            "mechanism"=>active_id(step.item.chosen.model),"queries"=>step.item.chosen.expected)
            for step in forecast.path])
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

function project_goal_model(knowledge,obs,history,goal,history_width,max_action_coordinates;meters=())
    initial = ProjectedState(last(obs.frames),sort(obs.available_actions),copy(history))
    states = [initial]
    ids = Dict{Tuple{String,Tuple,Tuple},Int}(state_key(initial)=>1)
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
            break
        else
            view = (frames=[state.frame],available_actions=state.actions)
            decision = ranked_public_actions(knowledge,view,state.history,Dict{ConcreteAction,Int}(),
                max_action_coordinates;composing=true,meters)
            enabled[index] = Set(action_key(item.action) for item in decision.ranked)
            if 6 in state.actions && decision.click_count < 4096
                push!(gaps,(state=index,action=nothing,reason="unmodeled_click_domain"))
            end
            for item in decision.ranked
                action = action_key(item.action)
                work += 1
                choice = item.chosen
                predicted = item.projection
                if isnothing(predicted)
                    reason = isnothing(choice) ? item.reason : "unproved_frame_projection"
                    push!(gaps,(state=index,action,reason))
                    continue
                end
                advanced = [state.history;action[1]]
                next_history = last(advanced,min(history_width,length(advanced)))
                after = ProjectedState(predicted,state.actions,next_history)
                key = state_key(after)
                target = get(ids,key,0)
                if target == 0
                    push!(states,after)
                    target = ids[key] = length(states)
                end
                rule = choice.model.rule.id
                edges[(index,action)] = ProjectedEdge(target,rule,choice.expected)
                effects[(index,action)] = SuccessorScope(Set([target]),proven,true,Set([rule]))
            end
        end
        index += 1
    end
    observations = Dict(i=>Set([frame_key(state.frame)]) for (i,state) in enumerate(states))
    model = PlanningModel(Set(1:length(states)),enabled,effects,observations,model_versions)
    return GoalProjection(model,states,edges,goals,gaps,work,obs.levels_completed)
end

function search_observed_goal(knowledge,obs,history,goal,history_width,max_action_coordinates,command;meters=())
    projection = project_goal_model(knowledge,obs,last(history,min(history_width,length(history))),
        goal,history_width,max_action_coordinates;meters)
    solved = solve_policy(projection.model,Set([1]),projection.goals)
    cursor = nothing
    if !isnothing(solved.policy) && !isnothing(solved.policy.action)
        index = index_observed_policy(projection,solved.policy,command)
        refs = Set(ref for model in knowledge.active for ref in model.rule.references
            if haskey(solved.policy.dependencies,model.rule.id))
        cursor = GoalCursor(projection,solved.policy,command,1,index,sort!(collect(refs)))
    end
    status = isnothing(solved.policy) && !isempty(projection.gaps) ? "incomplete" : solved.status
    return (; cursor, projection, status, search_work=solved.work)
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

function choose_observed_goal_step(rec,knowledge,goal,history,decision,pending,max_action_coordinates;meters=())
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
    history_width = goal_history_width(knowledge)
    id = command_id(rec.next_sequence)
    result = search_observed_goal(knowledge,rec.observation,history,goal,history_width,max_action_coordinates,id;meters)
    proof = public_projection_record(result)
    proof["before_ref"] = rec.before_ref
    proof["goal"] = Dict("relation"=>"distance_to_marker","role_color"=>goal.role_color,
        "marker"=>goal.marker,"maximum_pixel_distance"=>goal.pixel_distance)
    isnothing(goal.cue_color) || (proof["goal"]["cue_color"] = goal.cue_color)
    proof["history_width"] = history_width
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
