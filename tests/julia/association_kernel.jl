include("stitch_fixture.jl")

const ROLE = ("RoleBefore","before")
const ACTION_SCENE = TC.RelationScope("ep","frame","interpretation","color-support","before")

function composed_query!(signature, slot; shared=[(1,0)])
    first = TC.relation_atom!(signature,"touch",[ROLE,ROLE];slot)
    second = TC.relation_atom!(signature,"reach",[ROLE,ROLE];slot)
    joined = TC.relation_join!(signature,first,second;shared,output=[0,1,3])
    return TC.relation_project!(signature,joined,[0,2])
end

function relation_examples(left, right; complete=true, scope=ACTION_SCENE)
    eval = TC.RelationEvaluation(scope,Dict("pre"=>1,"future"=>2),2)
    TC.observe_relation!(eval,"touch",[ROLE,ROLE],left;event_reads=["pre"],domain_complete=true)
    TC.observe_relation!(eval,"reach",[ROLE,ROLE],right;event_reads=["pre"],domain_complete=complete)
    return eval
end

@testset "Ordered columns, shared roles, and public read phases" begin
    sig = schema_context(evidence_signature())
    query = composed_query!(sig,0)
    first = [("a","k1"),("a","k2"),("b","k3")]
    second = [("k1","target"),("k2","target"),("k4","target"),("k2","other")]
    eval = relation_examples(first,second)
    result = TC.evaluate_relation(query.term,eval,sig;slots=["SceneBefore"])
    expected = Set((a,b) for (a,k) in first for (l,b) in second if k == l)
    @test Set(keys(result.rows)) == expected
    combined = eval.witnesses[result.rows[("a","target")]]
    @test combined["kind"] == "or"
    @test length(combined["parents"]) == 2
    @test all(eval.witnesses[parent]["kind"] == "and" for parent in combined["parents"])
    negative = relation_examples([("a","k1")],[("k2","target")])
    empty = TC.evaluate_relation(query.term,negative,sig;slots=["SceneBefore"])
    @test TC.relation_member(empty,("a","target")) == TC.disproven
    @test TC.relation_member([result,empty],("a","target");interpretation_complete=true) == TC.unknown_truth
    partial = relation_examples([("a","k1")],[("k2","target")];complete=false)
    unknown = TC.evaluate_relation(query.term,partial,sig;slots=["SceneBefore"])
    @test TC.relation_member(unknown,("a","target")) == TC.unknown_truth
    @test_throws ErrorException TC.observe_relation!(eval,"future",[ROLE],[("a",)];
        event_reads=["future"],domain_complete=true)
    after = TC.relation_atom!(sig,"post",[("RoleAfter","after")];phase="after")
    @test_throws ErrorException TC.evaluate_relation(after.term,eval,sig;slots=["SceneAfter"])
    @test render_term(query.term) != render_term(composed_query!(sig,0;shared=[(0,0)]).term)

    sort = TC.query_sort!(sig,[ROLE,ROLE])
    left = TC.relation_atom!(sig,"touch",[ROLE,ROLE]).term
    right = TC.relation_atom!(sig,"reach",[ROLE,ROLE]).term
    swapped = TC.relation_operator!(sig,"Rename",[sort],sort;layout=Dict("columns"=>[1,0]))
    @test haskey(TC.evaluate_relation(Call(swapped,left),eval,sig;slots=["SceneBefore"]).rows,("k1","a"))
    filtered = TC.relation_operator!(sig,"SelectEqual",[sort],sort;layout=Dict("left"=>0,"value"=>"a"))
    @test length(TC.evaluate_relation(Call(filtered,left),eval,sig;slots=["SceneBefore"]).rows) == 2
    union = TC.relation_operator!(sig,"Union",[sort,sort],sort)
    @test length(TC.evaluate_relation(Call(union,left,right),eval,sig;slots=["SceneBefore"]).rows) == 7
    negation = TC.relation_operator!(sig,"SafeNegate",[sort,sort],sort)
    domain = TC.relation_atom!(sig,"universe",[ROLE,ROLE]).term
    TC.observe_relation!(eval,"universe",[ROLE,ROLE],vcat(first,[("a","k4")]);
        event_reads=["pre"],domain_complete=true)
    complement = TC.evaluate_relation(Call(negation,left,domain),eval,sig;slots=["SceneBefore"])
    @test Set(keys(complement.rows)) == Set([("a","k4")])
    @test TC.relation_member(TC.evaluate_relation(Call(negation,left,domain),partial,sig;
        slots=["SceneBefore"]),("a","k4")) == TC.unknown_truth
end

@testset "V3 relation search and stable semantics" begin
    sig = schema_context(evidence_signature())
    programs = [render_term(composed_query!(sig,index).term) for index in 0:7]
    slots = [Dict("index"=>i,"sort"=>"SceneBefore","time_role"=>"before","role_constraints"=>[]) for i in 0:7]
    empty = LibrarySnapshot()
    job = execute_stitch(sig,"relations",programs,empty;slots,intent="relation")
    @test job.code == 0
    checked = read_stitch_rounds(job.job,job.output)
    @test checked.summary["fixed_point"]
    @test !isempty(first(checked.verified)["definitions"])
    @test any(item->item["source_kind"] == "constructed",checked.origins)
    @test length(checked.context["constructions"]) == 16
    directory = joinpath(RUN,"publication")
    digest = TC.publish_stitch!(directory,checked;current_evidence="snapshot-relations")
    publication = TC.read_published_stitch(directory;publication=digest)
    evaluation = relation_examples([("a","k")],[("k","b")])
    answer = TC.evaluate_relation(first(publication.bundle["rewritten_programs"]),evaluation,sig;
        slots=fill("SceneBefore",8),library=publication.snapshot.entries)
    @test TC.relation_member(answer,("a","b")) == TC.proven
    extended = deepcopy(sig)
    push!(extended["operators"],symbol("unrelated",String[],"Integer"))
    @test !isempty(TC.registry_from(extended,publication.snapshot.entries)[2])
    changed = deepcopy(sig)
    target = first(op for op in changed["operators"] if haskey(op,"descriptor"))
    target["descriptor"]["layout"]["name"] = "different"
    @test_throws ErrorException TC.registry_from(changed,publication.snapshot.entries)
    invalid_context = deepcopy(checked.context)
    reverse!(last(invalid_context["constructions"])["parents"])
    child = first(item for item in invalid_context["constructions"] if length(item["parents"]) > 1)
    reverse!(child["parents"])
    invalid = execute_stitch(sig,"copied-proof",programs,empty;slots,intent="relation",
        tamper=("semantic_context",invalid_context))
    @test invalid.code == 20

    extended = deepcopy(sig)
    push!(extended["sorts"],Dict("id"=>"Separate"))
    append!(extended["operators"],[symbol("separate",["Integer"],"Separate"),
        symbol("extend",["Separate"],"Separate")])
    texts = ["(extend (extend (extend (separate i$i))))" for i in 1:8]
    # Include the new literals in the same typed signature used by both jobs.
    for i in 1:8
        name = "i$i"
        any(op->op["symbol"] == name,extended["operators"]) ||
            push!(extended["operators"],symbol(name,String[],"Integer"))
    end
    prelude = TC.scoped_search_library(publication.snapshot,extended,texts,[])
    @test isempty(prelude.entries)
    separate = execute_stitch(extended,"scoped",texts,prelude)
    @test separate.code == 0
    scoped = read_stitch_rounds(separate.job,separate.output)
    @test !isempty(first(scoped.verified)["definitions"])
    scoped_digest = TC.publish_stitch!(directory,scoped;current_evidence="snapshot-scoped")
    merged = TC.read_published_stitch(directory;publication=scoped_digest)
    @test merged.snapshot.entries[1:length(publication.snapshot.entries)] == publication.snapshot.entries
    @test merged.bundle["initial_library_count"] == 0
    @test merged.bundle["cost"]["initial_library"] == "0"
    @test length(merged.snapshot.entries) > length(merged.bundle["library"])
    @test TC.scoped_search_library(merged.snapshot,extended,programs,slots).entries == publication.snapshot.entries
    @test TC.read_published_stitch(directory).snapshot.version == merged.snapshot.version
    @test_throws ErrorException TC.publish_stitch!(directory,scoped;current_evidence="snapshot-scoped")
    damaged = deepcopy(merged.bundle)
    empty!(damaged["global_library"]["entries"])
    @test_throws ErrorException TC.verify_published_stitch(damaged)
end

@testset "Explicit connectivity and large support roles" begin
    frame = fill(UInt8(0),64,64)
    frame[4,4] = 0x07
    frame[5,5] = 0x07
    sizes(connectivity) = [length(group) for group in TC.color_components(frame,connectivity).groups
        if first(group)[3] == 0x07]
    @test sizes(4) == [1,1]
    @test sizes(8) == [2]
    frame[12:52,12:52] .= 0x02
    frame[14:50,14:50] .= 0x00
    frame[26:32,26:32] .= 0x03
    parts = TC.public_components(frame)
    contour = only(group for group in parts if first(group)[3] == 0x02)
    @test length(contour) > 192
    @test any(item->item.signal == contour && first(item.target)[3] == 0x03,TC.enclosure_pairs(parts))
    cropped = frame[25:45,25:45]
    @test !any(item->first(item.target)[3] == 0x03,
        TC.enclosure_pairs(TC.public_components(cropped)))
end
