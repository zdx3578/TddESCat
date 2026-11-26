"""One confirmed attempt at a bound relation, with distinct public outcomes."""
struct GoalSample
    contact::ContactSample
    entered::Bool
    advanced::Bool
    won::Bool
    attempt::Int
end

function goal_sample(contact::ContactSample, before, after;attempt=0)
    contact.before == before.event["event_id"] && contact.event == after.event["event_id"] ||
        error("Goal sample differs from its public intervention")
    contact.level == before.observation.levels_completed &&
        contact.action == after.observation.action["id"] ||
        error("Goal sample has the wrong binding or action")
    advanced = after.observation.levels_completed > before.observation.levels_completed
    advanced == (contact.outcome == :progress) || error("Contact and public advancement disagree")
    return GoalSample(contact,contact.outcome in (:entered,:progress),advanced,
        advanced && after.observation.state == "WIN",attempt)
end

function goal_sample_record(sample::GoalSample)
    return (;event=sample.contact.event,before=sample.contact.before,
        source=sample.contact.motion_event,site=sample.contact.site.event,
        entered=sample.entered,advanced=sample.advanced,won=sample.won,attempt=sample.attempt)
end

"""Fit an advancement relation from confirmed contacts before this decision."""
function learned_advancement(control, previous_action, before_ref)
    model = fit_progress_relations([row.contact for row in control.goal_samples if row.entered])
    isnothing(model.model) && return nothing
    facts = contact_facts(control,previous_action)
    isempty(facts.remaining) && return nothing
    # Instances are bindings, and never part of the learned relation's identity.
    reads = unique([model.reads;facts.domain_reads])
    return (;relation="public_advancement",model=model.model,fit=model,facts,before=before_ref,
        reads,scope=facts.domain_version,targets=Set(first.(facts.remaining)))
end

function learned_goal_record(goal)
    return (;relation=goal.relation, model=goal.model, scope=goal.scope, before=goal.before,
        examples=goal.fit.samples, rules=goal.fit.rules, reads=goal.reads)
end

function observed_site_status(frame, site::VisualSite, point, role)
    box = site.field.box
    checkbounds(Bool,frame,box.y+1,box.x+1) &&
        checkbounds(Bool,frame,box.y+box.height,box.x+box.width) || return nothing
    any(((x,y,_),)->in_window(box,point[1]+x,point[2]+y),role) && return nothing
    observed = visual_value(frame,site.field)
    if isnothing(observed)
        return all(==(site.field.background),@view frame[box.y+1:box.y+box.height,box.x+1:box.x+box.width]) ?
            :disappeared : nothing
    end
    return observed == site.value ? :unchanged : :changed
end

"""A site remains an obligation until its post-contact state is visible."""
function update_contact_sites!(control, spatial, resulting)
    isempty(control.site_entries) && return NamedTuple[]
    frame = last(resulting.observation.frames)
    role = spatial.role
    here = locate_role(frame,role)
    isnothing(here) && return NamedTuple[]
    source = resulting.event["event_id"]
    changes = NamedTuple[]
    for point in sort!(collect(keys(control.site_entries)))
        entry = control.site_entries[point]
        site = get(control.targets,point,nothing)
        isnothing(site) && continue
        status = observed_site_status(frame,site,here,role)
        isnothing(status) && continue
        if status in (:disappeared,:changed)
            point in control.matched && continue
            push!(control.matched,point)
        elseif point ∉ control.matched
            delete!(control.site_entries,point)
            continue
        else
            delete!(control.matched,point)
            delete!(control.site_entries,point)
            status = :reopened
        end
        control.site_status[point] = source
        push!(changes,(;point,entered=entry,observed=source,status,site,role))
        status in (:disappeared,:changed) && (control.site_completions[entry] = last(changes))
    end
    return changes
end
