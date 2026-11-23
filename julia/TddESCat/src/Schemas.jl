function schema_context(registry::Dict{String,Primitive}, version="finite-pixel-v1")
    sorts = sort!(unique(vcat([op.output for op in values(registry)],
        (op.inputs for op in values(registry))...)))
    operators = [Dict("symbol" => name, "inputs" => registry[name].inputs,
        "output" => registry[name].output, "purity" => "pure",
        "read_rule" => registry[name].reads .- 1, "binder_children" => Int[]) for name in sort!(collect(keys(registry)))]
    return Dict("schema_version" => 1, "signature_id" => version,
        "sorts" => [Dict("id" => sort) for sort in sorts], "operators" => operators)
end
