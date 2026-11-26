"""Exact public atoms available to a policy at a committed observation."""
function policy_scene_atoms(observation)
    frame = last(observation.frames)
    groups = public_components(frame)
    types = Dict{String,NamedTuple}()
    function accept(atom)
        id = semantic_hash(parse_json(JSON.json(atom)))
        types[id] = atom
    end
    for action in observation.available_actions
        accept((kind="available_action",value=action))
    end
    accept((kind="previous_action",value=observation.action["id"]))
    shape_counts = Dict{String,Int}()
    visible_colors = Set{Int}()
    for group in groups
        push!(visible_colors,Int(first(group)[3]))
        4length(group) <= length(frame) || continue
        shape = semantic_hash(shape_template(group))
        shape_counts[shape] = get(shape_counts,shape,0)+1
    end
    for color in visible_colors
        accept((kind="color_present",value=color))
    end
    for (shape,count) in shape_counts, threshold in 1:count
        accept((kind="shape_count_at_least",shape,threshold))
    end
    return types
end

function policy_atom_active(atoms,atom)
    atom["kind"] == "all" && return all(member->policy_atom_active(atoms,member),atom["members"])
    return haskey(atoms,semantic_hash(atom))
end

function policy_guard_value(layout,atoms)
    valuation = Dict(name=>policy_atom_active(atoms,atom) for (name,atom) in layout["atoms"])
    return evaluate_constraint(layout["guard"],valuation)
end

function typed_policy_guard(worker,positives,negatives,snapshot)
    min(length(positives),length(negatives)) >= 2 || return nothing
    examples = [positives[1:end-1];negatives[1:end-1]]
    positive_count = length(positives)-1
    atoms = reduce(merge,examples)
    features = filter(sort!(collect(keys(atoms)))) do key
        count(row -> haskey(row,key),examples) ∉ (0,length(examples))
    end
    isempty(features) && return nothing
    definitions = NamedTuple[atoms[feature] for feature in features]
    valuations = [[haskey(row,key) for key in features] for row in examples]
    # Closed intents over real public observations are additional guard inputs.
    # Their definitions expand to ordinary observable atoms at execution.
    incidence = Dict((i,key)=>(values[j] ? proven : disproven)
        for (i,values) in enumerate(valuations) for (j,key) in enumerate(features))
    rectangles = relational_factors(eachindex(examples),features,incidence,
        [1:positive_count,positive_count+1:length(examples)])
    for factor in rectangles.factors
        length(factor.intent) >= 2 || continue
        push!(definitions,(kind="all",members=[atoms[key] for key in factor.intent]))
        for (index,values) in enumerate(valuations)
            push!(values,index in factor.extent)
        end
    end
    names = ["atom_" * string(i) for i in eachindex(definitions)]
    samples = [(features=row,expected=index<=positive_count)
        for (index,row) in enumerate(valuations)]
    solution = compute_request!(worker,snapshot,"synthesize_guard",(;features=names,samples))
    solution.execution == "completed" && solution.answer == "value" || return nothing
    solution.value["status"] == "solution" || return nothing
    guard = solution.value["guard"]
    all(evaluate_constraint(guard,Dict(zip(names,row.features))) === row.expected for row in samples) ||
        error("Synthesized policy guard failed replay")
    used = Set{String}()
    function collect_atoms(node)
        if haskey(node,"var")
            push!(used,node["var"])
        end
        foreach(collect_atoms,get(node,"args",[]))
    end
    collect_atoms(guard)
    definitions = Dict(name=>atom for (name,atom) in zip(names,definitions) if name in used)
    layout = Dict("guard_schema"=>"public-atoms-v1","guard"=>guard,
        "atoms"=>parse_json(JSON.json(definitions)),"synthesis"=>"cvc5","validation"=>"held_out")
    policy_guard_value(layout,last(positives)) === true &&
        policy_guard_value(layout,last(negatives)) === false || return nothing
    return layout
end

function evaluate_policy_guard(layout,observation)
    observation isa PublicObservation || return nothing
    return policy_guard_value(layout,policy_scene_atoms(observation))
end
