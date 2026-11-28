"""Live occurrence index. A port names the exact public effect in its writer receipt."""
mutable struct RelationUseIndex
    roles::Dict{MotionShape,NamedTuple}
    permissions::Dict{Int,NamedTuple}
    inputs::Dict{Int,Vector{NamedTuple}}
    omissions::Dict{String,Dict{PublicActionKey,NamedTuple}}
    omission_screens::Set{Tuple{Int,PublicActionKey,UInt}}
    signatures::Dict{String,UInt}
end

RelationUseIndex() = RelationUseIndex(Dict(),Dict(),Dict(),Dict(),Set(),Dict())

relation_inputs(agenda,index) = get(agenda.uses.inputs,index,NamedTuple[])

function input_edge(agenda,fact,port,usage;comparison=0,tested_producer=nothing)
    writer = agenda.samples[fact.writer]
    through = agenda.previous
    reads = relation_refs(writer)
    through == 0 || push!(reads,relation_ref(agenda.samples[through]))
    comparison == 0 || append!(reads,relation_refs(agenda.samples[comparison]))
    return (;fact.writer,writer_event=relation_ref(writer),fact.kind,fact.producer,fact.relation,
        fact.output_port,fact.action,input_port=port,usage,comparison,tested_producer,
        since=fact.writer,through,reads=unique!(reads))
end

function bind_relation_reads(agenda,proposal,obs,action)
    isnothing(proposal) && return nothing
    proposal.action == action || error("Cannot bind facts to a different public action")
    edges = NamedTuple[]
    permission = get(agenda.uses.permissions,action["id"],nothing)
    isnothing(permission) || push!(edges,input_edge(agenda,permission,0,:dispatch_legality))
    if proposal.intent == :test_preparation_omission
        trial = proposal.obligation
        relation_context(obs) == trial.comparison_context || error("Omission context changed before dispatch")
        fact = (;trial.writer,kind=:role_support,trial.producer,trial.relation,trial.output_port,action=nothing)
        edge = input_edge(agenda,fact,0,:omission_test)
        original = agenda.samples[trial.consumer]
        push!(edges,merge(edge,(scope=:historical_contrast,through=trial.writer,
            baseline=relation_ref(original),reads=unique([edge.reads;relation_refs(original)]))))
    end
    for test in proposal.tests, (port,part) in enumerate(test.fragments)
        part.family in (:pigment,:translation,:selection) || continue
        fact = get(agenda.uses.roles,part.basis,nothing)
        isnothing(fact) || push!(edges,input_edge(agenda,fact,port,:task_read;tested_producer=test.key))
    end
    isempty(edges) && return proposal
    reads = unique([proposal.reads; reduce(vcat,getproperty.(edges,:reads))])
    return merge(proposal,(;fact_reads=unique!(edges),reads))
end

function observed_inputs!(edges,agenda,sample)
    if !sample.advanced && sample.state == "NOT_FINISHED" && endpoint_effects_observed(sample.effects) &&
            !scene_translation_unresolved(sample.effects)
        for (port,effect) in enumerate(sample.effects.effects)
            effect.family in (:translation,:pigment,:selection) || continue
            fact = get(agenda.uses.roles,effect.before,nothing)
            isnothing(fact) || push!(edges,input_edge(agenda,fact,port,:observed_input))
        end
    end
    id,x,y = action_key(sample.effects.action)
    if !isnothing(sample.binding)
        for (support,fact) in agenda.uses.roles
            if any(cell->cell[1]==x && cell[2]==y,support)
                push!(edges,input_edge(agenda,fact,0,:selected_role))
                break
            end
        end
    end
    permission = get(agenda.uses.permissions,id,nothing)
    isnothing(permission) || push!(edges,input_edge(agenda,permission,0,:dispatch_legality))
    return unique!(edges)
end

# The fingerprint only filters impossible screen matches. Positive hits still
# require reconstructing the omitted screen and checking its full context.
function screen_signature(uses,context,frame)
    return get!(uses.signatures,context) do
        value = zero(UInt)
        for x in axes(frame,2), y in axes(frame,1)
            value ⊻= hash((x-1,y-1,frame[y,x]))
        end
        value
    end
end

function omitted_context(agenda,sample,frame,fact,source)
    isempty(fact.patch) && return nothing
    sample.available == source.available || return nothing
    sample.context == source.next_context && return source.context
    isempty(agenda.uses.omission_screens) && return nothing
    screen = screen_signature(agenda.uses,sample.context,frame) ⊻ fact.patch_delta
    (sample.level,action_key(sample.effects.action),screen) in agenda.uses.omission_screens || return nothing
    restored = copy(frame)
    for (x,y,old,new) in fact.patch
        checkbounds(Bool,frame,y+1,x+1) && frame[y+1,x+1] == new || return nothing
        restored[y+1,x+1] = old
    end
    return semantic_hash([sample.level,size(restored),content_hash(vec(restored)),sort(sample.available)])
end

function same_relation_response(a,b)
    a.advanced == b.advanced && a.state == b.state || return false
    (a.advanced || a.state != "NOT_FINISHED") && return true
    return length(a.effects.effects) == length(b.effects.effects) && all(zip(a.effects.effects,b.effects.effects)) do (x,y)
        (x.family,x.before,x.after,x.values) == (y.family,y.before,y.after,y.values)
    end
end

function withdraw_omitted_outcomes!(agenda,index)
    counter = agenda.samples[index]
    withdrawn = NamedTuple[]
    filter!(agenda.outcome_relations) do witness
        compared = agenda.samples[witness.comparison]
        prior = agenda.samples[witness.outcome]
        compared.context == counter.context && action_key(compared.effects.action)==action_key(counter.effects.action) &&
            same_relation_response(prior,counter) || return true
        refined_history(history_scope(agenda,counter.context)) &&
            relation_history_key(agenda,counter.context,counter.preceding) !=
            relation_history_key(agenda,counter.context,compared.preceding) && return true
        inputs = relation_inputs(agenda,witness.outcome)
        edge = findfirst(f->f.usage==:omission_contrast && f.comparison==witness.comparison,inputs)
        isnothing(edge) && return true
        push!(withdrawn,(;preparation=inputs[edge].writer_event,outcome=relation_ref(prior),
            comparison=relation_ref(compared),counterexample=relation_ref(counter),reason=:outcome_without_preparation))
        return false
    end
    return withdrawn
end

function omission_inputs!(edges,agenda,index,before,contract,before_groups)
    sample = agenda.samples[index]
    if sample.unchanged && !sample.advanced && sample.state == "NOT_FINISHED"
        screen = screen_signature(agenda.uses,sample.context,last(before.frames))
        push!(agenda.uses.omission_screens,(sample.level,action_key(sample.effects.action),screen))
        return false
    end
    (sample.advanced || !isnothing(contract)) || return false
    sample.state == "GAME_OVER" && return false
    action = action_key(sample.effects.action)
    comparisons = NamedTuple[]
    unresolved = false
    selected_points = nothing
    for fact in values(agenda.uses.roles)
        writer = agenda.samples[fact.writer]
        missing = omitted_context(agenda,sample,last(before.frames),fact,writer)
        isnothing(missing) && continue
        seen = get(agenda.visits,(missing,action),Int[])
        if refined_history(history_scope(agenda,missing))
            if missing != writer.context
                unresolved = true
                continue
            end
            history = relation_history_key(agenda,missing,writer.preceding)
            seen = filter(i->relation_history_key(agenda,missing,agenda.samples[i].preceding) == history,seen)
        end
        at = findlast(seen) do i
            row = agenda.samples[i]
            i < index && row.level == sample.level && row.unchanged && !row.advanced &&
                row.state == "NOT_FINISHED" && !isnothing(row.binding) == !isnothing(sample.binding) &&
                (isnothing(row.binding) || row.binding.appearance == sample.binding.appearance)
        end
        if !isnothing(at)
            if any(i->i<index && same_relation_response(sample,agenda.samples[i]),seen)
                unresolved = true
                continue
            end
            push!(comparisons,input_edge(agenda,fact,0,:omission_contrast;comparison=seen[at]))
        elseif isempty(seen) && missing == writer.context
            # This counterfactual is known reachable at the writer's original state.
            # Schedule a real omission only where the same target was available.
            if !isnothing(sample.binding)
                if isnothing(selected_points)
                    groups = isnothing(before_groups) ? public_components(last(before.frames)) : before_groups
                    role = point_component(groups,action[2:3])
                    isnothing(role) && continue
                    selected_points = effect_points(role)
                end
                any(row->(row[1],row[2]) in selected_points,fact.patch) && continue
            end
            pending = get!(Dict{PublicActionKey,NamedTuple},agenda.uses.omissions,missing)
            get!(pending,action) do
                (;writer=fact.writer,consumer=index,output_port=fact.output_port,producer=fact.producer,
                    relation=fact.relation,comparison_context=missing)
            end
        end
    end
    # Multiple independent omissions with distinct witnesses remain competing explanations.
    !unresolved && length(comparisons)==1 && push!(edges,only(comparisons))
    return unresolved || length(comparisons)>1
end

function compatible_omission_history(agenda,context,previous,obligation)
    refined_history(history_scope(agenda,context)) || return true
    writer = agenda.samples[obligation.writer]
    return relation_history_key(agenda,context,previous) == relation_history_key(agenda,context,writer.preceding)
end

function omitted_preparation_experiment(agenda,obs,decision,context)
    pending = get(agenda.uses.omissions,context,nothing)
    isnothing(pending) && return nothing
    for (action,obligation) in sort!(collect(pending);by=item->last(item).consumer)
        compatible_omission_history(agenda,context,agenda.previous,obligation) || continue
        source = agenda.samples[obligation.consumer]
        option = findfirst(item->action_key(item.action)==action,decision.ranked)
        isnothing(option) && continue
        actual = decision.ranked[option].action
        matches_outcome_binding(source,actual,decision.groups) || continue
        observed_failure(agenda,context,action,agenda.previous) && continue
        reads = unique([relation_refs(agenda.samples[obligation.writer]);relation_refs(source)])
        return (;action=actual,intent=:test_preparation_omission,tests=NamedTuple[],reads,obligation)
    end
    return nothing
end

function invalidate_relation_facts!(agenda,sample,before,after,after_groups,after_regions)
    lost = NamedTuple[]
    entry(fact,status,frame) = (;writer_event=relation_ref(agenda.samples[fact.writer]),
        fact.kind,fact.output_port,fact.action,fact.producer,fact.relation,status,frame,event=relation_ref(sample))
    boundary = sample.advanced || sample.state!="NOT_FINISHED"
    final_groups = nothing
    if !isempty(agenda.uses.roles)
        for (i,frame) in enumerate(after.frames)
            isempty(agenda.uses.roles) && break
            same_domain = size(frame) == size(last(before.frames))
            region_view = isnothing(after_regions) ? nothing : after_regions.frames[i]
            groups = if !boundary && same_domain && isnothing(region_view)
                Set(i==length(after.frames) && !isnothing(after_groups) ? after_groups : public_components(frame))
            end
            i==length(after.frames) && (final_groups=groups)
            for (shape,fact) in agenda.uses.roles
                if same_domain && !boundary && !isnothing(region_view)
                    x,y,_ = first(shape)
                    region_view.groups[region_view.owner[y+1,x+1]] == shape && continue
                elseif !isnothing(groups) && shape in groups
                    continue
                end
                status = boundary ? :scope_ended : !same_domain || i<length(after.frames) ? :unknown : :destroyed
                push!(lost,entry(fact,status,i))
                delete!(agenda.uses.roles,shape)
            end
        end
    end
    for (action,fact) in agenda.uses.permissions
        !boundary && action in after.available_actions && continue
        push!(lost,entry(fact,boundary ? :scope_ended : :destroyed,length(after.frames)))
        delete!(agenda.uses.permissions,action)
    end
    return lost,final_groups
end

function record_relation_use!(agenda,index,before,after,proposal,contract,feedback,before_groups,after_groups,after_regions)
    sample = agenda.samples[index]
    task_inputs = isnothing(proposal) ? NamedTuple[] : get(proposal,:fact_reads,NamedTuple[])
    eligible_before = length(agenda.uses.roles) + length(agenda.uses.permissions)
    unresolved_conditions = !isnothing(proposal) &&
        any(test->test.scope==:unverified,proposal.tests)
    edges = observed_inputs!(copy(task_inputs),agenda,sample)
    ambiguous_omission = omission_inputs!(edges,agenda,index,before,contract,before_groups)
    unresolved_conditions |= ambiguous_omission
    isempty(edges) || (agenda.uses.inputs[index]=edges)
    lost,groups = invalidate_relation_facts!(agenda,sample,before,after,after_groups,after_regions)
    created = NamedTuple[]
    if sample.state=="NOT_FINISHED" && !sample.advanced
        function write_fact(kind,port,producer,relation,action,key,table,patch)
            fact = (;kind,writer=index,output_port=port,producer,relation,action)
            patch_delta = foldl(patch;init=zero(UInt)) do delta,row
                x,y,old,new=row
                delta ⊻ hash((x,y,old)) ⊻ hash((x,y,new))
            end
            table[key] = merge(fact,(;patch,patch_delta))
            push!(created,merge(fact,(writer_event=relation_ref(sample),)))
        end
        for id in observed_action_gain(sample)
            write_fact(:available_action,0,nothing,"available_action",id,id,agenda.uses.permissions,PixelChange[])
        end
        if !isnothing(contract) && !scene_translation_unresolved(sample.effects)
            for (port,effect) in enumerate(sample.effects.effects)
                effect.family in (:pigment,:translation) || continue
                if !isnothing(after_regions)
                    view = last(after_regions.frames)
                    x,y,_ = first(effect.after)
                    view.groups[view.owner[y+1,x+1]] == effect.after || continue
                elseif isnothing(groups)
                    groups = Set(isnothing(after_groups) ? public_components(last(after.frames)) : after_groups)
                end
                isnothing(groups) || effect.after in groups || continue
                patch = PixelChange[]
                if length(sample.effects.effects)==1 && sample.effects.complete && isempty(sample.effects.residual) &&
                        before.available_actions==after.available_actions
                    a,b=last(before.frames),last(after.frames)
                    append!(patch,((x,y,a[y+1,x+1],b[y+1,x+1]) for (x,y) in effect.changed))
                end
                write_fact(:role_support,port,contract.key,contract.relations[port],nothing,
                    effect.after,agenda.uses.roles,patch)
            end
        end
    end
    pending = get(agenda.uses.omissions,sample.context,nothing)
    if !isnothing(pending)
        action = action_key(sample.effects.action)
        trial = get(pending,action,nothing)
        if !isnothing(trial) && compatible_omission_history(agenda,sample.context,sample.preceding,trial)
            delete!(pending,action)
        end
        isempty(pending) && delete!(agenda.uses.omissions,sample.context)
    end
    confirmed_task = if !isnothing(proposal)
        (;intent=proposal.intent,result=feedback.result,state=sample.state,advanced=sample.advanced,
            tests=[(;row.producer,row.status) for row in feedback.tests])
    end
    return (;established=created,invalidated=lost,inputs=edges,confirmed_task,eligible_before,
        unresolved_conditions,ambiguous_omission)
end
