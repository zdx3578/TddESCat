struct LibrarySnapshot
    version::String
    entries::Vector{Dict{String,Any}}
end

LibrarySnapshot() = LibrarySnapshot("library-empty", Dict{String,Any}[])

function definition_id(definition)
    signature = [definition["parameter_sorts"], definition["result_sort"], wire_text(definition["body"])]
    return "lib_" * content_hash(JSON.json(signature))
end

function registry_from(signature, entries)
    registry = Dict{String,Any}()
    definitions = Dict{String,Any}()
    for op in signature["operators"]
        name = op["symbol"]
        haskey(registry, name) && error("Duplicate operator")
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
    registry[id] = Dict("inputs" => definition["parameter_sorts"], "output" => definition["result_sort"])
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
        id = definition_id(definition)
        if haskey(stored, id)
            stored[id]["body"] == definition["body"] || error("Definition content collision")
        else
            check_register!(registry, stored, id, definition)
            push!(entries, Dict("stable_id" => id, "definition" => definition))
        end
        names[candidate["temporary_name"]] = id
    end
    version = "library-" * content_hash(JSON.json([entry["stable_id"] for entry in entries]))
    return (snapshot=LibrarySnapshot(version, entries), names)
end
