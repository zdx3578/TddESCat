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
    rows = Dict{String,Int}[]
    for l in left, r in right
        all(key -> haskey(l, key) && haskey(r, key) && l[key] == r[key], interface) || continue
        all(key -> l[key] == r[key], intersect(keys(l), keys(r))) || continue
        candidate = merge(l, r)
        all(pair -> all(key -> haskey(candidate, key), pair) &&
            candidate[pair[1]] != candidate[pair[2]], distinct) || continue
        push!(rows, candidate)
    end
    return rows
end

function check_schema_map(map)
    return (natural=Catlab.is_natural(map; cat=SUPPORT_CATEGORY),
        failures=Catlab.naturality_failures(map; cat=SUPPORT_CATEGORY))
end
