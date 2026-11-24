function freeze_stitch_job(directory, job_id, snapshot_id, library::LibrarySnapshot,
                           signature, programs, origins, slots; repo_root, config_path=nothing,
                           config_text=nothing, engine_identity=nothing, input_scope_complete=true)
    xor(isnothing(config_path), isnothing(config_text)) || error("Provide one worker configuration source")
    config = isnothing(config_text) ? read(config_path, String) : config_text
    stitch_policy(config)
    mkpath(directory)
    isempty(readdir(directory)) || error("The frozen job directory must be fresh")
    upstream = TOML.parsefile(joinpath(repo_root, "third_party", "egg-stitch", "UPSTREAM.toml"))
    if isnothing(engine_identity)
        worker = joinpath(repo_root, "target", "release", "tddesc-stitch")
        engine_identity = JSON.parse(read(Cmd([worker, "--identity"]), String))
    end
    engine = Dict(
        "upstream_commit" => upstream["revision"],
        "source_git_tree" => upstream["tree_sha1"],
        "cargo_lock_sha256" => content_hash(read(joinpath(repo_root, "Cargo.lock"))),
        "rust_version" => TOML.parsefile(joinpath(repo_root, "rust-toolchain.toml"))["toolchain"]["channel"],
        "protocol_version" => LEARN_PROTOCOL,
        "build_sha256" => engine_identity["build_sha256"],
        "binary_sha256" => engine_identity["binary_sha256"],
    )
    manifest = Dict{String,Any}(
        "job_id" => job_id, "evidence_snapshot_id" => snapshot_id, "library_base_version" => library.version,
        "protocol_version" => LEARN_PROTOCOL, "codec_version" => STITCH_CODEC,
        "program_count" => length(programs), "slot_context" => slots, "engine_pin" => engine,
        "input_scope_complete" => input_scope_complete,
    )
    for (name, extension, data) in (
        ("signature", "json", JSON.json(signature)),
        ("programs", "json", JSON.json(programs)),
        ("origins", "json", JSON.json(origins)),
        ("initial_library", "json", JSON.json(library.entries)),
        ("rules", "json", "[]"),
        ("config", "toml", config),
    )
        filename = name * "." * extension
        atomic_write(joinpath(directory, filename), data)
        manifest[name * "_file"] = Dict("path" => filename, "bytes" => ncodeunits(data), "sha256" => content_hash(data))
    end
    atomic_json(joinpath(directory, "manifest.json"), manifest)
    return manifest
end

function stitch_blob(job_dir, manifest, field)
    descriptor = manifest[field * "_file"]
    path = descriptor["path"]
    basename(path) == path && valid_id(path) || error("Unsafe descriptor path")
    file = realpath(joinpath(job_dir, path))
    dirname(file) == realpath(job_dir) || error("Descriptor escaped job directory")
    data = read(file)
    length(data) == descriptor["bytes"] && content_hash(data) == descriptor["sha256"] ||
        error("Frozen job input changed")
    return data
end

stitch_input(job_dir, manifest, field) = JSON.parse(String(stitch_blob(job_dir, manifest, field)))

function verify_stitch_calls(result, outputs, input_sites, proof_for, sources, definitions)
    positions = Dict{Tuple{Int,Tuple},Any}()
    for (index, program) in enumerate(outputs)
        walk_wire(program) do term, path
            if term["kind"] == "Call" && haskey(definitions, term["operator"])
                positions[(index - 1, Tuple(path))] = term
            end
        end
    end
    used = Set{String}()
    for call in result["calls"]
        index, path = call["program_index"], Tuple(call["call_path"])
        expected = pop!(positions, (index, path))
        name = expected["operator"]
        call["definition_ref"] == name && call["argument_terms"] == expected["args"] ||
            error("Call witness differs from its output site")
        call["proof_ref"] == proof_for[index + 1] || error("Call witness has a different proof")
        expected_sites = get(sources[index + 1], path, Set{Tuple}())
        ids = call["source_occurrences"]
        allunique(ids) && !isempty(expected_sites) &&
            Set(ids) == Set(input_sites[index + 1][position] for position in expected_sites) ||
            error("Call witness differs from the proof-derived occurrences")
        push!(used, name)
    end
    isempty(positions) || error("A selected call has no source witness")
    return used
end

function input_occurrences(original, origins)
    ids = [entry["occurrence_id"] for entry in origins]
    allunique(ids) && all(valid_id, ids) || error("Duplicate or invalid input occurrence")
    sites = [Dict{Tuple,String}() for _ in original]
    for entry in origins
        index = entry["program_index"]
        strict_integer(index) && 0 <= index < length(sites) || error("Invalid origin program index")
        path = Tuple(entry["expression_path"])
        wire_at(original[index + 1], path)
        haskey(sites[index + 1], path) && error("Duplicate source position")
        sites[index + 1][path] = entry["occurrence_id"]
    end
    all(((term, entries),) -> length(entries) == wire_cost(term), zip(original, sites)) ||
        error("Origins do not cover the input syntax")
    return sites
end

function check_stitch_semantics(result, signature, entries, text, origins, slots; temporary=[])
    registry, definitions = registry_from(signature, entries)
    original = [decode_program(item, registry) for item in text]
    input_sorts = [wire_sort(term, registry; slots) for term in original]
    for candidate in temporary
        check_register!(registry, definitions, candidate["temporary_name"], candidate)
    end
    rewritten = [decode_program(item, registry) for item in result["rewritten_programs"]]
    [wire_sort(term, registry; slots) for term in rewritten] == input_sorts || error("Rewritten program sorts differ")
    length(result["proofs"]) == length(original) || error("Proof coverage differs")
    sources = [replay_call_sources(proof, before, after, definitions, registry, slots)
        for (proof, before, after) in zip(result["proofs"], original, rewritten)]
    proof_ids = [proof["proof_id"] for proof in result["proofs"]]
    allunique(proof_ids) || error("Duplicate proof ID")
    used = verify_stitch_calls(result, rewritten, input_occurrences(original, origins),
        proof_ids, sources, definitions)
    return (; original, rewritten, used, registry, definitions)
end

function check_stitch_result(result, manifest, signature, entries, text, origins)
    slots = String[slot["sort"] for slot in manifest["slot_context"]]
    (; original, rewritten, used) = check_stitch_semantics(result, signature, entries, text, origins, slots;
        temporary=result["definitions"])
    if !isempty(result["definitions"])
        last(result["definitions"])["temporary_name"] in used || error("New definition has no selected call")
    end
    input_cost = 1 + sum(wire_cost, original; init=0)
    output_cost = 1 + sum(wire_cost, rewritten; init=0)
    old_cost = sum(x -> wire_cost(x["definition"]["body"]), entries; init=0)
    new_cost = sum(x -> wire_cost(x["body"]), result["definitions"]; init=0)
    total = output_cost + old_cost + new_cost
    cost = result["cost"]
    for (key, expected) in (
        ("pre_rewrite_input", input_cost), ("output_programs", output_cost), ("initial_library", old_cost),
        ("new_definitions", new_cost), ("final_total", total),
        ("ratio_numerator", input_cost + old_cost), ("ratio_denominator", total),
    )
        decimal_cost(cost[key]) == expected || error("Independent cost check failed at " * key)
    end
    return result
end

function read_stitch_rounds(job_dir, output_dir)
    manifest_bytes = read(joinpath(job_dir, "manifest.json"))
    manifest = JSON.parse(String(copy(manifest_bytes)))
    input_sha = content_hash(manifest_bytes)
    manifest["protocol_version"] == LEARN_PROTOCOL && manifest["codec_version"] == STITCH_CODEC ||
        error("Job version differs")
    signature = stitch_input(job_dir, manifest, "signature")
    entries = stitch_input(job_dir, manifest, "initial_library")
    text = stitch_input(job_dir, manifest, "programs")
    origins = stitch_input(job_dir, manifest, "origins")
    policy = stitch_policy(String(stitch_blob(job_dir, manifest, "config")))
    paths = filter(name -> occursin(r"^round-[0-9]{6,}\z", name), readdir(output_dir))
    sort!(paths; by=name -> parse(Int, name[7:end]))
    verified = []
    parent = nothing
    known = []
    previous = nothing
    terminal = false
    checkpoint_digests = String[]
    for (index, name) in enumerate(paths)
        name == "round-" * lpad(index, 6, '0') || error("Missing checkpoint")
        folder = joinpath(output_dir, name)
        realpath(folder) == folder || error("Checkpoint path escaped output")
        checkpoint_bytes = read(joinpath(folder, "manifest.json"))
        checkpoint = JSON.parse(String(copy(checkpoint_bytes)))
        bytes = read(joinpath(folder, "result.json"))
        length(bytes) == checkpoint["result_bytes"] && content_hash(bytes) == checkpoint["result_sha256"] ||
            error("Checkpoint content differs")
        result = JSON.parse(String(bytes))
        for object in (checkpoint, result)
            object["round_index"] == index && object["input_sha256"] == input_sha &&
                object["parent_checkpoint_sha256"] == parent || error("Checkpoint order or parent differs")
        end
        result["protocol_version"] == LEARN_PROTOCOL && result["codec_version"] == STITCH_CODEC &&
            result["job_id"] == manifest["job_id"] || error("Result job identity differs")
        all(key -> result[key] === true, ("round_committed", "apply_complete", "match_support_exact",
                "saturation_complete","search_exhausted")) ||
            error("Incomplete result")
        result["input_scope_complete"] === manifest["input_scope_complete"] || error("Input scope differs")
        terminal && error("Result follows a terminal round")
        outcome = result["round_outcome"]
        definitions = result["definitions"]
        added = length(definitions) - length(known)
        if outcome == "definition_accepted"
            added == 1 && last(definitions)["arity"] <= policy["max_arity"] ||
                error("Invalid newly accepted definition")
        elseif outcome == "no_positive_gain"
            added == 0 || error("Terminal round introduced a definition")
            terminal = true
        else
            error("Invalid round outcome")
        end
        definitions[1:length(known)] == known || error("A prior definition changed")
        check_stitch_result(result, manifest, signature, entries, text, origins)
        cost = decimal_cost(result["cost"]["final_total"])
        baseline = isnothing(previous) ? decimal_cost(result["cost"]["ratio_numerator"]) : previous
        (cost < baseline || (terminal && cost == baseline)) || error("Full round cost did not decrease")
        push!(verified, result)
        parent = content_hash(checkpoint_bytes)
        push!(checkpoint_digests, parent)
        previous, known = cost, definitions
    end
    summary_path = joinpath(output_dir, "learning-summary.json")
    summary = isfile(summary_path) ? read_json(summary_path) : nothing
    if !isnothing(summary)
        summary["protocol_version"] == LEARN_PROTOCOL && summary["input_sha256"] == input_sha &&
            summary["effective_policy"] == policy && all(isnothing, values(summary["effective_limits"])) ||
            error("Learning summary does not match the frozen policy")
        refs = summary["scope_refs"]
        all(refs[key] == manifest[field * "_file"]["sha256"] for (key,field) in
            (("signature","signature"),("programs","programs"),("origins","origins"),
             ("base_library","initial_library"),("equations","rules"),("policy","config"))) ||
            error("Learning summary does not match the frozen inputs")
        all(refs[key] == manifest["engine_pin"][key * "_sha256"] for key in ("binary","build")) ||
            error("Learning summary has a different worker identity")
        summary["last_checkpoint"] == (isnothing(parent) ? nothing :
            Dict("round_index"=>length(verified),"sha256"=>parent)) || error("Summary checkpoint differs")
        summary["accepted_definitions"] == length(known) && summary["search_rounds"] >= length(verified) ||
            error("Summary counts differ")
        fixed = summary["termination_reason"] == "verified_compression_fixed_point"
        summary["fixed_point"] === fixed && (!fixed || (terminal && manifest["input_scope_complete"] &&
            summary["search_rounds"] == length(verified) && isnothing(summary["interrupted_phase"]))) ||
            error("Unproved fixed point")
    end
    return (; manifest, signature, verified, input_sha, entries, text, origins, summary,
        checkpoint_digests, policy)
end
