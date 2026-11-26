const FOUR_NEIGHBORS = ((1, 0), (-1, 0), (0, 1), (0, -1))
const EIGHT_NEIGHBORS = (FOUR_NEIGHBORS..., (1, 1), (1, -1), (-1, 1), (-1, -1))

function color_components(frame::AbstractMatrix{UInt8}, connectivity::Int=4)
    steps = connectivity == 4 ? FOUR_NEIGHBORS : connectivity == 8 ? EIGHT_NEIGHBORS :
        throw(ArgumentError("Connectivity must be 4 or 8"))
    owner = zeros(Int, size(frame))
    groups = Vector{ColorCell}[]
    for y in axes(frame, 1), x in axes(frame, 2)
        owner[y, x] == 0 || continue
        color = frame[y, x]
        number = length(groups) + 1
        group, frontier = ColorCell[], [(x, y)]
        owner[y, x] = number
        while !isempty(frontier)
            i, j = pop!(frontier)
            push!(group, (i - 1, j - 1, color))
            for (dx, dy) in steps
                u, v = i + dx, j + dy
                if checkbounds(Bool, frame, v, u) && owner[v, u] == 0 && frame[v, u] == color
                    owner[v, u] = number
                    push!(frontier, (u, v))
                end
            end
        end
        sort!(group)
        push!(groups, group)
    end
    return (groups=groups, owner=owner)
end

struct FrameRegions
    groups::Vector{Vector{ColorCell}}
    owner::Matrix{Int}
    boundaries::Dict{Tuple{Int,Int},Int}
    exterior::Vector{Int}
end

function frame_regions(frame)
    parts = color_components(frame)
    borders = Dict{Tuple{Int,Int},Int}()
    exterior = zeros(Int,length(parts.groups))
    height,width = size(frame)
    for y in axes(frame,1), x in axes(frame,2)
        region = parts.owner[y,x]
        exterior[region] += (x == 1) + (x == width) + (y == 1) + (y == height)
        for (dx,dy) in ((1,0),(0,1))
            checkbounds(Bool,parts.owner,y+dy,x+dx) || continue
            adjacent = parts.owner[y+dy,x+dx]
            region == adjacent && continue
            key = minmax(region,adjacent)
            borders[key] = get(borders,key,0)+1
        end
    end
    return FrameRegions(parts.groups,parts.owner,borders,exterior)
end

struct ReceiptRegions
    event::String
    frames::Vector{FrameRegions}
    differences::Vector{Union{Nothing,Int}}
end

function receipt_regions(entry; previous=nothing)
    entry.event["completion"] == "confirmed" || error("Only confirmed receipts can publish regions")
    frames = entry.observation.frames
    entry.event["frame_count"] == length(frames) || error("Region receipt lost frames")
    regions = FrameRegions[]
    differences = Union{Nothing,Int}[]
    earlier = isnothing(previous) ? nothing : last(previous.observation.frames)
    if !isnothing(previous)
        entry.event["before_ref"] == previous.event["event_id"] || error("Region receipt predecessor mismatch")
    end
    for frame in frames
        change = isnothing(earlier) || size(earlier) != size(frame) ? nothing :
            count(pair -> first(pair) != last(pair),zip(earlier,frame))
        push!(differences,change)
        region = change == 0 && !isempty(regions) ? last(regions) : frame_regions(frame)
        push!(regions,region)
        earlier = frame
    end
    return ReceiptRegions(entry.event["event_id"],regions,differences)
end

function support_candidates(frame; max_support_pixels=96)
    positive_integer(max_support_pixels) || throw(ArgumentError("Invalid support limit"))
    parts = color_components(frame)
    candidates = filter(group -> length(group) <= max_support_pixels, parts.groups)
    adjacent = Set{Tuple{Int,Int}}()
    for y in axes(frame, 1), x in axes(frame, 2)
        a = parts.owner[y, x]
        for (dx, dy) in ((1, 0), (0, 1))
            u, v = x + dx, y + dy
            if checkbounds(Bool, frame, v, u)
                b = parts.owner[v, u]
                if a != b && length(parts.groups[a]) + length(parts.groups[b]) <= max_support_pixels
                    push!(adjacent, minmax(a, b))
                end
            end
        end
    end
    for (a, b) in sort!(collect(adjacent))
        push!(candidates, sort!(vcat(parts.groups[a], parts.groups[b])))
    end
    return candidates
end

struct SupportCorrespondence
    before::Vector{ColorCell}
    after::Vector{ColorCell}
    delta::Pixel
    source_before::Vector{PixelSource}
    source_after::Vector{PixelSource}
    full_after_candidate::Bool
end

function witnesses(cells, ref)
    return [PixelSource(ref.event_id, ref.frame_index, x, y, ref.interpretation) for (x, y, _) in cells]
end

function correspondence_candidates(before, after, source_before, source_after;
        max_support_pixels=96, max_work=250_000, max_witnesses=10_000)
    size(before) == size(after) || return (candidates=SupportCorrespondence[],
        complete=false, reason="frame_shape_changed", work=0)
    all(positive_integer, (max_work, max_witnesses)) || throw(ArgumentError("Invalid grounding budget"))
    supports_before = support_candidates(before; max_support_pixels)
    supports_after = Set(Tuple(support) for support in support_candidates(after; max_support_pixels))
    by_color = [Pixel[] for _ in 1:16]
    for y in axes(after, 1), x in axes(after, 2)
        push!(by_color[Int(after[y, x]) + 1], (x - 1, y - 1))
    end
    candidates = SupportCorrespondence[]
    work = 0
    for shape in supports_before
        px, py, color = argmin(cell -> length(by_color[Int(cell[3]) + 1]), shape)
        for (x, y) in by_color[Int(color) + 1]
            if work + length(shape) > max_work || length(candidates) >= max_witnesses
                return (candidates=candidates, complete=false, reason="grounding_budget", work=work)
            end
            work += length(shape)
            dx, dy = x - px, y - py
            all(shape) do (u, v, pigment)
                q, r = u + dx + 1, v + dy + 1
                checkbounds(Bool, after, r, q) && after[r, q] == pigment
            end || continue
            support = [(u + dx, v + dy, pigment) for (u, v, pigment) in shape]
            push!(candidates, SupportCorrespondence(shape, support, (dx, dy),
                witnesses(shape, source_before), witnesses(support, source_after),
                Tuple(support) in supports_after))
        end
    end
    return (candidates=candidates, complete=true, reason=nothing, work=work)
end

function ground_event(previous, current; interpretation="finite-pixel-v1", kwargs...)
    current.event["before_ref"] == previous.event["event_id"] ||
        throw(ArgumentError("Grounding requires the committed predecessor"))
    before_frames = previous.observation.frames
    after_frames = current.observation.frames
    pre = (event_id=previous.event["event_id"], frame_index=length(before_frames) - 1, interpretation=interpretation)
    post = (event_id=current.event["event_id"], frame_index=length(after_frames) - 1, interpretation=interpretation)
    before, after = last(before_frames), last(after_frames)
    result = correspondence_candidates(before, after, pre, post; kwargs...)
    # A difference indexes evidence. It does not define the support of a role.
    changed = frame_difference(before, after)
    return merge(result, (action=current.observation.action, changed=changed,
        before_event=pre.event_id, after_event=post.event_id, scope="adjacent_components_integer_translation"))
end

function scene_transform_candidates(correspondences)
    grouped = Dict{Pixel,Vector{SupportCorrespondence}}()
    for candidate in correspondences
        candidate.delta == (0, 0) && continue
        push!(get!(Vector{SupportCorrespondence}, grouped, candidate.delta), candidate)
    end
    return filter(collect(grouped)) do (_, witnesses)
        any(isdisjoint(a.before, b.before) for a in witnesses for b in witnesses)
    end
end
