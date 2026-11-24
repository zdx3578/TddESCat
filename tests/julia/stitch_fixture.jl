using Test
using TddESCat
import JSON

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const RUN = abspath(ARGS[1])
const PYTHON = joinpath(ROOT, ".venv", "bin", "python")
const WORKER = joinpath(ROOT, "target", "release", "tddesc-stitch")
const CONFIG = joinpath(ROOT, "config", "stitch.toml")
const TC = TddESCat

isempty(mkpath(RUN) |> readdir) || error("Use a fresh run directory")
symbol(name, inputs, output="Atom") = Dict(
    "symbol" => name, "inputs" => inputs, "output" => output, "purity" => "pure",
    "read_rule" => collect(0:length(inputs)-1), "binder_children" => Int[],
)
function frame_origins(signature, programs, library)
    registry, _ = TC.registry_from(signature, library.entries)
    records = []
    for (index, text) in enumerate(programs)
        TC.walk_wire(TC.decode_program(text, registry)) do _, path
            push!(records, Dict(
                "program_index" => index - 1, "expression_path" => path,
                "occurrence_id" => "occ-" * join([index - 1; path], "."),
                "event_ref" => "symbolic-$(index - 1)", "interpretation_ref" => "structure-d0",
                "slot_bindings_ref" => "empty", "support_ref" => "synthetic",
            ))
        end
    end
    return records
end

function execute_stitch(signature, name, texts, library; slots=[], config=CONFIG, source_origins=nothing,
                        fault=nothing, input_scope_complete=true)
    job = joinpath(RUN, name * "-input")
    output = joinpath(RUN, name * "-output")
    origins = isnothing(source_origins) ? frame_origins(signature, texts, library) : source_origins
    freeze_stitch_job(job, name, "snapshot-" * name, library, signature, texts, origins, slots;
                      repo_root=ROOT, config_path=config, input_scope_complete)
    command = `$PYTHON -m tddesc_tools.stitch --job $job --output $output --binary $WORKER`
    isnothing(fault) || (command = `$command --test-fault $fault`)
    return (; job, output, code=run(ignorestatus(command)).exitcode)
end
