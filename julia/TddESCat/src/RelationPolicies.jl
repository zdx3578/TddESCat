"""A policy input is a witnessed dependency between adjacent public relation tasks."""
function witnessed_relation_steps(agenda,entries)
    by_ref = Dict(entry.event["event_id"]=>entry.observation for entry in entries)
    by_sample = Dict(index=>key for (key,producer) in agenda.producers for index in producer.support)
    descriptors = Dict{Int,Any}()
    neighbors = Dict{Int,NamedTuple}()
    outcomes_after = Dict{Int,Vector{NamedTuple}}()
    for outcome in agenda.outcomes
        haskey(by_ref,outcome.event) || continue
        prior = agenda.samples[outcome.index].preceding
        prior == 0 && continue
        push!(get!(Vector{NamedTuple},outcomes_after,prior),outcome)
    end
    for (index,row) in enumerate(agenda.samples)
        row.state == "GAME_OVER" && continue
        i = row.preceding
        i == 0 && continue
        left = agenda.samples[i]
        isempty(left.effects.residual) || continue
        earlier = get(by_sample,i,nothing)
        same_stage = !left.advanced && left.attempt == row.attempt && left.level == row.level
        same_stage || continue
        if row.advanced
            isnothing(earlier) && continue
            left.next_context == row.context || continue
            row.effects.action["id"] == 6 && isnothing(row.binding) && continue
            haskey(by_ref,relation_ref(row)) || continue
            descriptors[index] = policy_step(row,String[])
            descriptors[i] = policy_step(left,agenda.producers[earlier].relations)
            neighbors[index] = (;before=i,shared=Tuple{Int,Int}[])
            continue
        end
        isempty(row.effects.residual) || continue
        key = get(by_sample,index,nothing)
        isnothing(key) && continue
        sharing = public_role_links(left.effects,row.effects)
        inferred_history = any(pair->first(pair) == index,get(agenda.delayed,left.context,[]))
        law = get(left.effects.public_delta,"available_actions",nothing)
        enabled = !isnothing(law) && row.effects.action["id"] ∉ law["before"] &&
            row.effects.action["id"] in law["after"]
        # A positive delayed-effect witness needs a contrasting unchanged trial.
        connected = inferred_history || enabled || !isempty(sharing) || row.dependency == relation_ref(left)
        connected || continue
        (isnothing(earlier) && !inferred_history) && continue
        only_meter = all(effect->effect.family == :measurement,row.effects.effects) &&
            all(effect->effect.family == :measurement,left.effects.effects)
        only_meter && continue
        descriptors[index] = policy_step(row,agenda.producers[key].relations)
        descriptors[i] = policy_step(left,isnothing(earlier) ? [] : agenda.producers[earlier].relations)
        neighbors[index] = (;before=i,shared=sharing)
    end
    return (;descriptors,neighbors,by_ref,outcomes_after)
end

function public_role_links(previous,current)
    return [(i,j) for (i,left) in enumerate(previous.effects) for (j,right) in enumerate(current.effects)
        if left.family ∉ (:measurement,:count) && right.family ∉ (:measurement,:count) &&
            left.after == right.before]
end

function policy_step(row,relations)
    role = isnothing(row.binding) ? nothing : row.binding.appearance
    descriptor = Dict{String,Any}("id"=>row.effects.action["id"],"role"=>role,
        "relations"=>relations,"wait"=>row.unchanged)
    row.advanced && (descriptor["public_outcome"] = "advancement")
    return descriptor
end

policy_step_key(step) = semantic_hash(step)

function source_policy_episodes(agenda,trace)
    families = Dict{String,Vector{Vector{Int}}}()
    next = Dict(link.before=>index for (index,link) in trace.neighbors)
    epochs = Vector{Vector{Int}}()
    for start in sort!(collect(keys(next)))
        push!(epochs,[start,next[start]])
    end
    identify(rows) = semantic_hash([[policy_step_key(trace.descriptors[i]) for i in rows],
        [trace.neighbors[i].shared for i in rows[2:end]]])
    for rows in epochs
        push!(get!(Vector{Vector{Int}},families,identify(rows)),rows)
    end
    replicated = filter(pair->length(last(pair)) >= 2,families)
    pending = collect(values(replicated))
    while !isempty(pending)
        current = pop!(pending)
        # Keep each extension with independent witnesses. Sharing a prefix
        # can expose more than one valid continuation.
        extended = Dict{String,Vector{Vector{Int}}}()
        for rows in current
            tail = get(next,last(rows),0)
            tail == 0 && continue
            any(i->agenda.samples[i].context == agenda.samples[tail].context,rows) && continue
            interval = [rows;tail]
            siblings = get!(Vector{Vector{Int}},extended,identify(interval))
            (isempty(siblings) || last(last(siblings)) < first(interval)) && push!(siblings,interval)
        end
        choices = [rows for rows in values(extended) if length(rows) >= 2]
        if isempty(choices)
            length(first(current)) > 2 && (replicated[identify(first(current))] = current)
        else
            append!(pending,choices)
        end
    end
    return replicated
end

function policy_features!(cache,trace,ref)
    return get!(cache,ref) do
        obs = trace.by_ref[ref]
        Set(semantic_hash(shape_template(shape)) for shape in public_components(last(obs.frames))
            if 4length(shape) <= length(last(obs.frames)))
    end
end

function separating_feature(positive,negative)
    (isempty(positive) || isempty(negative)) && return nothing
    present = setdiff(reduce(intersect,positive),reduce(union,negative))
    absent = setdiff(reduce(intersect,negative),reduce(union,positive))
    !isempty(present) && return Dict("feature"=>minimum(present),"present"=>true)
    return isempty(absent) ? nothing : Dict("feature"=>minimum(absent),"present"=>false)
end

policy_expr(kind, args...; layout=Dict{String,Any}()) = Dict{String,Any}(
    "kind"=>kind,"layout"=>layout,"children"=>collect(args))

function sequence_policy(trace,members)
    first = policy_expr("RelationTask";layout=trace.descriptors[members[1]])
    for index in members[2:end]
        second = policy_expr("RelationTask";layout=trace.descriptors[index])
        first = policy_expr("RelationSequence",first,second;layout=Dict("shared"=>trace.neighbors[index].shared))
    end
    return first
end

function policy_episodes(agenda,entries;solver=nothing,snapshot="trajectory")
    trace = witnessed_relation_steps(agenda,entries)
    families = source_policy_episodes(agenda,trace)
    isempty(families) && return NamedTuple[]
    episodes = NamedTuple[]
    features = Dict{String,Set{String}}()
    atom_features = Dict{String,Dict{String,NamedTuple}}()
    function scene(ref)
        isnothing(solver) && return policy_features!(features,trace,ref)
        return get!(() -> policy_scene_atoms(trace.by_ref[ref]),atom_features,ref)
    end
    before(index) = scene(agenda.samples[index].effects.before_id)
    after(index) = scene(relation_ref(agenda.samples[index]))
    distinguish(a,b) = isnothing(solver) ? separating_feature(a,b) : typed_policy_guard(solver,a,b,snapshot)
    function emit(body,members,structure)
        rows = agenda.samples[members]
        outcomes = get(trace.outcomes_after,last(members),NamedTuple[])
        events = unique([reduce(vcat,relation_refs.(rows));[outcome.event for outcome in outcomes]])
        push!(episodes,(;body,members,structure,events,public_outcomes=outcomes))
    end
    ordered = sort!(collect(families);by=first)
    for (_,members) in ordered
        representative = first(members)
        body = sequence_policy(trace,representative)
        for indices in members
            emit(body,indices,"sequence")
        end
        repeats = Vector{Vector{Int}}()
        by_start = Dict(first(rows)=>rows for rows in members)
        followers = Dict(link.before=>i for (i,link) in trace.neighbors)
        for indices in members
            repetition = copy(indices)
            while haskey(by_start,get(followers,last(repetition),0))
                append!(repetition,by_start[followers[last(repetition)]])
            end
            length(repetition) > length(indices) && push!(repeats,repetition)
        end
        isempty(repeats) && continue
        width = length(representative)
        guard = distinguish([before(rows[i]) for rows in repeats for i in 1:width:length(rows)],
            [after(last(rows)) for rows in repeats])
        isnothing(guard) && continue
        test = policy_expr("RelationTest";layout=guard)
        repeat = policy_expr("RelationRepeat",test,body;
            layout=Dict("observed_bound"=>maximum(length(rows) ÷ width for rows in repeats)))
        for indices in repeats
            emit(repeat,indices,"repeat")
        end
    end
    # Compare witnessed continuations after a common prefix. An entry guard
    # can select a program before its first step when the entry separates it.
    for i in eachindex(ordered), j in i+1:length(ordered)
        left,right = last(ordered[i]),last(ordered[j])
        a,b = first(left),first(right)
        trace.descriptors[first(a)] == trace.descriptors[first(b)] || continue
        offset = findfirst(2:min(length(a),length(b))) do position
            trace.descriptors[a[position]] != trace.descriptors[b[position]] ||
                trace.neighbors[a[position]].shared != trace.neighbors[b[position]].shared
        end
        isnothing(offset) && continue
        position = offset + 1
        entry_guard = if position == 2
            distinguish([before(first(rows)) for rows in left],[before(first(rows)) for rows in right])
        end
        branch = if !isnothing(entry_guard)
            policy_expr("RelationBranch",policy_expr("RelationTest";layout=entry_guard),
                sequence_policy(trace,a),sequence_policy(trace,b))
        else
            guard = distinguish([before(rows[position]) for rows in left],
                [before(rows[position]) for rows in right])
            isnothing(guard) && continue
            prefix = sequence_policy(trace,a[1:position-1])
            shared = [trace.neighbors[a[position]].shared,trace.neighbors[b[position]].shared]
            suffix = policy_expr("RelationBranch",policy_expr("RelationTest";layout=guard),
                sequence_policy(trace,a[position:end]),sequence_policy(trace,b[position:end]);
                layout=Dict("shared_by_branch"=>shared))
            policy_expr("RelationSequence",prefix,suffix;layout=Dict("shared"=>[]))
        end
        for rows in [left;right]
            emit(branch,rows,"branch")
        end
    end
    return episodes
end

function policy_corpus(agenda::RelationAgenda,entries;published=Set{String}(),solver=nothing,snapshot="trajectory")
    episodes = policy_episodes(agenda,entries;solver,snapshot)
    filter!(episode->semantic_hash(episode.body) ∉ published,episodes)
    isempty(episodes) && return nothing
    signature = typed_motion_signature(Pixel[])
    append!(signature["sorts"],[Dict{String,Any}("id"=>name) for name in ("SceneBefore","Boolean")])
    sort = semantic_sort!(signature,"prog",Dict("kind"=>"program","version"=>"public-relation-policy-v1",
        "input_ports"=>["SceneBefore"],"output_ports"=>["PublicRelations"]))
    function encode(node,slot)
        kind = node["kind"]
        children = node["children"]
        input_types = if kind in ("RelationTask","RelationTest")
            ["SceneBefore"]
        elseif kind == "RelationBranch"
            ["Boolean",sort,sort]
        elseif kind == "RelationRepeat"
            ["Boolean",sort]
        else
            [sort,sort]
        end
        op = semantic_operator!(signature,input_types,kind == "RelationTest" ? "Boolean" : sort,
            Dict("kind"=>kind,"layout"=>node["layout"]))
        return Call(op,isempty(children) ? ConceptTerm[slot] : ConceptTerm[encode(child,slot) for child in children])
    end
    programs = String[]
    slots = Dict{String,Any}[]
    origins = Dict{String,Any}[]
    for (index,episode) in enumerate(episodes)
        push!(slots,Dict("index"=>index-1,"sort"=>"SceneBefore","time_role"=>"before","role_constraints"=>[]))
        term = render_term(encode(episode.body,Slot(index-1)))
        push!(programs,term)
        ref = relation_ref(agenda.samples[first(episode.members)])
        scope = "relation-episode-" * string(index)
        registry,_ = registry_from(signature,[])
        walk_wire(decode_program(term,registry)) do _,path
            push!(origins,Dict("program_index"=>index-1,"expression_path"=>path,
                "occurrence_id"=>"relation-policy-" * join([index;path],"."),
                "event_ref"=>ref,"interpretation_ref"=>episode.structure,
                "slot_bindings_ref"=>scope,"support_ref"=>scope,"source_kind"=>"observed"))
        end
    end
    events = sort!(unique([ref for episode in episodes for ref in episode.events]))
    return (;signature,slots,programs,origins,episodes,events,model="public-relation-policy-v1")
end

function analyze_relation_policy(node,registry,slot)
    get(node,"kind",nothing) == "Call" || return nothing
    description = get(registry[node["operator"]],"descriptor",nothing)
    isnothing(description) && return nothing
    kind = description["kind"]
    layout = get(description,"layout",Dict())
    args = node["args"]
    if kind in ("RelationTask","RelationTest")
        length(args) == 1 && only(args) == slot || return nothing
        return policy_expr(kind;layout)
    end
    arity = kind == "RelationBranch" ? 3 :
        kind in ("RelationSequence","RelationRepeat") ? 2 : 0
    arity > 0 && length(args) == arity || return nothing
    children = [analyze_relation_policy(child,registry,slot) for child in args]
    any(isnothing,children) && return nothing
    ks = [child["kind"] for child in children]
    if kind in ("RelationBranch","RelationRepeat")
        first(ks) == "RelationTest" && all(!=("RelationTest"),ks[2:end]) || return nothing
    else
        all(!=("RelationTest"),ks) || return nothing
    end
    return policy_expr(kind,children...;layout)
end

function relation_policy_slot(node)
    get(node,"kind",nothing) == "Slot" && return node
    get(node,"kind",nothing) == "Call" || return nothing
    for child in node["args"]
        slot = relation_policy_slot(child)
        isnothing(slot) || return slot
    end
    return nothing
end

function relation_predicate(layout,scene)
    haskey(layout,"guard_schema") && return evaluate_policy_guard(layout,scene)
    frame = scene isa PublicObservation ? last(scene.frames) : scene
    present = any(shape->4length(shape) <= length(frame) &&
        semantic_hash(shape_template(shape)) == layout["feature"],public_components(frame))
    return present == layout["present"]
end

mutable struct RelationPolicyCursor
    policy::LearnedPolicy
    pending::Vector{NamedTuple}
    observed::Vector{String}
    outputs::Vector{Any}
    loop_states::Set{Tuple{String,String}}
    purpose::Union{Nothing,NamedTuple}
end

RelationPolicyCursor(policy) = RelationPolicyCursor(policy,
    [(node=policy.body["tree"],iteration=0,shared=Any[])],String[],Any[],Set{Tuple{String,String}}(),nothing)

function peek_relation_instruction(cursor,scene)
    candidate = RelationPolicyCursor(cursor.policy,copy(cursor.pending),copy(cursor.observed),
        copy(cursor.outputs),copy(cursor.loop_states),cursor.purpose)
    result = next_relation_instruction!(candidate,scene)
    return merge(result,(;cursor=candidate))
end

function next_relation_instruction!(cursor,scene)
    branches = NamedTuple[]
    while !isempty(cursor.pending)
        instruction = pop!(cursor.pending)
        node = instruction.node
        kind,layout,children = node["kind"],node["layout"],node["children"]
        if kind == "RelationTask"
            return (;instruction,branches,status=:task)
        elseif kind == "RelationSequence"
            push!(cursor.pending,(node=children[2],iteration=0,shared=layout["shared"]))
            push!(cursor.pending,(node=children[1],iteration=0,shared=instruction.shared))
        elseif kind == "RelationBranch"
            yes = relation_predicate(first(children)["layout"],scene)
            isnothing(yes) && return (;instruction=nothing,branches,status=:unknown_guard)
            push!(branches,(control=:branch,outcome=yes))
            shared = haskey(layout,"shared_by_branch") ?
                layout["shared_by_branch"][yes ? 1 : 2] : instruction.shared
            push!(cursor.pending,(node=children[yes ? 2 : 3],iteration=0,shared))
        elseif kind == "RelationRepeat"
            yes = relation_predicate(first(children)["layout"],scene)
            isnothing(yes) && return (;instruction=nothing,branches,status=:unknown_guard)
            push!(branches,(control=:repeat,outcome=yes,iteration=instruction.iteration))
            yes || continue
            context = scene isa PublicObservation ? relation_context(scene) : content_hash(vec(scene))
            guard_scope = (semantic_hash(node),context)
            guard_scope in cursor.loop_states &&
                return (;instruction=nothing,branches,status=:unresolved_repeat_progress)
            push!(cursor.loop_states,guard_scope)
            push!(cursor.pending,(;instruction.node,iteration=instruction.iteration+1,shared=instruction.shared))
            push!(cursor.pending,(node=children[2],iteration=0,shared=instruction.shared))
        end
    end
    return (;instruction=nothing,branches,status=:stopped)
end

function verify_relation_episode(tree,episode,agenda,entries)
    cursor = RelationPolicyCursor(LearnedPolicy("","",0,"",Dict("tree"=>tree),String[],""))
    by_ref = Dict(entry.event["event_id"]=>entry.observation for entry in entries)
    for outcome in get(episode,:public_outcomes,NamedTuple[])
        sample = agenda.samples[outcome.index]
        after = get(by_ref,outcome.event,nothing)
        isnothing(after) && return false
        sample.preceding == last(episode.members) && relation_ref(sample) == outcome.event || return false
        after.state == sample.state && outcome in agenda.outcomes || return false
    end
    source_producer = Dict(index=>producer for producer in values(agenda.producers) for index in producer.support)
    earlier = nothing
    for index in episode.members
        row = agenda.samples[index]
        next = next_relation_instruction!(cursor,by_ref[row.effects.before_id])
        next.status == :task || return false
        producer = get(source_producer,index,nothing)
        descriptor = policy_step(row,isnothing(producer) ? [] : producer.relations)
        canonical_bytes(next.instruction.node["layout"]) == canonical_bytes(descriptor) || return false
        if haskey(descriptor,"public_outcome")
            before = by_ref[row.effects.before_id]
            after = by_ref[relation_ref(row)]
            after.levels_completed > before.levels_completed || return false
        end
        if !isempty(next.instruction.shared)
            isnothing(earlier) && return false
            canonical_bytes(next.instruction.shared) ==
                canonical_bytes(public_role_links(earlier.effects,row.effects)) || return false
        end
        earlier = row
    end
    return next_relation_instruction!(cursor,by_ref[relation_ref(earlier)]).status == :stopped
end

function trajectory_reads(corpus,agenda)
    indices = unique([index for episode in corpus.episodes for index in
        [episode.members; [outcome.index for outcome in get(episode,:public_outcomes,NamedTuple[])]]])
    return [begin
        row = agenda.samples[index]
        scope = history_scope(agenda,row.context)
        (;event=relation_ref(row),context=row.context,action=action_key(row.effects.action),
            previous=previous_key(agenda,row.preceding),after=row.next_context,
            state=row.state,advanced=row.advanced,history_width=scope.width,history_receipts=scope.receipts,
            history=relation_history_key(agenda,row.context,row.preceding))
    end for index in indices]
end

function trajectory_counterexamples(reads,cutoff,agenda)
    conflicts = Set{String}()
    for read in reads, index in get(agenda.visits,(read.context,read.action),Int[])
        index > cutoff || continue
        row = agenda.samples[index]
        scope = RelationHistoryScope(get(read,:history_width,1),get(read,:history_receipts,false))
        same_history = hasproperty(read,:history) ?
            relation_history_key(agenda,row.context,row.preceding;scope) == read.history :
            previous_key(agenda,row.preceding) == read.previous
        same_history || continue
        (row.next_context,row.state,row.advanced) == (read.after,read.state,read.advanced) && continue
        push!(conflicts,relation_ref(row))
    end
    return sort!(collect(conflicts))
end

function policy_task_options(agenda,instruction,obs,decision;meters=())
    op = instruction.node["layout"]
    id = op["id"]
    id in obs.available_actions || return NamedTuple[]
    actions = [row.action for row in decision.ranked if row.action["id"] == id]
    context = relation_context(obs)
    condition_view = get(decision,:condition_view,nothing)
    options = NamedTuple[]
    for action in actions
        observed_failure(agenda,context,action_key(action),agenda.previous) && continue
        if id == 6
            point = action_key(action)[2:3]
            support = point_component(decision.groups,point)
            isnothing(support) && continue
            click_profile(support,point) == op["role"] || continue
        end
        tests = if op["wait"]
            NamedTuple[]
        else
            sought = op["relations"]
            allowed = reduce(intersect,(Set(get(agenda.by_relation,relation,String[])) for relation in sought))
            observed = prepare_relation_tests(agenda,context,obs,decision.groups,action;meters,condition_view)
            [test for test in observed if test.key in allowed && test.relations == sought &&
                test.scope in (:bound,:replicated) && all(other->other.expected == test.expected,observed)]
        end
        op["wait"] || !isempty(tests) || continue
        push!(options,(;action,tests))
    end
    return options
end

function bind_policy_outcome(cursor,op,obs,decision,agenda)
    op["public_outcome"] == "advancement" || return nothing
    op["id"] in obs.available_actions || return nothing
    previous = agenda.previous
    (previous == 0 || isempty(cursor.observed)) && return nothing
    prior = agenda.samples[previous]
    preparation = relation_ref(prior)
    context = relation_context(obs)
    last(cursor.observed) == preparation && prior.next_context == context || return nothing
    training = Set(cursor.policy.training)
    available = Set(obs.available_actions)
    history = relation_history_key(agenda,context,previous)
    matches(row,action) = (op["id"] != 6 || !isnothing(row.binding) && row.binding.appearance == op["role"]) &&
        matches_outcome_binding(row,action,decision.groups)
    for item in decision.ranked
        action = item.action
        action["id"] == op["id"] || continue
        key = action_key(action)
        visits = get(agenda.visits,(context,key),Int[])
        exact = filter(index->relation_history_key(agenda,context,agenda.samples[index].preceding) == history,visits)
        if !isempty(exact)
            all(index->agenda.samples[index].advanced,exact) || continue
            recorded = findlast(exact) do index
                row = agenda.samples[index]
                relation_ref(row) in training && matches(row,action)
            end
            isnothing(recorded) && continue
            scope, outcome, comparison = :observed_instance, agenda.samples[exact[recorded]], nothing
        else
            match = findlast(agenda.outcome_relations) do witness
                observed = agenda.samples[witness.outcome]
                relation_ref(observed) in training && Set(observed.available) == available &&
                    matches(observed,action) || return false
                live = frontier_prior(agenda,previous,length(witness.steps))
                length(live) == length(witness.steps) <= length(cursor.observed) || return false
                relation_ref.(agenda.samples[live]) == cursor.observed[end-length(live)+1:end] || return false
                return all(index in agenda.producers[producer].support
                    for (index,(_,producer)) in zip(live,witness.steps))
            end
            isnothing(match) && continue
            witness = agenda.outcome_relations[match]
            scope = :hypothesis
            outcome, comparison = agenda.samples[[witness.outcome,witness.comparison]]
        end
        reads = unique([cursor.policy.training;cursor.policy.available_after;cursor.observed;
            relation_refs(outcome);isnothing(comparison) ? String[] : relation_refs(comparison)])
        obligation = (;definition=cursor.policy.definition,wait=false,sought=String[],shared=[],
            public_outcome=op["public_outcome"],scope,preparation,outcome=relation_ref(outcome),
            comparison=isnothing(comparison) ? nothing : relation_ref(comparison))
        return (;action,intent=:execute_relation_policy,tests=NamedTuple[],reads,obligation)
    end
    return nothing
end

function bind_relation_instruction(cursor,instruction,obs,decision,agenda;meters=())
    op = instruction.node["layout"]
    haskey(op,"public_outcome") && return bind_policy_outcome(cursor,op,obs,decision,agenda)
    options = policy_task_options(agenda,instruction,obs,decision;meters)
    sharing = instruction.shared
    if !isempty(sharing)
        filter!(options) do option
            !isempty(option.tests) && all(test->all(sharing) do (i,j)
                i <= length(cursor.outputs) && j <= length(test.fragments) &&
                    cursor.outputs[i] == test.fragments[j].basis
            end,option.tests)
        end
    end
    isempty(options) && return nothing
    context = relation_context(obs)
    option = argmin(options) do row
        bound = any(test->test.scope == :bound,row.tests)
        witnesses = length(get(agenda.visits,(context,action_key(row.action)),Int[]))
        (!bound,-witnesses,action_key(row.action))
    end
    source = unique([cursor.policy.training;cursor.policy.available_after;cursor.observed])
    return (action=option.action,intent=:execute_relation_policy,tests=option.tests,reads=source,
        obligation=(definition=cursor.policy.definition,wait=instruction.node["layout"]["wait"],
            sought=instruction.node["layout"]["relations"],shared=sharing))
end

function policy_outcome_steps(node)
    kind = node["kind"]
    if kind == "RelationTask"
        return get(node["layout"],"public_outcome",nothing) == "advancement" ? [node["layout"]] : []
    elseif kind == "RelationBranch"
        return reduce(vcat,policy_outcome_steps.(node["children"][2:end]);init=[])
    elseif kind == "RelationTest"
        return []
    end
    return policy_outcome_steps(last(node["children"]))
end

function policy_advancement_purpose(candidate,ends,agenda,obs,decision,context)
    training = Set(candidate.cursor.policy.training)
    available = Set(obs.available_actions)
    for witness in Iterators.reverse(agenda.outcome_relations)
        outcome = agenda.samples[witness.outcome]
        relation_ref(outcome) in training || continue
        id = outcome.effects.action["id"]
        role = isnothing(outcome.binding) ? nothing : outcome.binding.appearance
        any(op->op["id"] == id && op["role"] == role,ends) || continue
        at,producer = first(witness.steps)
        Set(agenda.samples[at].available) == available || continue
        matched = findfirst(test->test.key == producer,candidate.proposal.tests)
        isnothing(matched) && continue
        sources = [agenda.samples[index] for (index,_) in witness.steps]
        all(row->relation_ref(row) in training,sources) || continue
        target = rebound_outcome_action(outcome,decision)
        isnothing(target) && continue
        observed_failure(agenda,context,action_key(target),agenda.previous) && continue
        comparison = agenda.samples[witness.comparison]
        purpose = (;kind=:establish_public_outcome,scope=:hypothesis,target,producer,
            sought=candidate.proposal.tests[matched].relations,
            outcome=relation_ref(outcome),comparison=relation_ref(comparison))
        reads = unique([relation_refs(outcome);relation_refs(comparison);reduce(vcat,relation_refs.(sources))])
        return (;purpose,reads)
    end
    return nothing
end

function policy_comparison_purpose(proposal,relation,agenda,obs,context)
    if !isnothing(relation) && proposal.action == relation.action && relation.intent in
            (:establish_preparation,:test_delayed_effect,:test_history_response,:distinguish_changed_context,
                :test_concrete_effect)
        same_effect = if isempty(relation.tests)
            proposal.obligation.wait
        else
            all(wanted->any(test->test.key == wanted.key && test.expected == wanted.expected,proposal.tests),
                relation.tests)
        end
        if same_effect
            purpose = (;kind=:distinguish_relation,comparison=relation.intent,relation=relation.obligation)
            return (;purpose,reads=relation.reads)
        end
    end
    history = relation_history_key(agenda,context,agenda.previous)
    action = action_key(proposal.action)
    pending = filter(proposal.tests) do test
        test.scope == :replicated &&
            effect_experiment_scope(obs.levels_completed,action,history,test) ∉ agenda.checked_effects
    end
    isempty(pending) && return nothing
    # The known effect has yet to be checked at this role and history.
    purpose = (;kind=:distinguish_relation,comparison=:effect_at_bound_condition,
        producers=[test.key for test in pending],history)
    return (;purpose,reads=String[])
end

function assign_policy_purpose(candidate,purpose,reads=get(purpose,:reads,String[]))
    purpose = merge(purpose,(;reads))
    candidate.cursor.purpose = purpose
    task = candidate.proposal
    proposal = merge(task,(;obligation=merge(task.obligation,(;purpose)),reads=unique([task.reads;reads])))
    return merge(candidate,(;proposal))
end

function relation_policy_choice(policies,cursor,attempted,agenda,obs,decision;meters=(),relation=nothing)
    context = relation_context(obs)
    function ready(candidate)
        next = peek_relation_instruction(candidate,obs)
        next.status == :task || return nothing
        proposal = bind_relation_instruction(next.cursor,next.instruction,obs,decision,agenda;meters)
        isnothing(proposal) && return nothing
        candidate = (;cursor=next.cursor,proposal,next.branches,context)
        return isnothing(next.cursor.purpose) ? candidate : assign_policy_purpose(candidate,next.cursor.purpose)
    end

    choices = [policy for policy in Iterators.reverse(policies) if haskey(policy.body,"tree") &&
        (policy.body["scope"],context) ∉ attempted]
    if !isnothing(cursor)
        current = ready(cursor)
        isnothing(current) && return nothing
        cursor.policy.body["structure"] == "sequence" || return current
        # A guarded branch can reuse the current dispatch when it preserves
        # the remaining sequence or extends it after its last task.
        for policy in choices
            policy.body["structure"] == "branch" || continue
            next = ready(RelationPolicyCursor(policy))
            isnothing(next) && continue
            a,b = current.proposal,next.proposal
            a.action == b.action && a.obligation.wait == b.obligation.wait &&
                a.obligation.sought == b.obligation.sought || continue
            a_effects = Set(semantic_hash(test.expected) for test in a.tests)
            b_effects = Set(semantic_hash(test.expected) for test in b.tests)
            a_effects == b_effects || continue
            (isempty(current.cursor.pending) || current.cursor.pending == next.cursor.pending) || continue
            next.cursor.observed = copy(current.cursor.observed)
            next.cursor.loop_states = copy(current.cursor.loop_states)
            proposal = merge(b,(reads=unique([a.reads;b.reads]),))
            replacement = merge(next,(;proposal))
            return isnothing(cursor.purpose) ? replacement : assign_policy_purpose(replacement,cursor.purpose)
        end
        return current
    end
    sort!(choices;by=policy->policy.body["structure"] == "sequence")
    comparison = nothing
    for policy in choices
        ends = get(() -> policy_outcome_steps(policy.body["tree"]),policy.body,"public_outcomes")
        isempty(ends) && !isnothing(comparison) && continue
        next = ready(RelationPolicyCursor(policy))
        isnothing(next) && continue
        if !isempty(ends)
            goal = policy_advancement_purpose(next,ends,agenda,obs,decision,context)
            isnothing(goal) || return assign_policy_purpose(next,goal.purpose,goal.reads)
        end
        if isnothing(comparison)
            trial = policy_comparison_purpose(next.proposal,relation,agenda,obs,context)
            isnothing(trial) || (comparison = assign_policy_purpose(next,trial.purpose,trial.reads))
        end
    end
    return comparison
end

function observed_policy_port(effects,fragment)
    matches = [effect.after for effect in effects.effects if effect.family == fragment.family &&
        effect.before == fragment.basis]
    return length(matches) == 1 && !isempty(only(matches)) ? only(matches) : nothing
end

function confirm_relation_policy!(selection,agenda,feedback,after)
    cursor = selection.cursor
    row = last(agenda.samples)
    push!(cursor.observed,relation_ref(row))
    task = selection.proposal
    success = if get(task.obligation,:public_outcome,nothing) == "advancement"
        row.advanced
    elseif task.obligation.wait
        row.unchanged
    else
        !isnothing(feedback.feedback) && feedback.feedback.result == :established
    end
    experiment_after = row.state == "NOT_FINISHED" && !row.advanced ? relation_ref(row) : nothing
    if !success || row.state == "GAME_OVER"
        return (;cursor=nothing,result=:withdrawn,branches=NamedTuple[],experiment_after)
    end
    row.advanced && return (;cursor=nothing,result=:stopped_at_public_advance,branches=NamedTuple[],experiment_after)
    cursor.outputs = if isempty(task.tests)
        []
    else
        [observed_policy_port(row.effects,part) for part in first(task.tests).fragments]
    end
    # Peek through zero-action control nodes only after the receipt.
    next = next_relation_instruction!(cursor,after.observation)
    if next.status == :task
        push!(cursor.pending,next.instruction)
        return (;cursor,result=:continue,branches=next.branches,experiment_after=nothing)
    end
    return (;cursor=nothing,result=next.status,branches=next.branches,experiment_after)
end
