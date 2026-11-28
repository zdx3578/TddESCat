"""Live occurrence index. A port names the exact public effect in its writer receipt."""
mutable struct RelationUseIndex
    roles::Dict{MotionShape,NamedTuple}
    permissions::Dict{Int,NamedTuple}
    inputs::Dict{Int,Vector{NamedTuple}}
    omissions::Dict{String,Dict{PublicActionKey,NamedTuple}}
    omission_screens::Set{Tuple{Int,PublicActionKey,UInt}}
    signatures::Dict{String,UInt}
    rebound::Dict{Tuple,Dict{MotionShape,Vector{NamedTuple}}}
    rebound_receipts::Set{Int}
end

RelationUseIndex() = RelationUseIndex(Dict(),Dict(),Dict(),Dict(),Set(),Dict(),Dict(),Set())

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
    if proposal.intent in (:test_preparation_omission,:test_rebound_omission)
        trial = proposal.obligation
        relation_context(obs) == trial.comparison_context || error("Omission context changed before dispatch")
        original = agenda.samples[trial.consumer]
        for cause in trial.candidates
            fact = (;cause.writer,kind=:role_support,cause.producer,cause.relation,cause.output_port,action=nothing)
            rebound = proposal.intent == :test_rebound_omission
            usage = rebound ? :rebound_omission_test : :omission_test
            edge = input_edge(agenda,fact,0,usage)
            push!(edges,merge(edge,(scope=rebound ? :confounded_rebinding : :historical_contrast,through=cause.writer,
                baseline=relation_ref(original),reads=unique([edge.reads;relation_refs(original)]))))
        end
    elseif proposal.intent in (:execute_relation_policy,:continue_outcome_preparation,:continue_outcome_relation) &&
            !isnothing(proposal.obligation)
        usage = proposal.intent==:execute_relation_policy ? :policy_preparation_read : :outcome_preparation_read
        for role in get(proposal.obligation,:role_reads,())
            for (shape,fact) in agenda.uses.roles
                fact.output_port == role.port && relation_ref(agenda.samples[fact.writer]) == role.writer || continue
                semantic_hash(shape) == role.support || continue
                push!(edges,input_edge(agenda,fact,0,usage))
            end
        end
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
    fact.isolated && sample.context == source.next_context && return source.context
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
        prior = agenda.samples[witness.outcome]
        same_relation_response(prior,counter) || return true
        at = findfirst(witness.comparisons) do i
            compared = agenda.samples[i]
            compared.context == counter.context && action_key(compared.effects.action)==action_key(counter.effects.action) &&
                (!refined_history(history_scope(agenda,counter.context)) ||
                relation_history_key(agenda,counter.context,counter.preceding)==relation_history_key(agenda,counter.context,compared.preceding))
        end
        isnothing(at) && return true
        comparison = witness.comparisons[at]
        inputs = relation_inputs(agenda,witness.outcome)
        edge = findfirst(f->f.usage==:omission_contrast && f.comparison==comparison,inputs)
        isnothing(edge) && return true
        push!(withdrawn,(;preparation=inputs[edge].writer_event,outcome=relation_ref(prior),
            comparison=relation_ref(agenda.samples[comparison]),counterexample=relation_ref(counter),reason=:outcome_without_preparation))
        return false
    end
    return withdrawn
end

# Exact row spans outside the omitted fact footprints. Coordinates use the public zero-based frame.
function uncontrolled_spans(before,prepared,covered)
    spans = NTuple{5,Int}[]
    for y in axes(before,1)
        for x in axes(before,2)
            a,b = before[y,x],prepared[y,x]
            a == b && continue
            (x-1,y-1) in covered && continue
            if !isempty(spans)
                v,left,right,old,new = last(spans)
                if v == y-1 && right == x-2 && old == a && new == b
                    spans[end] = (v,left,x-1,old,new)
                    continue
                end
            end
            push!(spans,(y-1,x-1,x-1,Int(a),Int(b)))
        end
    end
    return spans
end

function omission_trial(agenda,index,context_writer,frame,roles,groups)
    row = agenda.samples[index]
    prior = agenda.samples[context_writer.writer]
    before = context_writer.source_frame
    size(before)==size(frame) || return nothing
    if row.effects.action["id"] == 6
        isnothing(row.binding) && return nothing
        point = action_key(row.effects.action)[2:3]
        selected = point_component(groups,point)
        isnothing(selected) && return nothing
        # Identical support plus an unchanged surrounding boundary proves the click still binds.
        footprint = effect_points(selected)
        for (x,y,color) in selected
            before[y+1,x+1] == color || return nothing
            for (dx,dy) in FOUR_NEIGHBORS
                u,v = x+dx,y+dy
                if (u,v) ∉ footprint && checkbounds(Bool,before,v+1,u+1) && before[v+1,u+1] == color
                    return nothing
                end
            end
        end
    end
    candidates = NamedTuple[]
    covered = Set{Pixel}()
    for fact in roles
        isempty(fact.patch) && continue
        all(fact.patch) do (x,y,a,b)
            before[y+1,x+1]==a && frame[y+1,x+1]==b
        end || continue
        push!(candidates,(;fact.writer,fact.output_port,fact.producer,fact.relation))
        union!(covered,((x,y) for (x,y,_,_) in fact.patch))
    end
    # The proposed context must really omit its named preparation in the final public observation.
    any(f->f.writer==context_writer.writer && f.output_port==context_writer.output_port,candidates) || return nothing
    sort!(candidates;by=f->(f.writer,f.output_port))
    spans = uncontrolled_spans(before,frame,covered)
    added = sort(setdiff(row.available,prior.available))
    removed = sort(setdiff(prior.available,row.available))
    uncontrolled = (;pixel_spans=spans,available_added=added,available_removed=removed,
        observed_before=prior.effects.before_id,prepared_before=row.effects.before_id)
    isolated = length(candidates)==1 && isempty(spans) && isempty(added) && isempty(removed)
    return (;context_writer.writer,context_writer.output_port,context_writer.producer,context_writer.relation,
        consumer=index,comparison_context=prior.context,candidates,uncontrolled,isolated)
end

function comparable_visits(agenda,context,action,writer)
    seen = get(agenda.visits,(context,action),Int[])
    isempty(agenda.uses.rebound_receipts) || (seen=filter(i->i ∉ agenda.uses.rebound_receipts,seen))
    refined_history(history_scope(agenda,context)) || return seen
    context == writer.context || return Int[]
    history = relation_history_key(agenda,context,writer.preceding)
    return filter(i->relation_history_key(agenda,context,agenda.samples[i].preceding)==history,seen)
end

function omission_inputs!(edges,agenda,index,before,contract,before_groups)
    row = agenda.samples[index]
    proposed = NamedTuple[]
    confounded = NamedTuple[]
    empty_result = (;ambiguous=false,proposed,confounded)
    action = action_key(row.effects.action)
    frame = last(before.frames)
    if row.unchanged && !row.advanced && row.state == "NOT_FINISHED"
        screen = screen_signature(agenda.uses,row.context,frame)
        push!(agenda.uses.omission_screens,(row.level,action,screen))
        return empty_result
    end
    (row.advanced || row.state=="WIN" || !isnothing(contract)) || return empty_result
    row.state == "GAME_OVER" && return empty_result
    roles = sort!(collect(values(agenda.uses.roles));by=f->(f.writer,f.output_port))
    comparisons = NamedTuple[]
    conflicted = false
    inspected = Set{String}()
    for fact in roles
        isempty(fact.patch) && continue
        writer = agenda.samples[fact.writer]
        missing = omitted_context(agenda,row,frame,fact,writer)
        if !isnothing(fact.producer) && !isnothing(missing) && missing != row.context
            seen = comparable_visits(agenda,missing,action,writer)
            at = findlast(seen) do i
                other = agenda.samples[i]
                i < index && other.level == row.level && other.unchanged && !other.advanced &&
                    other.state=="NOT_FINISHED" && !isnothing(other.binding)==!isnothing(row.binding) &&
                    (isnothing(other.binding) || other.binding.appearance==row.binding.appearance)
            end
            if !isnothing(at)
                if any(i->i<index && same_relation_response(row,agenda.samples[i]),seen)
                    conflicted = true
                else
                    push!(comparisons,input_edge(agenda,fact,0,:omission_contrast;comparison=seen[at]))
                end
            end
        end

        # Source contexts are publicly reached. A partial inverse can motivate a test there even
        # when it cannot explain the complete transition. Keep joint omissions and residuals visible.
        context = writer.context
        context == row.context && continue
        action[1] in writer.available || continue
        context in inspected && continue
        pending = get(agenda.uses.omissions,context,nothing)
        !isnothing(pending) && haskey(pending,action) && continue
        seen = comparable_visits(agenda,context,action,writer)
        !isempty(seen) && !row.advanced && row.state!="WIN" && continue
        groups = before_groups
        if action[1]==6 && isnothing(groups)
            before_groups = groups = public_components(frame)
        end
        trial = omission_trial(agenda,index,fact,frame,roles,groups)
        isnothing(trial) && continue
        push!(inspected,context)
        if isempty(seen)
            obligations = get!(Dict{PublicActionKey,NamedTuple},agenda.uses.omissions,context)
            obligations[action] = trial
            index_rebound_omission!(agenda,trial,fact.source_frame,action,groups)
            push!(proposed,(;context,action=concrete_action(action),trial.candidates,trial.isolated,
                observed_before=trial.uncontrolled.observed_before,prepared_before=trial.uncontrolled.prepared_before,
                uncontrolled_pixels=sum((r[3]-r[2]+1 for r in trial.uncontrolled.pixel_spans);init=0),
                trial.uncontrolled.available_added,trial.uncontrolled.available_removed))
        elseif !trial.isolated
            prior = last(seen)
            compared = agenda.samples[prior]
            status = same_relation_response(row,compared) ? :same_response :
                compared.unchanged ? :unchanged_observation : :other_response
            push!(confounded,(;trial,comparison=prior,event=relation_ref(compared),status))
        end
    end
    # Each admitted input must have its own single-factor omission. An alias sharing
    # one comparison or a success without the factor prevents that attribution.
    independent = allunique([agenda.samples[e.comparison].context for e in comparisons])
    if independent && !conflicted
        append!(edges,sort!(comparisons;by=e->(e.writer,e.output_port)))
    end
    return (;ambiguous=conflicted || !independent || isempty(comparisons) && !isempty(confounded),proposed,confounded)
end

function compatible_omission_history(agenda,context,previous,obligation)
    refined_history(history_scope(agenda,context)) || return true
    writer = agenda.samples[obligation.writer]
    return relation_history_key(agenda,context,previous) == relation_history_key(agenda,context,writer.preceding)
end

function omission_evidence_refs(agenda,obligation)
    sources = [obligation.writer,obligation.consumer]
    append!(sources,(fact.writer for fact in obligation.candidates))
    return unique([ref for i in unique(sources) for ref in relation_refs(agenda.samples[i])])
end

# Exact source supports are lookup keys; a protected pixel is never considered an
# external change. Keep the original public frame only once per source record.
function index_rebound_omission!(agenda,trial,reference,action,groups)
    source=agenda.samples[trial.writer]
    target=agenda.samples[trial.consumer]
    source.preceding==0 && return
    Set(source.available)==Set(target.available) || return
    parts=[agenda.samples[f.writer].effects.effects[f.output_port] for f in trial.candidates]
    any(p->isempty(p.before) || isempty(p.after),parts) && return
    selected=action[1]==6 ? point_component(groups,action[2:3]) : nothing
    action[1]==6 && isnothing(selected) && return
    protected=Set{Pixel}()
    function protect(shape)
        for (x,y,_) in shape
            push!(protected,(x,y))
            for (dx,dy) in FOUR_NEIGHBORS
                u,v=x+dx,y+dy
                checkbounds(Bool,reference,v+1,u+1) && push!(protected,(u,v))
            end
        end
    end
    for part in parts
        protect(part.before)
        protect(part.after)
    end
    isnothing(selected) || protect(selected)
    anchor=argmin(length,[p.before for p in parts])
    bucket=(source.attempt,source.level,Tuple(sort(source.available)),previous_key(agenda,source.preceding))
    by_role=get!(Dict{MotionShape,Vector{NamedTuple}},agenda.uses.rebound,bucket)
    support_id=semantic_hash([(p.before,p.after) for p in parts])
    push!(get!(Vector{NamedTuple},by_role,anchor),(;trial,reference,action,selected,protected,support_id,
        inputs=[p.before for p in parts]))
end

function unindex_rebound_omission!(agenda,trial,action)
    source=agenda.samples[trial.writer]
    bucket=(source.attempt,source.level,Tuple(sort(source.available)),previous_key(agenda,source.preceding))
    by_role=get(agenda.uses.rebound,bucket,nothing)
    isnothing(by_role) && return
    anchor=argmin(length,[agenda.samples[f.writer].effects.effects[f.output_port].before for f in trial.candidates])
    records=get(by_role,anchor,nothing)
    isnothing(records) && return
    filter!(r->r.action!=action || r.trial!==trial,records)
    isempty(records) && delete!(by_role,anchor)
    isempty(by_role) && delete!(agenda.uses.rebound,bucket)
end

function rebound_omission_experiment(agenda,obs,decision,context)
    uses=agenda.uses
    (isempty(uses.rebound) || agenda.previous==0 || obs.state!="NOT_FINISHED") && return nothing
    bucket=(agenda.attempt,obs.levels_completed,Tuple(sort(obs.available_actions)),previous_key(agenda,agenda.previous))
    by_role=get(uses.rebound,bucket,nothing)
    isnothing(by_role) && return nothing
    groups=get(decision,:groups,nothing)
    isnothing(groups) && (groups=public_components(last(obs.frames)))
    matched=[record for shape in groups for record in get(by_role,shape,())]
    isempty(matched) && return nothing
    sort!(matched;by=r->(r.trial.consumer,r.trial.writer,r.action))
    seen_groups=Set(groups)
    frame=last(obs.frames)
    for record in matched
        trial=record.trial
        # An exact trial remains available through the original scheduler.
        context==trial.comparison_context && continue
        table=get(uses.omissions,trial.comparison_context,nothing)
        (isnothing(table) || get(table,record.action,nothing)!==trial) && continue
        all(in(seen_groups),record.inputs) || continue
        size(frame)==size(record.reference) || continue
        all(p->frame[p[2]+1,p[1]+1]==record.reference[p[2]+1,p[1]+1],record.protected) || continue
        if !isnothing(record.selected)
            record.selected in seen_groups || continue
            template=shape_template(record.selected)
            count(g->length(g)==length(template) && shape_template(g)==template,groups)==1 || continue
        end
        source=agenda.samples[trial.writer]
        a,b=history_scope(agenda,source.context),history_scope(agenda,context)
        scope=RelationHistoryScope(max(a.width,b.width),a.receipts||b.receipts)
        sources=frontier_prior(agenda,source.preceding,scope.width)
        latest=frontier_prior(agenda,agenda.previous,scope.width)
        all(i->agenda.samples[i].attempt==source.attempt && agenda.samples[i].level==source.level &&
            !agenda.samples[i].advanced && agenda.samples[i].state=="NOT_FINISHED",Iterators.flatten((sources,latest))) || continue
        source_history=relation_history_key(agenda,source.context,source.preceding;scope)
        live_history=relation_history_key(agenda,context,agenda.previous;scope)
        length(source_history)==scope.width && source_history==live_history || continue
        observed_failure(agenda,context,record.action,agenda.previous) && continue
        observed_failure(agenda,source.context,record.action,source.preceding) && continue
        check=(:rebound_omission,bucket,record.support_id,record.action,live_history,context)
        check in agenda.checked_effects && continue
        # A confirmed action at this same binding and history already tested it.
        any(i->relation_history_key(agenda,context,agenda.samples[i].preceding;scope)==live_history,
            get(agenda.visits,(context,record.action),Int[])) && continue
        spans=uncontrolled_spans(record.reference,frame,record.protected)
        isempty(spans) && continue
        current=relation_ref(agenda.samples[agenda.previous])
        uncontrolled=(;pixel_spans=spans,available_added=Int[],available_removed=Int[],
            observed_before=source.effects.before_id,prepared_before=current)
        obligation=merge(trial,(;comparison_context=context,source_context=source.context,source_event=source.effects.before_id,
            paired_scope=:confounded_rebinding,uncontrolled,source_uncontrolled=trial.uncontrolled,isolated=false,
            before=current,history_width=scope.width,history_receipts=scope.receipts))
        indices=[sources;latest]
        reads=unique([omission_evidence_refs(agenda,trial);relation_ref.(agenda.samples[indices]);current])
        return (;action=concrete_action(record.action),intent=:test_rebound_omission,tests=NamedTuple[],reads,obligation,
            rebound_check=check)
    end
    return nothing
end

function omitted_preparation_experiment(agenda,obs,decision,context)
    pending = get(agenda.uses.omissions,context,nothing)
    isnothing(pending) && return nothing
    for (action,obligation) in sort!(collect(pending);by=item->last(item).consumer)
        compatible_omission_history(agenda,context,agenda.previous,obligation) || continue
        source = agenda.samples[obligation.consumer]
        action[1] in obs.available_actions || continue
        if action[1]==6 && !checkbounds(Bool,last(obs.frames),action[3]+1,action[2]+1)
            continue
        end
        actual = concrete_action(action)
        matches_outcome_binding(source,actual,decision.groups) || continue
        observed_failure(agenda,context,action,agenda.previous) && continue
        reads = omission_evidence_refs(agenda,obligation)
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
    rebound = !isnothing(proposal) && proposal.intent==:test_rebound_omission
    omissions = if rebound
        push!(agenda.uses.rebound_receipts,index)
        push!(agenda.checked_effects,proposal.rebound_check)
        (;ambiguous=true,proposed=NamedTuple[],confounded=NamedTuple[])
    else
        omission_inputs!(edges,agenda,index,before,contract,before_groups)
    end
    (sample.advanced || sample.state!="NOT_FINISHED") && empty!(agenda.uses.rebound)
    ambiguous_omission = omissions.ambiguous
    unresolved_conditions |= ambiguous_omission
    isempty(edges) || (agenda.uses.inputs[index]=edges)
    lost,groups = invalidate_relation_facts!(agenda,sample,before,after,after_groups,after_regions)
    created = NamedTuple[]
    if sample.state=="NOT_FINISHED" && !sample.advanced
        isolated = length(sample.effects.effects)==1 && sample.effects.complete &&
            isempty(sample.effects.residual) && Set(before.available_actions)==Set(after.available_actions)
        function write_fact(kind,port,producer,relation,action,key,table,patch)
            fact = (;kind,writer=index,output_port=port,producer,relation,action)
            patch_delta = foldl(patch;init=zero(UInt)) do delta,row
                x,y,old,new=row
                delta ⊻ hash((x,y,old)) ⊻ hash((x,y,new))
            end
            table[key] = merge(fact,(;patch,patch_delta,isolated,source_frame=kind==:role_support ? last(before.frames) : nothing))
            push!(created,merge(fact,(writer_event=relation_ref(sample),)))
        end
        for id in observed_action_gain(sample)
            write_fact(:available_action,0,nothing,"available_action",id,id,agenda.uses.permissions,PixelChange[])
        end
        # An exact in-place colour change is observable even if other correspondences
        # remain unresolved. Without a joint producer it may only motivate an experiment.
        partial_pigment = isnothing(contract)
        if !scene_translation_unresolved(sample.effects)
            for (port,effect) in enumerate(sample.effects.effects)
                effect.family in (:pigment,:translation) || continue
                partial_pigment && effect.family != :pigment && continue
                if !isnothing(after_regions)
                    view = last(after_regions.frames)
                    x,y,_ = first(effect.after)
                    view.groups[view.owner[y+1,x+1]] == effect.after || continue
                elseif isnothing(groups)
                    groups = Set(isnothing(after_groups) ? public_components(last(after.frames)) : after_groups)
                end
                isnothing(groups) || effect.after in groups || continue
                a,b = last(before.frames),last(after.frames)
                patch = PixelChange[(x,y,a[y+1,x+1],b[y+1,x+1]) for (x,y) in effect.changed]
                producer = partial_pigment ? nothing : contract.key
                relation = partial_pigment ? effect_relation(effect.family,shape_template(effect.before),effect.values) :
                    contract.relations[port]
                write_fact(:role_support,port,producer,relation,nothing,
                    effect.after,agenda.uses.roles,patch)
            end
        end
    end
    pending = get(agenda.uses.omissions,sample.context,nothing)
    if !isnothing(pending) && !rebound
        action = action_key(sample.effects.action)
        trial = get(pending,action,nothing)
        if !isnothing(trial) && compatible_omission_history(agenda,sample.context,sample.preceding,trial)
            unindex_rebound_omission!(agenda,trial,action)
            delete!(pending,action)
        end
        isempty(pending) && delete!(agenda.uses.omissions,sample.context)
    end
    confirmed_task = if !isnothing(proposal)
        (;intent=proposal.intent,result=feedback.result,state=sample.state,advanced=sample.advanced,
            tests=[(;row.producer,row.status) for row in feedback.tests])
    end
    return (;established=created,invalidated=lost,inputs=edges,confirmed_task,eligible_before,
        unresolved_conditions,ambiguous_omission,proposed_omissions=omissions.proposed,
        confounded_omissions=omissions.confounded)
end
