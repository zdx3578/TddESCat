include("stitch_fixture.jl")

constant(index) = "c" * lpad(index, 2, '0')
signature = Dict(
    "schema_version" => 3, "signature_id" => "two-batches", "sorts" => [Dict("id" => "Atom"), Dict("id" => "Other")],
    "operators" => [
        symbol("f", ["Atom", "Atom"]); symbol("g", ["Atom"]); symbol("wrap", ["Atom"]);
        [symbol(constant(i), String[]) for i in 0:63];
        symbol("extra", ["Other"], "Other"); symbol("other", String[], "Other")
    ],
)

function batch(first)
    return ["(f (g $(constant(i))) (g $(constant(i+1))))" for i in first:2:first+30]
end

execute(name, texts, library; options...) = execute_stitch(signature, name, texts, library; options...)

@testset "Nested reverse proof preserves its substitutions" begin
    atom = TC.wire_const("Atom","c00")
    g(term) = TC.wire_call("g",[term])
    registry, _ = TC.registry_from(signature,[])
    definitions = Dict()
    for name in ("fn_1","fn_2")
        registry[name] = Dict("inputs"=>["Atom"],"output"=>"Atom")
        definitions[name] = Dict("arity"=>1,"parameter_sorts"=>["Atom"],
            "body"=>g(TC.wire_parameter(0)))
    end
    start = g(g(g(atom)))
    finish = TC.wire_call("fn_1",[g(TC.wire_call("fn_2",[atom]))])
    step(name, path, term) = Dict("kind"=>"rule","premise_refs"=>[],
        "rule_id"=>"def."*name,"substitution"=>[Dict("parameter"=>0,"term"=>term)],
        "direction"=>"reverse","site_path"=>path)
    proof = Dict("left_term"=>start,"right_term"=>finish,
        "steps"=>[step("fn_1",Int[],g(g(atom))),step("fn_2",[0,0],atom)])
    frozen = deepcopy(proof)
    @test TC.replay_proof(proof,start,finish,definitions,registry,String[]) == finish
    @test proof == frozen
    @test TC.replay_proof(proof,start,finish,definitions,registry,String[]) == finish
end

@testset "Real typed E-Stitch and exact frozen-library reuse" begin
    empty = LibrarySnapshot()
    positive = execute("positive", batch(0), empty)
    @test positive.code == 0
    @test isfile(joinpath(positive.output, "round-000001", "result.json"))
    result = read_stitch_rounds(positive.job, positive.output)
    @test length(result.verified) == 2
    @test result.summary["fixed_point"]
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
    wrapped = [batch(0)[1:15]; "(wrap " * last(batch(0)) * ")"]
    nested = execute("nested-origin", wrapped, empty)
    @test nested.code == 0
    nested_rounds = read_stitch_rounds(nested.job, nested.output)
    nested_result = first(nested_rounds.verified)
    call_index = findfirst(c -> c["program_index"] == 15 && c["call_path"] == [0], nested_result["calls"])
    @test !isnothing(call_index)
    for corruption in ("wrong-site", "missing", "duplicate")
        invalid_origin = deepcopy(nested_result)
        sites = invalid_origin["calls"][call_index]["source_occurrences"]
        if corruption == "wrong-site"
            sites[1] = "occ-15"
        elseif corruption == "missing"
            pop!(sites)
        else
            push!(sites, first(sites))
        end
        @test_throws ErrorException TC.check_stitch_result(invalid_origin, nested_rounds.manifest,
            signature, [], wrapped, nested_rounds.origins)
    end
    directory = joinpath(RUN, "publication")
    @test_throws ErrorException TC.publish_stitch!(directory, result; current_evidence="unrelated")
    @test !isfile(joinpath(directory, "current.json"))
    digest = TC.publish_stitch!(directory, result; current_evidence="snapshot-positive")
    restored = TC.read_published_stitch(directory)
    @test restored.publication == digest
    @test all(c["definition_ref"] == lib for c in restored.bundle["calls"])
    @test all(occursin(lib, line) for line in restored.bundle["rewritten_programs"])
    @test_throws ErrorException TC.publish_stitch!(directory, result; current_evidence="snapshot-positive")
    @test TC.read_published_stitch(directory).publication == digest
    missing = execute("missing", ["(f c32 c33)"], empty; tamper=("origins",[]))
    @test missing.code == 20 && isempty(filter(n->startswith(n,"round-"),readdir(missing.output)))
    invalid = execute("wrong-sort", ["(f (g c02) c03)"], empty;
        tamper=("programs",["(f (g other) c03)"]))
    @test invalid.code == 20 && isempty(filter(n->startswith(n,"round-"),readdir(invalid.output)))
    stopped = execute("before-commit", batch(0), empty; fault="before-first-commit")
    @test stopped.code == 22 && isempty(filter(n->startswith(n,"round-"),readdir(stopped.output)))
    @test TC.read_json(joinpath(stopped.output,"learning-summary.json"))["termination_reason"] == "cancelled"
    mixed = execute("mixed-sort", [batch(0); "(extra other)"], empty)
    @test mixed.code == 0
    m = first(read_stitch_rounds(mixed.job, mixed.output).verified)
    @test m["cost"]["final_total"] == "56"
    @test learned["definitions"][1]["body_cost"] == "5"
    interrupted = execute("after-round", batch(0), empty; fault="after-first-commit")
    @test interrupted.code == 10
    prior = only(read_stitch_rounds(interrupted.job, interrupted.output).verified)
    @test prior["cost"]["final_total"] == "54"
    @test TC.read_json(joinpath(interrupted.output,"metrics.json"))["complete_rounds"] == 1
    stopped_write = execute("during-write", batch(0), empty; fault="during-first-write")
    @test stopped_write.code == 22
    @test isfile(joinpath(stopped_write.output,"round-000001.tmp","result.json"))
    @test isempty(read_stitch_rounds(stopped_write.job, stopped_write.output).verified)
    @test TC.read_json(joinpath(stopped_write.output,"learning-summary.json"))["interrupted_phase"] == "serialize"
    damaged = joinpath(RUN, "damaged-checkpoint")
    cp(interrupted.output, damaged)
    open(joinpath(damaged, "round-000001", "result.json"), "a") do io
        write(io, " ")
    end
    @test_throws ErrorException read_stitch_rounds(interrupted.job, damaged)
    small_chunks = joinpath(RUN,"small-chunks.toml")
    write(small_chunks, replace(read(CONFIG,String),"apply_chunk_rows = 128"=>"apply_chunk_rows = 1"))
    chunked = execute("chunked",batch(0),empty;config=small_chunks)
    @test chunked.code == 0
    new = first(read_stitch_rounds(chunked.job,chunked.output).verified)
    for key in ("proofs","calls","definitions","rewritten_programs","cost")
        @test new[key] == learned[key]
    end
    measured = TC.read_json(joinpath(chunked.output,"metrics.json"))
    @test isnothing(measured["managed_byte_limit"])
    @test all(key -> measured["phases"][key]["peak_live_bytes"] > 0,
        ["load","graph","search","apply","extract","proof","serialize","commit"])
    memory = execute("resource-stop",batch(0),empty;fault="resource-load")
    @test memory.code == 22
    @test TC.read_json(joinpath(memory.output,"learning-summary.json"))["termination_reason"] == "resource_failure"
    println(JSON.json(Dict("batch_one" => learned["cost"], "batch_two" => old["cost"],
                           "library_definition" => lib, "second_batch_calls" => length(old["calls"]))))
end
