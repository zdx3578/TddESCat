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
constant(index) = "c" * lpad(index, 2, '0')
signature = Dict(
    "schema_version" => 1, "signature_id" => "two-batches", "sorts" => [Dict("id" => "Atom"), Dict("id" => "Other")],
    "operators" => [
        symbol("f", ["Atom", "Atom"]); symbol("g", ["Atom"]);
        [symbol(constant(i), String[]) for i in 0:63];
        symbol("extra", ["Other"], "Other"); symbol("other", String[], "Other")
    ],
)

function batch(first)
    return ["(f (g $(constant(i))) (g $(constant(i+1))))" for i in first:2:first+30]
end

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

function execute(name, texts, library; config=CONFIG, source_origins=nothing)
    job = joinpath(RUN, name * "-input")
    output = joinpath(RUN, name * "-output")
    origins = isnothing(source_origins) ? frame_origins(signature, texts, library) : source_origins
    freeze_stitch_job(job, name, "snapshot-" * name, library, signature, texts, origins, [];
                      repo_root=ROOT, config_path=config)
    command = `$PYTHON -m tddesc_tools.stitch --job $job --output $output --binary $WORKER`
    return (; job, output, code=run(ignorestatus(command)).exitcode)
end

@testset "Real typed E-Stitch and exact frozen-library reuse" begin
    empty = LibrarySnapshot()
    positive = execute("positive", batch(0), empty)
    @test positive.code == 0
    @test isfile(joinpath(positive.output, "round-000001", "result.json"))
    result = read_stitch_rounds(positive.job, positive.output)
    @test length(result.verified) == 2
    learned = result.verified[1]
    @test learned["cost"]["pre_rewrite_input"] == "81"
    @test learned["cost"]["final_total"] == "54"
    @test length(learned["calls"]) == 16
    @test all(length(call["source_occurrences"]) == 5 for call in learned["calls"])
    proof_exchange = deepcopy(learned)
    proof_exchange["proofs"][1]["steps"][1]["site_path"] = [1]
    @test_throws ErrorException TC.check_stitch_result(
        proof_exchange, result.manifest, signature, [], batch(0), frame_origins(signature, batch(0), empty),
    )
    swapped = deepcopy(only(learned["definitions"]))
    swapped["closed_lambda_text"] = "(lam (lam (f (g \$0) (g \$1))))"
    registry, _ = TC.registry_from(signature, empty.entries)
    @test_throws ErrorException TC.decode_definition(swapped, registry)
    @test_throws ErrorException publish_library(
        empty, learned, result.manifest, signature; current_version=empty.version, current_evidence="different",
    )
    accepted = publish_library(
        empty, learned, result.manifest, signature; current_version=empty.version, current_evidence="snapshot-positive",
    )
    library = accepted.snapshot
    lib = only(library.entries)["stable_id"]
    TC.atomic_json(joinpath(RUN, "published-library.json"), library.entries)
    second = execute("reuse", batch(32), library)
    @test second.code == 0
    old = only(read_stitch_rounds(second.job, second.output).verified)
    @test isempty(old["definitions"])
    @test old["cost"]["post_rewrite_baseline"] == "49"
    @test old["cost"]["initial_library"] == "5"
    @test old["cost"]["final_total"] == "54"
    @test length(old["calls"]) == 16 && all(call["definition_ref"] == lib for call in old["calls"])
    @test all(occursin(lib, line) for line in old["rewritten_programs"])
    @test length(unique(call["source_occurrences"][1] for call in old["calls"])) == 16
    missing = execute("missing", ["($lib c32 c33)"], empty; source_origins=[])
    @test missing.code == 20 && isempty(readdir(missing.output))
    invalid = execute("wrong-sort", ["(f (g other) c03)"], empty)
    @test invalid.code == 20 && isempty(readdir(invalid.output))
    cutoff = joinpath(RUN, "cutoff.toml")
    write(cutoff, replace(read(CONFIG, String), "max_steps = 20000" => "max_steps = 1"))
    stopped = execute("bounded", batch(0), empty; config=cutoff)
    @test stopped.code == 22 && isempty(readdir(stopped.output))
    mixed = execute("mixed-sort", [batch(0); "(extra other)"], empty)
    @test mixed.code == 0
    m = first(read_stitch_rounds(mixed.job, mixed.output).verified)
    @test m["cost"]["final_total"] == "56"
    @test learned["definitions"][1]["body_cost"] == "5"
    saved_limit = joinpath(RUN, "saved-limit.toml")
    write(saved_limit, replace(read(CONFIG, String), "max_steps = 20000" => "max_steps = 70"))
    interrupted = execute("after-round", batch(0), empty; config=saved_limit)
    @test interrupted.code == 10
    mkpath(joinpath(interrupted.output, "round-000002.tmp"))
    prior = only(read_stitch_rounds(interrupted.job, interrupted.output).verified)
    @test prior["cost"]["final_total"] == "54"
    println(JSON.json(Dict("batch_one" => learned["cost"], "batch_two" => old["cost"],
                           "library_definition" => lib, "second_batch_calls" => length(old["calls"]))))
end
