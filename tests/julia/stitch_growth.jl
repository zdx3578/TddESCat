include("stitch_fixture.jl")

const EMPTY = LibrarySnapshot()
const ATOM_SLOTS = [Dict("index"=>index,"sort"=>"Atom","time_role"=>"timeless","role_constraints"=>[])
    for index in 0:7]

function checked_growth(signature,name,text,library; publication=joinpath(RUN,name * "-publication"))
    job = execute_stitch(signature,name,text,library;slots=ATOM_SLOTS)
    @test job.code == 0
    verified = read_stitch_rounds(job.job,job.output)
    @test verified.summary["fixed_point"]
    hash = TC.publish_stitch!(publication,verified;
        current_evidence=verified.manifest["evidence_snapshot_id"])
    return TC.read_published_stitch(publication;publication=hash),verified
end

function signature_for_growth(name, operators)
    return Dict("schema_version"=>3,"signature_id"=>name,
        "sorts"=>[Dict("id"=>"Atom")],"operators"=>operators)
end

@testset "Independent concept count and genuine dependency growth" begin
    counts = []
    for family_count in (48,96)
        signature = signature_for_growth("independent-concepts",
            [symbol("$op-$i",["Atom"]) for i in 1:family_count for op in ("a","b","c")])
        text = ["(a-$i (b-$i (c-$i \$$slot)))" for i in 1:family_count for slot in 0:7]
        data,rounds = checked_growth(signature,"families-$family_count",text,EMPTY)
        @test length(data.snapshot.entries) == family_count
        @test all(==(1),values(data.bundle["definition_depths"]))
        @test rounds.summary["search_rounds"] == family_count + 1
        @test parse(Int,data.bundle["cost"]["pre_rewrite_input"]) == 1 + 32family_count
        @test parse(Int,data.bundle["cost"]["final_total"]) == 1 + 20family_count
        push!(counts,(; family_count,cost=data.bundle["cost"],
            rounds=rounds.summary["search_rounds"],heap_pops=rounds.summary["total_heap_pops"]))
    end

    signature = signature_for_growth("dependent-concepts",
        [symbol("root",["Atom"]);[symbol("$op-$i",["Atom"]) for i in 1:8 for op in ("a","b")]])
    library = EMPTY
    parent = "root"
    layers = []
    for layer in 1:8
        text = ["(a-$layer (b-$layer ($parent \$$slot)))" for slot in 0:7]
        data,rounds = checked_growth(signature,"layer-$layer",text,library;
            publication=joinpath(RUN,"dependent-publication"))
        id = only(data.bundle["new_definition_ids"])
        @test data.bundle["definition_depths"][id] == layer
        @test all(call["definition_ref"] == id for call in data.bundle["calls"])
        @test last(data.snapshot.entries)["definition"]["dependencies"] == (layer == 1 ? [] : [parent])
        layer == 1 || @test_throws ErrorException TC.registry_from(signature,data.snapshot.entries[2:end])
        push!(layers,(; depth=layer,id,parent,cost=data.bundle["cost"],rounds=rounds.summary["search_rounds"]))
        library = data.snapshot
        parent = id
    end
    registry,_ = TC.registry_from(signature,library.entries)
    nested(depth) = repeat("(root ",depth) * "\$0" * repeat(")",depth)
    @test TC.wire_sort(TC.decode_program(nested(59),registry),registry;slots=["Atom"]) == "Atom"
    for depth in (60,256)
        @test_throws ErrorException TC.decode_program(nested(depth),registry)
    end
    TC.atomic_json(joinpath(RUN,"growth.json"),(; counts,layers,codec_depth=(accepted=59,rejected=[60,256])))
end
