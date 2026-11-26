struct MeterTransition
    action::Int
    patch::Tuple
    used::Bool
    moved::Bool
    before::Int
    after::Int
    event::String
end

mutable struct MeterDynamics
    local_rows::Vector{MeterTransition}
    gain_rows::Vector{MeterTransition}
end

MeterDynamics() = MeterDynamics(MeterTransition[],MeterTransition[])

function record_meter_transition!(memory,action,patch,used,moved,before,after,event)
    row = MeterTransition(action,patch,used,moved,before,after,event)
    push!(memory.local_rows,row)
    moved && after > before && push!(memory.gain_rows,row)
    return row
end

function fit_meter_dynamics(memory)
    gains = Set(row.patch for row in memory.gain_rows)
    at_site = Dict{Tuple{Tuple,Bool},Vector{MeterTransition}}()
    ordinary = Dict{Tuple{Int,Bool},Vector{MeterTransition}}()
    for row in [memory.gain_rows;memory.local_rows]
        if row.patch in gains && row.moved
            push!(get!(Vector{MeterTransition},at_site,(row.patch,row.used)),row)
        end
    end
    for row in memory.local_rows
        row.after <= row.before && row.patch ∉ gains || continue
        push!(get!(Vector{MeterTransition},ordinary,(row.action,row.moved)),row)
    end
    return (;gains,at_site,ordinary)
end

function meter_result(rows,before,capacity)
    isempty(rows) && return nothing
    exact = [row for row in rows if row.before == before]
    if !isempty(exact)
        all(row->row.after == first(exact).after,exact) || return nothing
        return (value=first(exact).after,reads=unique([row.event for row in exact]))
    end
    # Admit both supported interpretations of a positive transfer. A single
    # refill observation may be compatible with a fixed delta and a fixed result.
    candidates = Int[]
    deltas = unique(row.after-row.before for row in rows if 0 < row.after < capacity)
    if isempty(deltas)
        deltas = unique(row.after-row.before for row in rows)
    end
    if length(deltas) == 1 && all(clamp(row.before+only(deltas),0,capacity) == row.after for row in rows)
        push!(candidates,clamp(before+only(deltas),0,capacity))
    end
    if allequal(row.after for row in rows) &&
            (any(row->row.after > row.before,rows) || length(unique(row.before for row in rows)) > 1)
        push!(candidates,first(rows).after)
    end
    isempty(candidates) || allequal(candidates) || return nothing
    isempty(candidates) && return nothing
    return (value=first(candidates),reads=unique([row.event for row in rows]))
end

function meter_transition(model,action,patch,before,capacity;used=false,moved=true)
    if moved && patch in model.gains
        rows = get(model.at_site,(patch,used),MeterTransition[])
        directed = [row for row in rows if row.action == action]
        candidate = meter_result(isempty(directed) ? rows : directed,before,capacity)
        if !used || !isempty(rows)
            return candidate
        end
        # A repeat without evidence cannot count on another acquisition.
        # Its conservative execution cost still uses witnessed ordinary moves.
    end
    rows = get(model.ordinary,(action,moved),MeterTransition[])
    return meter_result(rows,before,capacity)
end

function visual_meter_prediction(control, model, action, patch, charge, used; moved=true)
    isnothing(control.resource) && return (value=charge,reads=String[])
    return meter_transition(model,action,patch,charge,meter_length(control.resource.face.box);
        used,moved)
end
