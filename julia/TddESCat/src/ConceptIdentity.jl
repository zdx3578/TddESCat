# Preserve the v1 canonical bytes independently of the installed JSON writer.
function canonical_string(io, value)
    write(io, UInt8('"'))
    for byte in codeunits(value)
        if byte == 0x22 || byte == 0x5c
            write(io, 0x5c, byte)
        elseif byte == 0x08
            print(io, "\\b")
        elseif byte == 0x09
            print(io, "\\t")
        elseif byte == 0x0a
            print(io, "\\n")
        elseif byte == 0x0c
            print(io, "\\f")
        elseif byte == 0x0d
            print(io, "\\r")
        elseif byte < 0x20 || byte == 0x7f
            print(io, "\\u", string(byte; base=16, pad=4))
        else
            write(io, byte)
        end
    end
    write(io, UInt8('"'))
end

function canonical_write(io, value)
    if value isa AbstractDict
        all(key->key isa AbstractString,keys(value)) || error("Canonical keys must be strings")
        print(io,'{')
        for (i,key) in enumerate(sort!(collect(keys(value))))
            i == 1 || print(io,',')
            canonical_string(io,key)
            print(io,':')
            canonical_write(io,value[key])
        end
        print(io,'}')
    elseif value isa AbstractVector || value isa Tuple
        print(io,'[')
        for (i,item) in enumerate(value)
            i == 1 || print(io,',')
            canonical_write(io,item)
        end
        print(io,']')
    elseif value isa AbstractString
        canonical_string(io,value)
    elseif isnothing(value)
        print(io,"null")
    elseif value isa Bool || strict_integer(value)
        print(io,value)
    else
        error("Unsupported canonical semantic value")
    end
end

canonical_bytes(value) = sprint(canonical_write,value)
semantic_hash(value) = content_hash(canonical_bytes(value))

function operator_material(op)
    return ["operator-v1",op["inputs"],op["output"],op["read_rule"],op["semantic_version"],
        get(op,"descriptor",nothing)]
end

function operator_digest(op)
    material = operator_material(op)
    return semantic_hash(isnothing(last(material)) ? [op["symbol"],material] : material)
end

function semantic_sort!(signature, prefix, descriptor)
    prefix in ("rel","prog") || error("Unknown semantic sort kind")
    id = prefix * "_" * semantic_hash(descriptor)
    existing = findfirst(sort->sort["id"] == id,signature["sorts"])
    value = Dict("id"=>id,"descriptor"=>descriptor)
    if isnothing(existing)
        push!(signature["sorts"],value)
    else
        signature["sorts"][existing] == value || error("Sort descriptor identity collision")
    end
    return id
end

function semantic_operator!(signature, inputs, output, descriptor; version="relation-operators-v1")
    op = Dict("inputs"=>collect(String,inputs),"output"=>output,"purity"=>"pure",
        "read_rule"=>collect(0:length(inputs)-1),"binder_children"=>Int[],
        "semantic_version"=>version,"descriptor"=>descriptor)
    id = "op_" * operator_digest(op)
    op["symbol"] = id
    existing = findfirst(entry->entry["symbol"] == id,signature["operators"])
    if isnothing(existing)
        push!(signature["operators"],op)
    else
        signature["operators"][existing] == op || error("Operator descriptor identity collision")
    end
    return id
end

function definition_semantics(body, registry)
    used = Set{String}()
    walk_wire(body) do term, _
        kind = term["kind"]
        if kind in ("Call","Const")
            key = kind == "Call" ? term["operator"] : wire_text(term)
            op = registry[key]
            push!(used,haskey(op,"semantic_digest") ? op["semantic_digest"] : operator_digest(op))
        end
    end
    return semantic_hash(sort!(collect(used)))
end
