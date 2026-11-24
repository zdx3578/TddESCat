include("stitch_fixture.jl")

import TOML

const EXPERIMENT = abspath(ARGS[2])
const PROFILE = TOML.parsefile(EXPERIMENT)
const POLICY = normpath(joinpath(dirname(EXPERIMENT), PROFILE["stitch_policy"]))
const EMPTY = LibrarySnapshot()

signature_for(name, sorts, ops) = Dict("schema_version"=>3, "signature_id"=>name,
    "sorts"=>[Dict("id"=>sort) for sort in sorts], "operators"=>ops)
slots_for(sorts) = [Dict("index"=>i-1,"sort"=>sort,"time_role"=>"timeless",
    "role_constraints"=>[]) for (i,sort) in enumerate(sorts)]
ref_slot(index) = "\$" * string(index)

function checked(job; fixed=true)
    @test job.code == (fixed ? 0 : 10)
    rounds = read_stitch_rounds(job.job, job.output)
    @test rounds.summary["fixed_point"] == fixed
    @test rounds.summary["scope_refs"]["policy"] == TC.content_hash(read(POLICY))
    @test TC.read_json(joinpath(job.output,"worker-policy.json"))["policy_sha256"] ==
        rounds.summary["scope_refs"]["policy"]
    return rounds
end

function publish(job, rounds, directory)
    digest = TC.publish_stitch!(directory, rounds; current_evidence=rounds.manifest["evidence_snapshot_id"])
    return TC.read_published_stitch(directory; publication=digest)
end

function balanced(parts, join, lo=firstindex(parts), hi=lastindex(parts))
    lo == hi && return parts[lo]
    mid = (lo + hi) ÷ 2
    return join(balanced(parts, join, lo, mid), balanced(parts, join, mid + 1, hi), lo, hi)
end

function codec_fixture(width)
    definitions = Dict(
        "temporary_name"=>"fn_0", "arity"=>width, "parameter_sorts"=>fill("Atom",width),
        "result_sort"=>"Atom", "parameter_reads"=>collect(0:width-1), "dependencies"=>String[])
    body = width == 0 ? TC.wire_const("Atom","atom") : width == 1 ? TC.wire_call("wrap",[TC.wire_parameter(0)]) :
        balanced(TC.wire_parameter.(0:width-1), (a,b,_,_)->TC.wire_call("combine",[a,b]))
    definitions["body"] = body
    definitions["pattern_text"] = TC.wire_text(body)
    definitions["closed_lambda_text"] = TC.lambda_text(body,width)
    definitions["body_cost"] = string(TC.wire_cost(body))
    sig = signature_for("codec",["Atom"],[symbol("atom",String[]),symbol("wrap",["Atom"]),
        symbol("combine",["Atom","Atom"])])
    registry, known = TC.registry_from(sig,[])
    definitions["semantic_digest"] = TC.definition_semantics(body,registry)
    TC.check_register!(registry,known,"fn_0",definitions)
    return definitions, registry
end

function wide_corpus(width, count)
    result_sort(lo,hi) = "Branch-$lo-$hi"
    role(index) = "Role-$index"
    operators = [symbol("leaf-$i",[role(i)],result_sort(i,i)) for i in 1:width]
    sorts = [role.(1:width); [result_sort(i,i) for i in 1:width]]
    function op(a, b, lo, hi)
        middle = (lo + hi) ÷ 2
        name = "branch-$lo-$hi"
        result = result_sort(lo,hi)
        if name ∉ (item["symbol"] for item in operators)
            push!(operators,symbol(name,[result_sort(lo,middle),result_sort(middle+1,hi)],result))
            push!(sorts,result)
        end
        return "($name $a $b)"
    end
    text = [balanced(["(leaf-$i " * ref_slot(instance*width+i-1) * ")" for i in 1:width], op)
        for instance in 0:count-1]
    return signature_for("wide-$width",sorts,operators), text, slots_for(repeat(role.(1:width),count))
end

function library_depths(entries)
    depths = Dict{String,Int}()
    for entry in entries
        depths[entry["stable_id"]] = 1 + maximum((depths[id] for id in entry["definition"]["dependencies"]); init=0)
    end
    return depths
end

@testset "E-Stitch open learning policy" begin
    @test PROFILE["experiment_id"] == "estitch-open-v1"
    @test POLICY == CONFIG
    policy = TC.stitch_policy(read(POLICY,String))
    @test policy["max_arity"] == 1000
    @test_throws ArgumentError TC.stitch_policy("schema_version = 1\nmax_arity = 2\nrounds = 2")
    wide = PROFILE["wide_interfaces"]
    for width in wide["codec_arities"]
        d, registry = codec_fixture(width)
        call = TC.wire_call("fn_0",TC.wire_slot.(0:width-1))
        decoded = TC.decode_program(TC.wire_text(call),registry)
        @test decoded == call
        @test TC.wire_sort(decoded,registry;slots=fill("Atom",width)) == "Atom"
        bad = deepcopy(d)
        bad["closed_lambda_text"] = "(lam " * bad["closed_lambda_text"] * ")"
        @test_throws ErrorException TC.decode_definition(bad,registry)
        if width > 0
            bad = deepcopy(d)
            bad["parameter_sorts"][1] = "Missing"
            @test_throws ErrorException TC.decode_definition(bad,registry)
        end
    end

    wide_results = []
    for width in wide["search_arities"]
        sig, text, slots = wide_corpus(width,wide["instances_per_shape"])
        input = execute_stitch(sig,"wide-$width",text,EMPTY;slots,config=POLICY)
        rounds = checked(input)
        published = publish(input,rounds,joinpath(RUN,"wide-$width-publication"))
        values = [entry["definition"]["arity"] for entry in published.snapshot.entries]
        @test width in values
        @test TC.decimal_cost(published.bundle["cost"]["final_total"]) <
            TC.decimal_cost(published.bundle["cost"]["ratio_numerator"])
        @test length(published.bundle["rewritten_programs"]) == length(text)
        push!(wide_results,(; width, actual_arities=values, cost=published.bundle["cost"],
            rounds=rounds.summary["search_rounds"], heap_pops=rounds.summary["total_heap_pops"]))
        println("Verified search width $width with actual arities $values")
    end

    size = PROFILE["round_progress"]
    families, instances = size["independent_families"], size["instances_per_family"]
    sig = signature_for("independent-families",["Atom"],
        [symbol("$op-$family",["Atom"]) for family in 1:families for op in ("a","b","c")])
    text = ["(a-$i (b-$i (c-$i " * ref_slot(j) * ")))" for i in 1:families for j in 0:instances-1]
    slots = slots_for(fill("Atom",instances))
    independent = execute_stitch(sig,"independent",text,EMPTY;slots,config=POLICY)
    rounds = checked(independent)
    published = publish(independent,rounds,joinpath(RUN,"independent-publication"))
    @test length(published.bundle["new_definition_ids"]) == families
    @test rounds.summary["search_rounds"] == families + 1
    @test all(==(1),values(library_depths(published.snapshot.entries)))
    cost = published.bundle["cost"]
    @test parse(Int,cost["pre_rewrite_input"]) == 1 + families*instances*4 == 769
    @test parse(Int,cost["final_total"]) == 1 + families*(instances*2+4) == 481
    prefixes = []
    for count in policy["progress"]["accepted_definition_checkpoints"]
        count <= families || continue
        result = rounds.verified[count]
        index = TC.read_json(joinpath(independent.output,"accepted-" * lpad(count,6,'0') * ".json"))
        @test index["checkpoint_sha256"] == rounds.checkpoint_digests[count]
        @test index["final_total"] == result["cost"]["final_total"]
        snapshot = publish_library(EMPTY,result,rounds.manifest,sig;
            current_version=EMPTY.version,current_evidence=rounds.manifest["evidence_snapshot_id"])
        push!(prefixes,(; accepted=count,total=result["cost"]["final_total"],
            depth=maximum(values(library_depths(snapshot.snapshot.entries))),
            heap_pops=sum(r["round_metrics"]["heap_pops"] for r in rounds.verified[1:count])))
    end

    dependency = PROFILE["dependency"]
    @test dependency["batches"] == 3
    instances = dependency["instances_per_batch"]
    sig = signature_for("dependent-families",["Atom"],[symbol(op,["Atom"]) for op in ("a","b","c","d","e","h","i")])
    slots = slots_for(fill("Atom",instances))
    directory = joinpath(RUN,"dependent-publication")
    library = EMPTY
    definitions = String[]
    dependent = []
    for (number,(outer,inner)) in enumerate((("a","b"),("d","e"),("h","i")))
        dep = isempty(definitions) ? "c" : last(definitions)
        text = ["($outer ($inner ($dep " * ref_slot(j) * ")))" for j in 0:instances-1]
        input = execute_stitch(sig,"dep-$number",text,library;slots,config=POLICY)
        rounds = checked(input)
        accepted = publish(input,rounds,directory)
        id = only(accepted.bundle["new_definition_ids"])
        library = accepted.snapshot
        push!(definitions,id)
        @test all(call -> call["definition_ref"] == id,accepted.bundle["calls"])
        @test library_depths(library.entries)[id] == number
        wanted = number == 1 ? [] : [definitions[end-1]]
        @test last(library.entries)["definition"]["dependencies"] == wanted
        push!(dependent,(; id, depth=number, dependencies=wanted,
            input_sha256=rounds.input_sha, cost=accepted.bundle["cost"]))
    end
    @test_throws ErrorException TC.registry_from(sig,library.entries[2:end])

    sizes = PROFILE["input_capacity"]
    count = sizes["minimum_programs"]
    sig = signature_for("complete-input",["Atom"],[symbol("op-$i",["Atom"]) for i in 1:6])
    text = [foldr((i,t)->"(op-$i $t)",1:6;init=ref_slot(mod(j,8))) for j in 1:count]
    input = execute_stitch(sig,"complete-input",text,EMPTY;slots=slots_for(fill("Atom",8)),config=POLICY)
    rounds = checked(input)
    origin_bytes = filesize(joinpath(input.job,"origins.json"))
    @test origin_bytes >= sizes["minimum_origins_bytes"]
    @test all(length(r["proofs"]) == count for r in rounds.verified)
    @test length(rounds.origins) == count*7
    @test last(rounds.verified)["rewritten_programs"][count] != text[count]
    empty_job = execute_stitch(sig,"empty",String[],EMPTY;config=POLICY)
    @test empty_job.code == 0
    empty_rounds = read_stitch_rounds(empty_job.job,empty_job.output)
    @test isempty(empty_rounds.verified) && empty_rounds.summary["termination_reason"] == "no_eligible_corpus"
    partial = execute_stitch(sig,"unresolved",text[1:8],EMPTY;
        slots=slots_for(fill("Atom",8)),config=POLICY,input_scope_complete=false)
    rounds_partial = checked(partial;fixed=false)
    @test rounds_partial.summary["termination_reason"] == "input_scope_incomplete"
    @test last(rounds_partial.verified)["round_outcome"] == "no_positive_gain"
    TC.atomic_json(joinpath(RUN,"open-structure.json"),(; wide=wide_results,
        independent=(; definitions=families, cost, prefixes, summary=TC.read_json(joinpath(independent.output,"learning-summary.json"))),
        dependent, complete_input=(; programs=count, origin_bytes, occurrences=length(rounds.origins),
            terminal=rounds.summary)))
end
