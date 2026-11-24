const LEARN_PROTOCOL = "tddescat.learn.v2"
const STITCH_CODEC = "typed-free-slots.v1"

wire_parameter(index) = Dict("kind" => "Param", "index" => index)
wire_slot(index) = Dict("kind" => "Slot", "index" => index)
wire_call(name, args) = Dict("kind" => "Call", "operator" => name, "args" => args)
wire_const(sort, value) = Dict("kind" => "Const", "sort" => sort, "value" => value)

function wire_text(term; parameter="?#")
    kind = term["kind"]
    if kind == "Param"
        return parameter * string(term["index"])
    elseif kind == "Slot"
        return "\$" * string(term["index"])
    elseif kind == "Const"
        value, sort = term["value"], term["sort"]
        return value isa String ? value : (sort == "Integer" ? "i" : "color") * string(value)
    end
    args = term["args"]
    return isempty(args) ? term["operator"] : "(" * join([term["operator"]; wire_text.(args; parameter)], " ") * ")"
end

function stitch_tokens(text)
    occursin(r"^[A-Za-z0-9_.\-?$#() \t\r\n]+\z", text) ||
        error("Invalid encoded expression")
    return split(replace(text, "(" => " ( ", ")" => " ) "))
end

function parse_stitch_tokens(tokens)
    stack = NamedTuple[]
    root = nothing
    position = 1
    while position <= length(tokens)
        isnothing(root) || error("Trailing encoded expression")
        token = tokens[position]
        position += 1
        if token == "("
            position <= length(tokens) || error("Missing operator")
            head = String(tokens[position])
            head in ("(", ")") && error("Invalid operator")
            position += 1
            push!(stack, (head=head, children=Any[]))
            2 * length(stack) + 8 < 128 || error("Wire JSON body depth is unsupported")
            continue
        end
        node = if token == ")"
            isempty(stack) && error("Unexpected closing parenthesis")
            pop!(stack)
        else
            (head=String(token), children=Any[])
        end
        if isempty(stack)
            root = node
        else
            push!(last(stack).children, node)
        end
    end
    isempty(stack) && !isnothing(root) || error("Incomplete encoded expression")
    return root
end

encoded_syntax(text) = parse_stitch_tokens(stitch_tokens(text))

function wire_index(value)
    index = tryparse(Int, value)
    isnothing(index) || (index >= 0 && string(index) == value) || error("Invalid index")
    isnothing(index) && error("Invalid index")
    return index
end

function decode_node(node, registry, mode, arity=0)
    name, children = node
    if startswith(name, "\$")
        isempty(children) || error("Non-leaf indexed reference")
        index = wire_index(name[2:end])
        mode == :program && return wire_slot(index)
        mode == :lambda && index < arity || error("Free index in definition")
        return wire_parameter(arity - 1 - index)
    elseif startswith(name, "?#")
        mode == :pattern && isempty(children) || error("Unexpected pattern variable")
        return wire_parameter(wire_index(name[3:end]))
    end
    haskey(registry, name) || error("Unknown operator " * name)
    ports = registry[name]
    length(children) == length(ports["inputs"]) || error("Invalid arity")
    if isempty(children) && !(startswith(name, "lib_") || startswith(name, "fn_"))
        sort = ports["output"]
        prefix = get(Dict("Integer" => "i", "Color" => "color"), sort, nothing)
        value = isnothing(prefix) || !startswith(name, prefix) ? nothing :
            tryparse(Int, name[length(prefix) + 1:end])
        canonical = !isnothing(value) && prefix * string(value) == name
        return wire_const(sort, canonical ? value : name)
    end
    return wire_call(name, [decode_node(child, registry, mode, arity) for child in children])
end

function wire_sort(term, registry; slots=String[], params=nothing)
    kind = term["kind"]
    if kind == "Slot" || kind == "Param"
        context = kind == "Slot" ? (isnothing(params) ? slots : String[]) : params
        index = term["index"]
        !isnothing(context) && strict_integer(index) && 0 <= index < length(context) ||
            error("Undeclared typed reference")
        return context[index + 1]
    elseif kind == "Const"
        port = registry[wire_text(term)]
        isempty(port["inputs"]) && port["output"] == term["sort"] || error("Constant sort mismatch")
        return port["output"]
    end
    kind == "Call" || error("Unrecognized term kind")
    name = term["operator"]
    port = registry[name]
    [wire_sort(child, registry; slots, params) for child in term["args"]] == port["inputs"] ||
        error("Port sort mismatch at " * name)
    return port["output"]
end

decode_program(text, registry) = decode_node(encoded_syntax(text), registry, :program)

function decode_definition(definition, registry)
    arity = definition["arity"]
    params = definition["parameter_sorts"]
    strict_integer(arity) && 0 <= arity && arity == length(params) || error("Invalid arity")
    tokens = stitch_tokens(definition["closed_lambda_text"])
    start = 1
    stop = length(tokens)
    for _ in 1:arity
        start + 2 <= stop && tokens[start] == "(" && tokens[start + 1] == "lam" &&
            tokens[stop] == ")" || error("Missing or unclosed outer binder")
        start += 2
        stop -= 1
    end
    bound = parse_stitch_tokens(@view tokens[start:stop])
    from_pattern = decode_node(encoded_syntax(definition["pattern_text"]), registry, :pattern)
    from_lambda = decode_node(bound, registry, :lambda, arity)
    from_pattern == from_lambda == definition["body"] || error("Definition parameter order differs")
    wire_sort(from_pattern, registry; params) == definition["result_sort"] || error("Result sort mismatch")
    used = Set{Int}()
    prerequisites = Set{String}()
    walk_wire(from_pattern) do term, _
        term["kind"] == "Param" && push!(used, term["index"])
        if term["kind"] == "Call"
            name = term["operator"]
            (startswith(name, "fn_") || startswith(name, "lib_")) && push!(prerequisites, name)
        end
    end
    sort!(collect(used)) == definition["parameter_reads"] == collect(0:arity-1) ||
        error("Definition reads differ")
    sort!(collect(prerequisites)) == definition["dependencies"] || error("Definition dependencies differ")
    wire_cost(from_pattern) == decimal_cost(definition["body_cost"]) || error("Definition cost differs")
    return from_pattern
end

function walk_wire(f, term, path=Int[])
    f(term, path)
    term["kind"] == "Call" || return
    for (index, node) in enumerate(term["args"])
        walk_wire(f, node, [path; index - 1])
    end
end

wire_cost(term) = 1 + (term["kind"] == "Call" ? sum(wire_cost, term["args"]; init=0) : 0)

function decimal_cost(value)
    value isa String && occursin(r"^(0|[1-9][0-9]*)\z", value) || error("Invalid decimal cost")
    return parse(UInt64, value)
end

function instantiate_wire(body, args)
    body["kind"] == "Param" && return deepcopy(args[body["index"] + 1])
    body["kind"] == "Call" || return deepcopy(body)
    return wire_call(body["operator"], [instantiate_wire(arg, args) for arg in body["args"]])
end

function wire_at(term, path)
    for index in path
        term["kind"] == "Call" && strict_integer(index) && 0 <= index < length(term["args"]) ||
            error("Invalid proof position")
        term = term["args"][index + 1]
    end
    return term
end

function replay_proof(proof, input, output, library, registry, slots)
    proof["left_term"] == input && proof["right_term"] == output || error("Proof endpoints differ")
    term = deepcopy(input)
    for step in proof["steps"]
        step["kind"] == "rule" && isempty(step["premise_refs"]) || error("Unsupported proof step")
        rule = step["rule_id"]
        startswith(rule, "def.") || error("Unregistered rule")
        name = rule[5:end]
        definition = library[name]
        args = step["substitution"]
        [item["parameter"] for item in args] == collect(0:definition["arity"]-1) || error("Invalid proof substitution")
        terms = [item["term"] for item in args]
        [wire_sort(item, registry; slots) for item in terms] == definition["parameter_sorts"] ||
            error("Substitution sort differs")
        call = wire_call(name, terms)
        body = instantiate_wire(definition["body"], terms)
        direction = step["direction"]
        before, after = direction == "forward" ? (call, body) :
            direction == "reverse" ? (body, call) : error("Invalid proof direction")
        path = step["site_path"]
        wire_at(term, path) == before || error("Proof step does not match its site")
        if isempty(path)
            term = after
        else
            wire_at(term, path[1:end-1])["args"][last(path) + 1] = after
        end
    end
    term == output || error("Proof did not reach its claimed output")
    return term
end

site_contains(site, path) = length(site) <= length(path) && path[1:length(site)] == site

function expand_sites!(positions, step, library; spread)
    site = Tuple(step["site_path"])
    name = step["rule_id"][5:end]
    original = Dict(path => labels for (path, labels) in positions if site_contains(site, path))
    root_labels = get(original, site, Set{Tuple}())
    for path in keys(original)
        delete!(positions, path)
    end
    function add_labels(path, labels)
        isempty(labels) && return
        union!(get!(Set{Tuple}, positions, path), labels)
    end
    walk_wire(library[name]["body"]) do node, relative
        destination = (site..., relative...)
        if node["kind"] == "Param"
            argument = (site..., node["index"])
            for (path, labels) in original
                site_contains(argument, path) || continue
                add_labels((destination..., path[length(argument)+1:end]...), labels)
            end
        end
        (spread || isempty(relative)) && add_labels(destination, root_labels)
    end
end

function initial_sites(term, library; all_nodes)
    positions = Dict{Tuple,Set{Tuple}}()
    walk_wire(term) do node, path
        if all_nodes || (node["kind"] == "Call" && haskey(library, node["operator"]))
            site = Tuple(path)
            positions[site] = Set{Tuple}([site])
        end
    end
    return positions
end

function replay_call_sources(proof, input, output, library, registry, slots)
    replay_proof(proof, input, output, library, registry, slots)
    left = initial_sites(input, library; all_nodes=true)
    right = initial_sites(output, library; all_nodes=false)
    steps = proof["steps"]
    middle = findfirst(step -> step["direction"] == "reverse", steps)
    middle = isnothing(middle) ? length(steps) + 1 : middle
    all(step -> step["direction"] == "reverse", @view steps[middle:end]) ||
        error("Definition proof does not have a shared expansion")
    for step in @view steps[1:middle-1]
        expand_sites!(left, step, library; spread=true)
    end
    for i in length(steps):-1:middle
        expand_sites!(right, steps[i], library; spread=false)
    end
    sources = Dict{Tuple,Set{Tuple}}()
    for (path, labels) in left
        for n in 0:length(path)
            calls = get(right, path[1:n], nothing)
            isnothing(calls) && continue
            for call in calls
                union!(get!(Set{Tuple}, sources, call), labels)
            end
        end
    end
    return sources
end
