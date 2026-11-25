const METER_METHOD = "rectangular-strip-v1"
const METER_UNIT = "complete-cross-section"

struct MeterFace
    box::Window
    fill::UInt8
    rim::UInt8
    source::String
end

struct MeterBinding
    face::MeterFace
    blank::UInt8
    from_end::Bool
    calibrated_at::String
end

mutable struct MeterContext
    faces::Dict{NTuple{4,Int},MeterFace}
    bindings::Dict{NTuple{4,Int},MeterBinding}
    scene::Union{Nothing,Tuple{String,Int}}
end

MeterContext() = MeterContext(Dict(),Dict(),nothing)
meter_window(b::Window) = (b.x,b.y,b.width,b.height)
meter_length(b::Window) = max(b.width,b.height)
meter_thickness(b::Window) = min(b.width,b.height)
meter_axis(b::Window) = b.width > b.height ? 1 : 2
meter_point(b,u,v) = meter_axis(b) == 1 ? (b.x+u,b.y+v) : (b.x+v,b.y+u)
meter_identity(binding) = semantic_hash([METER_METHOD,METER_UNIT,meter_window(binding.face.box),
    binding.face.source,binding.face.fill,binding.face.rim,binding.blank,binding.from_end])
meter_contract() = Dict("method"=>METER_METHOD,"unit"=>METER_UNIT)

function meter_context!(context,observation)
    scene = (observation.guid,observation.levels_completed)
    if context.scene != scene || observation.action["id"] == 0
        empty!(context.faces)
        empty!(context.bindings)
        context.scene = scene
    end
    return context
end

function meter_rim(frame,b)
    left,right = b.x,b.x+b.width+1
    top,bottom = b.y,b.y+b.height+1
    checkbounds(Bool,frame,top,left) && checkbounds(Bool,frame,bottom,right) || return nothing
    ink = frame[top,left]
    all(x->frame[top,x] == frame[bottom,x] == ink,left:right) &&
        all(y->frame[y,left] == frame[y,right] == ink,top:bottom) || return nothing
    return ink
end

function bind_meter_faces!(context,frame,groups,event)
    for shape in groups
        x,y = anchor(shape)
        b = Window(x,y,maximum(first,shape)-x+1,maximum(cell->cell[2],shape)-y+1)
        length(shape) == b.width*b.height && meter_length(b) >= 4meter_thickness(b) || continue
        rim = meter_rim(frame,b)
        fill = first(shape)[3]
        (isnothing(rim) || rim == fill) && continue
        get!(context.faces,meter_window(b),MeterFace(b,fill,rim,event))
    end
end

function meter_strips(frame,face)
    b = face.box
    meter_rim(frame,b) == face.rim || return nothing
    strips = UInt8[]
    for u in 0:meter_length(b)-1
        x,y = meter_point(b,u,0)
        ink = frame[y+1,x+1]
        all(0:meter_thickness(b)-1) do v
            s,t = meter_point(b,u,v)
            frame[t+1,s+1] == ink
        end || return nothing
        push!(strips,ink)
    end
    return strips
end

function meter_value(strips, binding)
    isnothing(strips) && return nothing
    ordered = binding.from_end ? Iterators.reverse(strips) : strips
    n = 0
    empty_started = false
    for ink in ordered
        if ink == binding.blank
            empty_started = true
        elseif ink == binding.face.fill && !empty_started
            n += 1
        else
            return nothing
        end
    end
    return n
end

read_meter(frame,binding) = meter_value(meter_strips(frame,binding.face),binding)

function meter_layout(binding)
    box = binding.face.box
    return (meter_axis(box),meter_thickness(box),meter_length(box),binding.from_end)
end

function match_meter(source,meters)
    id = meter_identity(source)
    exact = findfirst(binding->meter_identity(binding) == id,meters)
    isnothing(exact) || return meters[exact]
    candidates = [binding for binding in meters if meter_layout(binding) == meter_layout(source)]
    return length(candidates) == 1 ? only(candidates) : nothing
end

function calibrate_meter(face,strips,event)
    any(isnothing,strips) && return nothing
    blanks = unique(ink for row in strips for ink in row if ink != face.fill)
    length(blanks) == 1 && only(blanks) != face.rim || return nothing
    candidates = [MeterBinding(face,only(blanks),side,event) for side in (false,true)]
    filter!(binding->all(row->!isnothing(meter_value(row,binding)),strips),candidates)
    return length(candidates) == 1 ? only(candidates) : nothing
end

function meter_ink(binding,n,u)
    index = binding.from_end ? meter_length(binding.face.box)-1-u : u
    return index < n ? binding.face.fill : binding.blank
end

function meter_support(binding,n)
    b = binding.face.box
    return sort!(ColorCell[(meter_point(b,u,v)...,binding.face.fill)
        for u in 0:meter_length(b)-1 for v in 0:meter_thickness(b)-1
        if meter_ink(binding,n,u) == binding.face.fill])
end

function meter_pixels(binding,from,to)
    b = binding.face.box
    return sort!(Pixel[meter_point(b,u,v)
        for u in 0:meter_length(b)-1 for v in 0:meter_thickness(b)-1
        if meter_ink(binding,from,u) != meter_ink(binding,to,u)])
end

function render_meter!(frame,binding,n)
    b = binding.face.box
    0 <= n <= meter_length(b) && !isnothing(read_meter(frame,binding)) || return false
    for u in 0:meter_length(b)-1, v in 0:meter_thickness(b)-1
        x,y = meter_point(b,u,v)
        frame[y+1,x+1] = meter_ink(binding,n,u)
    end
    return true
end

function meter_readings!(context,before,frames,groups,before_ref,event)
    live = [binding for (_,binding) in sort!(collect(context.bindings);by=first)
        if !isnothing(read_meter(before,binding))]
    bind_meter_faces!(context,before,groups,before_ref)
    readings = NamedTuple[]
    unresolved = String[]
    for (key,face) in sort!(collect(context.faces);by=first)
        strips = [meter_strips(frame,face) for frame in (before,frames...)]
        binding = get(context.bindings,key,nothing)
        if isnothing(binding)
            binding = calibrate_meter(face,strips,event)
            isnothing(binding) && continue
            context.bindings[key] = binding
        end
        values = [meter_value(row,binding) for row in strips]
        if any(isnothing,values)
            push!(unresolved,meter_identity(binding))
            continue
        end
        push!(readings,(binding=binding,values=Int[values...]))
    end
    return (;readings,unresolved,live)
end
