struct LibrarySnapshot
    version::String
    entries::Vector{Dict{String,Any}}
end

LibrarySnapshot() = LibrarySnapshot("library-empty", Dict{String,Any}[])

library_version(entries) = isempty(entries) ? "library-empty" :
    "library-" * content_hash(JSON.json([entry["stable_id"] for entry in entries]))

function scoped_search_library(base, signature, programs, slots)
    registry,_ = registry_from(signature,base.entries)
    sorts = Set{String}()
    for program in programs
        walk_wire(decode_program(program,registry)) do node,_
            kind = node["kind"]
            sort = kind == "Call" ? registry[node["operator"]]["output"] :
                kind == "Slot" ? slots[node["index"]+1]["sort"] : node["sort"]
            push!(sorts,sort)
        end
    end
    selected = Set(entry["stable_id"] for entry in base.entries
        if entry["definition"]["result_sort"] in sorts)
    for entry in Iterators.reverse(base.entries)
        entry["stable_id"] ∈ selected && union!(selected,entry["definition"]["dependencies"])
    end
    entries = filter(entry->entry["stable_id"] in selected,base.entries)
    return LibrarySnapshot(base.version,entries)
end

function definition_depths(entries)
    depths = Dict{String,Int}()
    for entry in entries
        dependencies = entry["definition"]["dependencies"]
        depths[entry["stable_id"]] = 1 + maximum((depths[id] for id in dependencies); init=0)
    end
    return depths
end

function definition_id(definition)
    material = [definition["parameter_sorts"], definition["result_sort"], wire_text(definition["body"]),
        definition["semantic_digest"]]
    return "lib_" * semantic_hash(material)
end

function registry_from(signature, entries)
    signature["schema_version"] == 3 || error("Unsupported semantic signature")
    registry = Dict{String,Any}()
    definitions = Dict{String,Any}()
    sorts = Set{String}()
    for sort in signature["sorts"]
        id = sort["id"]
        valid_id(id) && id ∉ sorts || error("Invalid or repeated semantic sort")
        if startswith(id,"rel_") || startswith(id,"prog_")
            prefix, digest = split(id,'_';limit=2)
            kind = prefix == "rel" ? "relation" : "program"
            sort["descriptor"]["kind"] == kind && digest == semantic_hash(sort["descriptor"]) ||
                error("Sort descriptor digest differs")
        elseif haskey(sort,"descriptor")
            error("Unexpected descriptor on a primitive sort")
        end
        push!(sorts,id)
    end
    for op in signature["operators"]
        name = op["symbol"]
        haskey(registry, name) && error("Duplicate operator")
        valid_id(op["semantic_version"]) && op["purity"] == "pure" && isempty(op["binder_children"]) &&
            op["read_rule"] == collect(0:length(op["inputs"])-1) &&
            all(in(sorts),op["inputs"]) && op["output"] in sorts || error("Invalid semantic operator")
        if haskey(op,"descriptor")
            name == "op_" * operator_digest(op) || error("Operator descriptor digest differs")
        elseif startswith(name,"op_")
            error("Missing descriptor on a semantic operator")
        end
        registry[name] = op
    end
    for entry in entries
        id, definition = entry["stable_id"], entry["definition"]
        id == definition_id(definition) || error("Library definition ID differs")
        check_register!(registry, definitions, id, definition)
    end
    return registry, definitions
end

function check_register!(registry, definitions, id, definition)
    haskey(registry, id) && error("Definition name already in use")
    all(name -> haskey(definitions, name), definition["dependencies"]) || error("Definition dependency missing")
    decode_definition(definition, registry)
    digest = definition_semantics(definition["body"],registry)
    definition["semantic_digest"] == digest || error("Definition semantic digest differs")
    registry[id] = Dict("inputs" => definition["parameter_sorts"], "output" => definition["result_sort"],
        "semantic_digest"=>digest)
    definitions[id] = definition
end

function rename_wire(term, names)
    term["kind"] == "Call" || return deepcopy(term)
    name = term["operator"]
    return wire_call(get(names, name, name), [rename_wire(node, names) for node in term["args"]])
end

function lambda_text(body, arity)
    function bind(term)
        kind = term["kind"]
        kind == "Param" && return "\$" * string(arity - 1 - term["index"])
        kind == "Call" || return wire_text(term)
        name = term["operator"]
        args = term["args"]
        return isempty(args) ? name : "(" * join([name; bind.(args)], " ") * ")"
    end
    return repeat("(lam ", arity) * bind(body) * repeat(")", arity)
end

function publish_library(base::LibrarySnapshot, result, manifest, signature;
                         current_version, current_evidence)
    current_version == base.version == manifest["library_base_version"] ||
        error("Library changed since the job was frozen")
    current_evidence == manifest["evidence_snapshot_id"] || error("Evidence changed since the job was frozen")
    registry, stored = registry_from(signature, base.entries)
    entries = deepcopy(base.entries)
    names = Dict{String,String}()
    for candidate in result["definitions"]
        definition = deepcopy(candidate)
        definition["body"] = rename_wire(definition["body"], names)
        definition["dependencies"] = sort!([get(names, name, name) for name in definition["dependencies"]])
        definition["pattern_text"] = wire_text(definition["body"])
        definition["closed_lambda_text"] = lambda_text(definition["body"], definition["arity"])
        definition["semantic_digest"] == definition_semantics(definition["body"],registry) ||
            error("Definition semantic digest changed during publication")
        id = definition_id(definition)
        if haskey(stored, id)
            definition_id(stored[id]) == id && stored[id]["body"] == definition["body"] ||
                error("Definition content collision")
        else
            check_register!(registry, stored, id, definition)
            push!(entries, Dict("stable_id" => id, "definition" => definition))
        end
        names[candidate["temporary_name"]] = id
    end
    version = length(entries) == length(base.entries) ? base.version : library_version(entries)
    return (snapshot=LibrarySnapshot(version, entries), names)
end

function rename_proof(proof, names)
    function rename_step(step)
        name = get(names, step["rule_id"][5:end], step["rule_id"][5:end])
        return merge(step, Dict(
            "rule_id"=>"def." * name,
            "substitution"=>[merge(arg, Dict("term"=>rename_wire(arg["term"], names)))
                for arg in step["substitution"]]))
    end
    return merge(proof, Dict(
        "left_term"=>rename_wire(proof["left_term"], names),
        "right_term"=>rename_wire(proof["right_term"], names),
        "steps"=>rename_step.(proof["steps"])))
end

function publication_from(base, checkpoint, result; current_version, current_evidence)
    accepted = publish_library(base, result, checkpoint.manifest, checkpoint.signature;
        current_version, current_evidence)
    names = accepted.names
    registry, definitions = registry_from(checkpoint.signature, base.entries)
    for candidate in result["definitions"]
        check_register!(registry, definitions, candidate["temporary_name"], candidate)
    end
    programs = [wire_text(rename_wire(decode_program(program, registry), names))
        for program in result["rewritten_programs"]]
    calls = [merge(entry, Dict(
        "definition_ref"=>get(names, entry["definition_ref"], entry["definition_ref"]),
        "argument_terms"=>[rename_wire(arg, names) for arg in entry["argument_terms"]]))
        for entry in result["calls"]]
    # The baseline comes from the e-graph extractor. The descriptor identifies
    # it separately from the costs recomputed by the Julia consumer.
    cost = Dict(k=>v for (k,v) in result["cost"] if k != "post_rewrite_baseline")
    cost["engine_reported_post_rewrite_baseline"] = result["cost"]["post_rewrite_baseline"]
    depths = definition_depths(accepted.snapshot.entries)
    new_ids = [entry["stable_id"] for entry in accepted.snapshot.entries[length(base.entries)+1:end]]
    prefixes = [
        Dict("accepted_definitions"=>count, "round_index"=>count,
            "checkpoint_sha256"=>checkpoint.checkpoint_digests[count],
            "final_total"=>checkpoint.verified[count]["cost"]["final_total"],
            "stable_definitions"=>new_ids[1:count],
            "library_dependency_depth"=>maximum((depths[entry["stable_id"]]
                for entry in accepted.snapshot.entries[1:length(base.entries)+count]); init=0))
        for count in checkpoint.policy["progress"]["accepted_definition_checkpoints"]
        if count <= length(new_ids)
    ]
    return Dict(
        "schema_version"=>1, "protocol_version"=>LEARN_PROTOCOL,
        "input_sha256"=>checkpoint.input_sha, "round_index"=>result["round_index"],
        "engine_pin"=>checkpoint.manifest["engine_pin"],
        "policy_sha256"=>checkpoint.manifest["config_file"]["sha256"],
        "library_version"=>accepted.snapshot.version, "base_version"=>base.version,
        "evidence_snapshot_id"=>current_evidence, "signature"=>checkpoint.signature,
        "slot_context"=>checkpoint.manifest["slot_context"], "library"=>accepted.snapshot.entries,
        "initial_library_count"=>length(base.entries), "new_definition_ids"=>sort!(unique!(collect(values(names)))),
        "definition_depths"=>depths, "verified_prefixes"=>prefixes,
        "source_programs"=>checkpoint.text, "origins"=>checkpoint.origins, "semantic_context"=>checkpoint.context,
        "rewritten_programs"=>programs, "calls"=>calls, "proofs"=>[rename_proof(proof, names) for proof in result["proofs"]],
        "cost"=>cost)
end

function read_published_stitch(directory; publication=nothing)
    if isnothing(publication)
        pointer = joinpath(directory, "current.json")
        isfile(pointer) || return nothing
        publication = read_json(pointer)["publication"]
    end
    occursin(r"^[a-f0-9]{64}\z", publication) || error("Invalid publication identity")
    path = joinpath(directory, publication * ".json")
    bytes = read(path)
    content_hash(bytes) == publication || error("Published artifact digest mismatch")
    bundle = parse_json(String(bytes))
    verify_published_stitch(bundle)
    state = get(bundle,"global_library",nothing)
    snapshot = isnothing(state) ? LibrarySnapshot(bundle["library_version"],collect(Dict{String,Any},bundle["library"])) :
        LibrarySnapshot(state["version"],collect(Dict{String,Any},state["entries"]))
    return (; publication,bundle,snapshot)
end

function verify_published_stitch(bundle)
    bundle["schema_version"] == 1 && bundle["protocol_version"] == LEARN_PROTOCOL ||
        error("Unknown publication schema or learning protocol")
    slots = String[slot["sort"] for slot in bundle["slot_context"]]
    signature, entries, texts = bundle["signature"], bundle["library"], bundle["source_programs"]
    older = bundle["initial_library_count"]
    strict_integer(older) && 0 <= older <= length(entries) || error("Invalid frozen library boundary")
    old_registry, _ = registry_from(signature, entries[1:older])
    context = bundle["semantic_context"]
    origins, expected_context = describe_learning_context(signature,entries[1:older],texts,bundle["origins"],
        bundle["slot_context"]; intent=context["intent"],consumer=context["consumer"],
        obligation_refs=context["obligation_refs"])
    origins == bundle["origins"] && context == expected_context || error("Published semantic derivation differs")
    for text in texts
        wire_sort(decode_program(text, old_registry), old_registry; slots)
    end
    (; original, rewritten) = check_stitch_semantics(bundle, signature, entries, texts, bundle["origins"], slots)
    definition_depths(entries) == bundle["definition_depths"] || error("Published dependency depths differ")
    input_cost = 1 + sum(wire_cost, original; init=0)
    corpus_cost = 1 + sum(wire_cost, rewritten; init=0)
    old_cost = sum(entry -> wire_cost(entry["definition"]["body"]), entries[1:older]; init=0)
    new_cost = sum(entry -> wire_cost(entry["definition"]["body"]), entries[older+1:end]; init=0)
    final_cost = corpus_cost + old_cost + new_cost
    for (key, value) in (
        ("pre_rewrite_input", input_cost), ("output_programs", corpus_cost),
        ("initial_library", old_cost), ("new_definitions", new_cost), ("final_total", final_cost),
        ("ratio_numerator", input_cost + old_cost), ("ratio_denominator", final_cost),
    )
        decimal_cost(bundle["cost"][key]) == value || error("Published cost mismatch at " * key)
    end
    decimal_cost(bundle["cost"]["engine_reported_post_rewrite_baseline"])
    if haskey(bundle,"global_library")
        state = bundle["global_library"]
        state["version"] == library_version(state["entries"]) || error("Global library version differs")
        state["prelude_digest"] == semantic_hash(entries[1:older]) || error("Published prelude digest differs")
        _,global_defs = registry_from(signature,state["entries"])
        all(entry->get(global_defs,entry["stable_id"],nothing) == entry["definition"],entries) ||
            error("Global library does not contain the verified job definitions")
        total = sum(entry->wire_cost(entry["definition"]["body"]),state["entries"];init=0)
        decimal_cost(state["storage_cost"]) == total || error("Global library storage cost differs")
    end
    return bundle
end

function publish_stitch!(directory, checkpoint; current_evidence)
    return with_run(directory) do store
        current = read_published_stitch(store.public_dir)
        global_base = isnothing(current) ? LibrarySnapshot() : current.snapshot
        isempty(checkpoint.verified) && error("No verified round to publish")
        selected = Set(entry["stable_id"] for entry in checkpoint.entries)
        frozen = filter(entry->entry["stable_id"] in selected,global_base.entries)
        frozen == checkpoint.entries || error("Frozen library dependencies differ from the current version")
        base = LibrarySnapshot(global_base.version,frozen)
        result = last(checkpoint.verified)
        bundle = publication_from(base, checkpoint, result; current_version=base.version, current_evidence)
        if frozen != global_base.entries
            existing = Set(entry["stable_id"] for entry in global_base.entries)
            added = filter(entry->entry["stable_id"] ∉ existing,bundle["library"])
            entries = vcat(global_base.entries,added)
            bundle["global_library"] = Dict("version"=>library_version(entries),"entries"=>entries,
                "prelude_digest"=>semantic_hash(frozen),"storage_cost"=>string(sum(
                    entry->wire_cost(entry["definition"]["body"]),entries;init=0)))
        end
        verify_published_stitch(bundle)
        bytes = JSON.json(bundle)
        digest = content_hash(bytes)
        path = store_path(store, digest * ".json")
        if isfile(path)
            read(path, String) == bytes || error("Publication ID collision")
        else
            atomic_write(path, bytes)
        end
        atomic_json(store_path(store, "current.json"), Dict("publication"=>digest))
        return digest
    end
end
