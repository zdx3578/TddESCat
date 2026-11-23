function freeze_stitch_job(directory, job_id, snapshot_id, library::LibrarySnapshot,
                           signature, programs, origins, slots; repo_root, config_path)
    mkpath(directory)
    isempty(readdir(directory)) || error("The frozen job directory must be fresh")
    upstream = TOML.parsefile(joinpath(repo_root, "third_party", "egg-stitch", "UPSTREAM.toml"))
    engine = Dict(
        "upstream_commit" => upstream["revision"],
        "source_git_tree" => upstream["tree_sha1"],
        "cargo_lock_sha256" => content_hash(read(joinpath(repo_root, "Cargo.lock"))),
        "rust_version" => TOML.parsefile(joinpath(repo_root, "rust-toolchain.toml"))["toolchain"]["channel"],
        "protocol_version" => LEARN_PROTOCOL,
    )
    manifest = Dict{String,Any}(
        "job_id" => job_id, "evidence_snapshot_id" => snapshot_id, "library_base_version" => library.version,
        "protocol_version" => LEARN_PROTOCOL, "codec_version" => STITCH_CODEC,
        "program_count" => length(programs), "slot_context" => slots, "engine_pin" => engine,
    )
    for (name, extension, data) in (
        ("signature", "json", JSON.json(signature)),
        ("programs", "json", JSON.json(programs)),
        ("origins", "json", JSON.json(origins)),
        ("initial_library", "json", JSON.json(library.entries)),
        ("rules", "json", "[]"),
        ("config", "toml", read(config_path, String)),
    )
        filename = name * "." * extension
        atomic_write(joinpath(directory, filename), data)
        manifest[name * "_file"] = Dict("path" => filename, "bytes" => ncodeunits(data), "sha256" => content_hash(data))
    end
    atomic_json(joinpath(directory, "manifest.json"), manifest)
    return manifest
end

function stitch_input(job_dir, manifest, field)
    descriptor = manifest[field * "_file"]
    path = descriptor["path"]
    basename(path) == path && valid_id(path) || error("Unsafe descriptor path")
    file = realpath(joinpath(job_dir, path))
    dirname(file) == realpath(job_dir) || error("Descriptor escaped job directory")
    data = read(file)
    length(data) == descriptor["bytes"] && content_hash(data) == descriptor["sha256"] ||
        error("Frozen job input changed")
    return JSON.parse(String(data))
end

function verify_stitch_calls(result, outputs, origins, proof_for, definitions)
    positions = Dict{Tuple{Int,Tuple},Any}()
    for (index, program) in enumerate(outputs)
        walk_wire(program) do term, path
            if term["kind"] == "Call" && haskey(definitions, term["operator"])
                positions[(index - 1, Tuple(path))] = term
            end
        end
    end
    origin_index = Dict(o["occurrence_id"] => o for o in origins)
    used = Set{String}()
    for call in result["calls"]
        index, path = call["program_index"], Tuple(call["call_path"])
        expected = pop!(positions, (index, path))
        name = expected["operator"]
        call["definition_ref"] == name && call["argument_terms"] == expected["args"] ||
            error("Call witness differs from its output site")
        call["proof_ref"] == proof_for[index + 1] || error("Call witness has a different proof")
        ids = call["source_occurrences"]
        !isempty(ids) && all(id -> origin_index[id]["program_index"] == index, ids) ||
            error("Call witness has a different source program")
        push!(used, name)
    end
    isempty(positions) || error("A selected call has no source witness")
    return used
end

function check_stitch_result(result, manifest, signature, entries, text, origins)
    registry, definitions = registry_from(signature, entries)
    slots = String[slot["sort"] for slot in manifest["slot_context"]]
    original = [decode_program(item, registry) for item in text]
    input_sorts = [wire_sort(term, registry; slots) for term in original]
    for candidate in result["definitions"]
        check_register!(registry, definitions, candidate["temporary_name"], candidate)
    end
    rewritten = [decode_program(item, registry) for item in result["rewritten_programs"]]
    [wire_sort(term, registry; slots) for term in rewritten] == input_sorts || error("Rewritten program sorts differ")
    length(result["proofs"]) == length(original) || error("Proof coverage differs")
    for (proof, before, after) in zip(result["proofs"], original, rewritten)
        replay_proof(proof, before, after, definitions, registry, slots)
    end
    proof_ids = [proof["proof_id"] for proof in result["proofs"]]
    allunique(proof_ids) || error("Duplicate proof ID")
    used = verify_stitch_calls(result, rewritten, origins, proof_ids, definitions)
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
    paths = filter(name -> occursin(r"^round-[0-9]{6}\z", name), readdir(output_dir))
    verified = []
    parent = nothing
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
        all(key -> result[key] === true, ("round_committed", "apply_complete", "match_support_exact")) ||
            error("Incomplete result")
        check_stitch_result(result, manifest, signature, entries, text, origins)
        push!(verified, result)
        parent = content_hash(checkpoint_bytes)
    end
    return (; manifest, signature, verified)
end
