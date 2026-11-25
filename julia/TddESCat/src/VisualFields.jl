struct VisualValue
    width::Int
    height::Int
    mask::UInt64
    pigment::UInt8
end

struct VisualField
    box::Window
    background::UInt8
    scale::Int
end

function visual_value(frame, field::VisualField)
    box = field.box
    scale = field.scale
    scale > 0 && box.width % scale == box.height % scale == 0 || return nothing
    checkbounds(Bool,frame,box.y+box.height,box.x+box.width) || return nothing
    width,height = div(box.width,scale),div(box.height,scale)
    width*height <= 64 || return nothing
    mask = UInt64(0)
    pigment = nothing
    for y in 0:height-1, x in 0:width-1
        px,py = box.x+x*scale+1,box.y+y*scale+1
        value = frame[py,px]
        all(frame[py+v,px+u] == value for u in 0:scale-1 for v in 0:scale-1) ||
            return nothing
        value == field.background && continue
        isnothing(pigment) || pigment == value || return nothing
        pigment = value
        mask |= UInt64(1) << (y*width+x)
    end
    isnothing(pigment) && return nothing
    return VisualValue(width,height,mask,pigment)
end

function visual_motif(frame, box, background)
    left,top = box.x+box.width,box.y+box.height
    right,bottom = box.x,box.y
    ink = nothing
    for y in box.y:box.y+box.height-1, x in box.x:box.x+box.width-1
        c = frame[y+1,x+1]
        c <= 15 || return nothing
        c == background && continue
        isnothing(ink) || c == ink || return nothing
        ink = c
        left,right = min(left,x),max(right,x)
        top,bottom = min(top,y),max(bottom,y)
    end
    h,w = bottom-top+1,right-left+1
    min(h,w) >= 2 || return nothing
    for scale in reverse(1:gcd(h,w))
        h % scale == w % scale == 0 || continue
        min(h,w) >= 2scale || continue
        field = VisualField(Window(left,top,w,h),background,scale)
        value = visual_value(frame,field)
        isnothing(value) && continue
        n = count_ones(value.mask)
        2 < n < value.width*value.height || continue
        return (; field,value)
    end
    return nothing
end

function visual_motifs(frame, size_limit)
    height,width = size(frame)
    unique_fields = Dict{Tuple,NamedTuple}()
    for side in 4:min(size_limit,height,width), y in 1:height-side+1, x in 1:width-side+1
        c = frame[y,x]
        c <= 15 || continue
        edge = side-1
        c == frame[y+edge,x] == frame[y,x+edge] == frame[y+edge,x+edge] || continue
        all(c == frame[y,x+i] == frame[y+edge,x+i] == frame[y+i,x] == frame[y+i,x+edge]
            for i in 1:edge-1) || continue
        motif = visual_motif(frame,Window(x,y,side-2,side-2),c)
        isnothing(motif) && continue
        b = motif.field.box
        key = (b.x,b.y,b.width,b.height,c)
        unique_fields[key] = motif
    end
    # A small crop of the same diagram is not an independent symbol.
    motifs = sort!(collect(values(unique_fields));by=m->begin
        b = m.field.box
        (-b.width*b.height,b.y,b.x)
    end)
    maximal = NamedTuple[]
    for motif in motifs
        b = motif.field.box
        contained = any(maximal) do parent
            p = parent.field.box
            parent.field.background == motif.field.background && parent.value.pigment == motif.value.pigment &&
                p.x <= b.x && p.y <= b.y && b.x+b.width <= p.x+p.width && b.y+b.height <= p.y+p.height
        end
        contained || push!(maximal,motif)
    end
    return maximal
end

function motif_contrast_boundary(frame, field, maximum_margin)
    b = field.box
    for margin in 1:maximum_margin
        left,right = b.x+1-margin,b.x+b.width+margin
        top,bottom = b.y+1-margin,b.y+b.height+margin
        checkbounds(Bool,frame,top,left) && checkbounds(Bool,frame,bottom,right) || continue
        color = frame[top,left]
        color != field.background || continue
        all(frame[top,x] == frame[bottom,x] == color for x in left:right) &&
            all(frame[y,left] == frame[y,right] == color for y in top:bottom) && return true
    end
    return false
end

function rectangular_fields(frame, role_width, role_height)
    candidates = []
    for component in color_components(frame).groups
        x,y = anchor(component)
        w = maximum(first,component)-x+1
        h = maximum(c->c[2],component)-y+1
        length(component) == w*h && max(w,h) >= 4min(w,h) || continue
        max(w,h) >= max(role_width,role_height) && min(w,h) < min(role_width,role_height) || continue
        push!(candidates,(box=Window(x,y,w,h),pixel=first(component)[3]))
    end
    return candidates
end

function read_counter(frame, counter)
    b = counter.box
    observed = count(==(counter.pixel),@view frame[b.y+1:b.y+b.height,b.x+1:b.x+b.width])
    return div(observed,min(b.width,b.height))
end

function visual_transform(value::VisualValue, operation)
    w,h = value.width,value.height
    swap,flip_x,flip_y = operation
    width,height = swap ? (h,w) : (w,h)
    mask = UInt64(0)
    for y in 0:h-1, x in 0:w-1
        iszero(value.mask & (UInt64(1) << (y*w+x))) && continue
        u,v = swap ? (y,x) : (x,y)
        flip_x && (u=width-u-1)
        flip_y && (v=height-v-1)
        mask |= UInt64(1) << (v*width+u)
    end
    return VisualValue(width,height,mask,value.pigment)
end

const RECTANGLE_TRANSFORMS = [(swap,x,y) for swap in (false,true) for x in (false,true) for y in (false,true)]

function compatible_transforms(before, after)
    return filter(op->visual_transform(before,op) == after, RECTANGLE_TRANSFORMS)
end
