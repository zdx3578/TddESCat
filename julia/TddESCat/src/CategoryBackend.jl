import Catlab

const SUPPORT_CATEGORY = Catlab.ACSetCategory(Catlab.CSetCat(Catlab.Graph()))

struct SupportGraph
    graph::Catlab.Graph
    cells::Vector{ColorCell}
end

function support_graph(cells)
    graph = Catlab.Graph(length(cells))
    index = Dict((x, y) => i for (i, (x, y, _)) in enumerate(cells))
    for (i, (x, y, _)) in enumerate(cells), (dx, dy) in ((1, 0), (0, 1))
        target = get(index, (x + dx, y + dy), 0)
        target > 0 && Catlab.add_edge!(graph, i, target)
    end
    return SupportGraph(graph, cells)
end

function match_pattern(pattern::SupportGraph, scene::SupportGraph; max_witnesses=32)
    positive_integer(max_witnesses) && max_witnesses < typemax(Int) ||
        throw(ArgumentError("Invalid homomorphism budget"))
    function compatible(map)
        isempty(pattern.cells) && return true
        x, y, _ = first(pattern.cells)
        u, v, _ = scene.cells[map[:V](1)]
        return all(enumerate(pattern.cells)) do (i, (px, py, pigment))
            sx, sy, color = scene.cells[map[:V](i)]
            color == pigment && sx - px == u - x && sy - py == v - y
        end
    end
    matches = Catlab.homomorphisms(pattern.graph, scene.graph; cat=SUPPORT_CATEGORY,
        monic=true, filter=compatible, take=max_witnesses + 1)
    return (bindings=[collect(map[:V]) for map in Iterators.take(matches, max_witnesses)],
        complete=length(matches) <= max_witnesses)
end

function glue_patterns(left_mapping, right_mapping)
    return Catlab.pushout[SUPPORT_CATEGORY](left_mapping, right_mapping)
end

function glue_matches(left, right, interface; distinct=Tuple{String,String}[])
    return bounded_glue_matches(left, right, interface; distinct).rows
end

function bounded_glue_matches(left, right, interface; distinct=Tuple{String,String}[], max_work=typemax(Int))
    rows = Dict{String,Int}[]
    work = 0
    for l in left, r in right
        work == max_work && return (; rows, complete=false, work)
        work += 1
        all(key -> haskey(l, key) && haskey(r, key) && l[key] == r[key], interface) || continue
        all(key -> l[key] == r[key], intersect(keys(l), keys(r))) || continue
        candidate = merge(l, r)
        all(pair -> all(key -> haskey(candidate, key), pair) &&
            candidate[pair[1]] != candidate[pair[2]], distinct) || continue
        push!(rows, candidate)
    end
    return (; rows, complete=true, work)
end

function join_effect_roles(count, max_work)
    count > 0 || throw(ArgumentError("An effect span must be nonempty"))
    graph = Catlab.Graph(1)
    event = 1
    interface = Catlab.Graph(1)
    roles = Tuple{Int,Int}[]
    work = 0
    for _ in 1:count
        work == max_work && return (; roles, event, complete=false, work)
        piece = Catlab.Graph(3)
        Catlab.add_edge!(piece, 1, 2)
        Catlab.add_edge!(piece, 1, 3)
        Catlab.add_edge!(piece, 2, 3)
        left = Catlab.ACSetTransformation(interface, graph; V=[event], cat=SUPPORT_CATEGORY)
        right = Catlab.ACSetTransformation(interface, piece; V=[1], cat=SUPPORT_CATEGORY)
        all(check_schema_map(map).natural for map in (left, right)) || error("Unnatural effect span")
        joined = glue_patterns(left, right)
        to_join, new_roles = Catlab.legs(joined)
        graph = Catlab.ob(joined)
        event = to_join[:V](event)
        event == new_roles[:V](1) || error("The effect span lost the common event")
        roles = [(to_join[:V](old), to_join[:V](new)) for (old, new) in roles]
        push!(roles, (new_roles[:V](2), new_roles[:V](3)))
        work += 1
    end
    length(unique([event; [role for pair in roles for role in pair]])) == Catlab.nv(graph) ||
        error("Unexpected role identification in effect span")
    return (; roles, event, complete=true, work)
end

function check_schema_map(map)
    return (natural=Catlab.is_natural(map; cat=SUPPORT_CATEGORY),
        failures=Catlab.naturality_failures(map; cat=SUPPORT_CATEGORY))
end
