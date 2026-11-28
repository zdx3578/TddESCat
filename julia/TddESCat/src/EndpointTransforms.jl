"""Public, zero-based inclusive bounds. A rectangle is present only if it is one solid component."""
const EndpointBox = NTuple{4,Int}  # left, top, right, bottom
struct EndpointView
    frame::Matrix{UInt8}
    groups::Vector{MotionShape}
    rectangles::Dict{EndpointBox,UInt8}
end

function EndpointView(frame, groups)
    rects = Dict{EndpointBox,UInt8}()
    for shape in groups
        x,u = extrema(first,shape)
        y,v = extrema(c->c[2],shape)
        length(shape) == (u-x+1)*(v-y+1) && (rects[(x,y,u,v)] = first(shape)[3])
    end
    return EndpointView(frame,groups,rects)
end

offset_box(box,point) = box .+ (point...,point...)
box_size(box) = (box[3]-box[1]+1, box[4]-box[2]+1)
inside_box(box,x,y) = box[1]<=x<=box[3] && box[2]<=y<=box[4]
box_in_frame(box,frame) = inside_box((0,0,size(frame,2)-1,size(frame,1)-1),box[1],box[2]) &&
    checkbounds(Bool,frame,box[4]+1,box[3]+1) && all(>(0),box_size(box))

abstract type EndpointTransform end

# Three edges and the pigment bind the affected role relative to the public action.
struct EdgeDisplacement <: EndpointTransform
    color::UInt8
    edge::Int
    fixed::EndpointBox  # moving edge is masked
    delta::Int
end

mask_edge(box,edge) = Base.setindex(box,0,edge)
function endpoint_input(rule::EdgeDisplacement,view,origin)
    found = nothing
    for (box,color) in view.rectangles
        color == rule.color || continue
        relative = offset_box(box,.-origin)
        mask_edge(relative,rule.edge) == rule.fixed || continue
        isnothing(found) || return nothing
        found = relative
    end
    return found
end

function endpoint_expectation(rule::EdgeDisplacement,input,view,origin)
    expected = Base.setindex(input,input[rule.edge]+rule.delta,rule.edge)
    absolute = offset_box(expected,origin)
    box_in_frame(absolute,view.frame) || return nothing
    return (;kind=:edge_displacement,known=1,total=1,source=offset_box(input,origin),box=absolute,color=Int(rule.color))
end

function endpoint_agreement(rule::EdgeDisplacement,claim,before,after)
    matched = get(after.rectangles,claim.box,nothing)==claim.color &&
        single_boundary_change(before,after,claim.source,claim.box,claim.color)
    return (;status=matched ? :established : :refuted,
        actual=(;color=get(after.rectangles,claim.box,nothing),single_boundary=matched))
end

# A nested rectangle might have swallowed another component of the same color, or
# split in two. Check the entire strip before treating it as one object's boundary.
function single_boundary_change(before,after,old,new,color)
    outer,inner,smaller_frame = if prod(box_size(old)) > prod(box_size(new))
        old,new,after.frame
    else
        new,old,before.frame
    end
    return all(inside_box(inner,x,y) || smaller_frame[y+1,x+1]!=color
        for y in outer[2]:outer[4] for x in outer[1]:outer[3])
end

function edge_examples(before,after,origin)
    examples = NamedTuple[]
    index = Dict{Tuple{UInt8,Int,EndpointBox},EndpointBox}()
    for (box,color) in after.rectangles
        get(before.rectangles,box,nothing)==color && continue
        for edge in 1:4
            index[(color,edge,mask_edge(box,edge))] = box
        end
    end
    for (old,color) in before.rectangles
        get(after.rectangles,old,nothing)==color && continue
        for edge in 1:4
            new = get(index,(color,edge,mask_edge(old,edge)),nothing)
            isnothing(new) && continue
            single_boundary_change(before,after,old,new,color) || continue
            left,right = offset_box(old,.-origin),offset_box(new,.-origin)
            rule = EdgeDisplacement(color,edge,mask_edge(left,edge),right[edge]-left[edge])
            push!(examples,(;rule,input=left,output=right,identity=("edge",color,edge,rule.fixed,rule.delta)))
        end
    end
    return examples
end

"""A bijection between fixed supports. Equal class labels mean still indistinguishable sources."""
struct SlotTransfer <: EndpointTransform
    boxes::Vector{EndpointBox}
    source::Vector{Int}
    target::Vector{Int}
end

function endpoint_input(rule::SlotTransfer,view,origin)
    colors = UInt8[]
    for relative in rule.boxes
        color = get(view.rectangles,offset_box(relative,origin),nothing)
        isnothing(color) && return nothing
        push!(colors,color)
    end
    return colors
end

# Intersect source/destination color histories. A bijection exists exactly when
# every class has equal multiplicity on the two sides. No assignment is guessed.
function refine_endpoint(rule::SlotTransfer,input,output)
    labels = Dict{Tuple{Int,UInt8},Int}()
    classify(classes,colors) = [get!(() -> length(labels)+1,labels,(k,c)) for (k,c) in zip(classes,colors)]
    source = classify(rule.source,input)
    target = classify(rule.target,output)
    sort(source)==sort(target) || return nothing
    source == rule.source && target == rule.target && return rule
    return SlotTransfer(rule.boxes,source,target)
end

function endpoint_expectation(rule::SlotTransfer,input,view,origin)
    first_color = Dict{Int,UInt8}()
    ambiguous = BitSet()
    for (label,color) in zip(rule.source,input)
        get!(first_color,label,color)==color || push!(ambiguous,label)
    end
    known = findall(label->label ∉ ambiguous,rule.target)
    return (;kind=:slot_transfer,known=length(known),boxes=[offset_box(rule.boxes[i],origin) for i in known],
        colors=[Int(first_color[rule.target[i]]) for i in known],total=length(input))
end

function endpoint_agreement(::SlotTransfer,claim,before,after)
    isempty(claim.boxes) && return (;status=:unresolved,actual=nothing)
    actual = [get(after.rectangles,box,nothing) for box in claim.boxes]
    return (;status=actual==claim.colors ? :established : :refuted,actual)
end

function slot_examples(before,after,origin)
    layouts = Dict{Pixel,Vector{EndpointBox}}()
    for box in keys(before.rectangles)
        push!(get!(Vector{EndpointBox},layouts,box_size(box)),box)
    end
    examples = NamedTuple[]
    for boxes in values(layouts)
        length(boxes)>=2 && all(b->haskey(after.rectangles,b),boxes) || continue
        sort!(boxes)
        input = [before.rectangles[b] for b in boxes]
        output = [after.rectangles[b] for b in boxes]
        input!=output && sort(input)==sort(output) || continue
        relative = [offset_box(b,.-origin) for b in boxes]
        initial = ones(Int,length(boxes))
        rule = SlotTransfer(relative,initial,initial)
        push!(examples,(;rule,input,output,identity=("slots",relative)))
    end
    return examples
end

refine_endpoint(rule::EdgeDisplacement,input,output) = rule
endpoint_version(rule::SlotTransfer,key) = semantic_hash([key,rule.source,rule.target])
open_correspondences(rule::SlotTransfer) = !allunique(rule.source)
open_correspondences(::EdgeDisplacement) = false

# Register observation families here. Each owns its role binding, forecast, refinement and measurement.
endpoint_examples(before,after,origin) =
    Iterators.flatten((edge_examples(before,after,origin),slot_examples(before,after,origin)))
