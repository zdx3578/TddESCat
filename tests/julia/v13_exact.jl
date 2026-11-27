using Test
using TddESCat
const TC = TddESCat
const ROOT = normpath(joinpath(@__DIR__,"../.."))

@testset "JSON input and canonical identity" begin
    @test TC.parse_json("{\"a\":{\"b\":null}}") == Dict("a"=>Dict("b"=>nothing))
    @test TC.parse_json("{\"a\":{\"b\":null}}")["a"] isa Dict{String,Any}
    @test_throws Exception TC.parse_json("NaN")
    @test TC.canonical_bytes(Dict("b"=>Any[1,true,nothing],"a"=>"汉/\n\0\x7f")) ==
        "{\"a\":\"汉/\\n\\u0000\\u007f\",\"b\":[1,true,null]}"
end

@testset "Galley Boolean join and evidence read ranges" begin
    a = [(1,3),(2,1),(2,1),(2,2)]
    b = [(2,1),(7,2),(2,1)]
    @test Set(TC.galley_join_pairs(a,b)) == Set((i,j) for i in eachindex(a), j in eachindex(b) if a[i] == b[j])
    @test isempty(TC.galley_join_pairs(a,Tuple{Int,Int}[]))
    @test isempty(TC.galley_join_pairs([(1,)],[(2,)]))
    @test Set(TC.exact_join_pairs(a,b)) == Set(TC.galley_join_pairs(a,b))
    large = [(i%7,i%3) for i in 1:65]
    @test Set(TC.exact_join_pairs(large,reverse(large))) ==
        Set(TC.indexed_join_pairs(large,reverse(large)))

    header = [("Integer","before")]
    function evaluation(event,rows;view="public")
        scope = TC.RelationScope("episode","binding","atoms",view,"before")
        context = TC.RelationEvaluation(scope,Dict(event=>1),2)
        TC.observe_relation!(context,"role",header,rows;event_reads=[event],domain_complete=true)
        return context
    end
    first_view = evaluation("event-a",[])
    TC.read_relation_range!(first_view,"role",(3,))
    read = first_view.reads[("role",(3,))]
    @test TC.relation_read_current(read,evaluation("event-b",[(1,)]))
    @test !TC.relation_read_current(read,evaluation("event-c",[(3,)]))
    @test !TC.relation_read_current(read,evaluation("event-d",[];view="unrelated"))
end

function with_worker(f,path,args...)
    worker = TC.ComputeWorker(Cmd([path,args...]))
    try
        f(worker)
    finally
        close(worker)
    end
end

@testset "Distinct observations count once per declared role" begin
    role = ("Role","before")
    item = ("Member","before")
    event = ("Event","timeless")
    signature = Dict{String,Any}("schema_version"=>3,"signature_id"=>"distinct-count-test",
        "sorts"=>Dict{String,Any}[],"operators"=>Dict{String,Any}[])
    observation = TC.relation_atom!(signature,"membership",[role,item,event])
    roles = TC.relation_atom!(signature,"observed-roles",[role])
    count = TC.relation_count_distinct!(signature,observation,roles;groups=[0],distinct=[1])
    reports = [("actor-a","member-x","event-1"),("actor-a","member-x","event-2"),
        ("actor-a","member-y","event-2")]
    function run_count(;closed=true)
        scope = TC.RelationScope("episode","fresh","observed","roles","before")
        context = TC.RelationEvaluation(scope,Dict("event-1"=>1,"event-2"=>2),3)
        TC.observe_relation!(context,"membership",[role,item,event],reports;
            event_reads=["event-1","event-2"],domain_complete=closed)
        TC.observe_relation!(context,"observed-roles",[role],[("actor-a",),("actor-b",)];
            event_reads=["event-1"],domain_complete=true)
        return TC.evaluate_relation(count.term,context,signature;slots=["SceneBefore"]),context
    end
    exact,context = run_count()
    @test Set(keys(exact.rows)) == Set([("actor-a",2),("actor-b",0)])
    @test TC.relation_member(exact,("actor-a",3)) == TC.disproven
    @test context.witnesses[exact.rows[("actor-a",2)]]["kind"] == "distinct_count"
    partial,_ = run_count(;closed=false)
    @test isempty(partial.rows)
    @test TC.relation_member(partial,("actor-b",0)) == TC.unknown_truth
end

@testset "Relation pages preserve the typed range after recovery" begin
    header = [("Role","before"),("Integer","timeless")]
    function observed(rows;complete=true)
        scope = TC.RelationScope("episode","slot","views","roles","before")
        evaluation = TC.RelationEvaluation(scope,Dict("source"=>1),2)
        TC.observe_relation!(evaluation,"observed",header,rows;event_reads=["source"],domain_complete=complete)
        return evaluation
    end
    rows = [("a",1),("a",3),("b",1),("b",2)]
    first_view = observed(rows)
    bound = TC.relation_page!(first_view,"observed",("a",1),1)
    @test bound.coverage == "complete" && first(only(bound.rows)) == ("a",1)
    first_page = TC.relation_page!(first_view,"observed",("a",nothing),1)
    @test first_page.coverage == "partial"
    cursor = TC.parse_json(TC.canonical_bytes(first_page.cursor))
    second_view = observed(vcat(rows,[("b",4)]))
    second_page = TC.relation_page!(second_view,"observed",("a",nothing),3;cursor)
    @test second_page.coverage == "complete" && second_page.cursor === nothing
    @test [first(only(first_page.rows)),first(only(second_page.rows))] == [("a",1),("a",3)]
    changed = TC.relation_page!(observed(vcat(rows,[("a",5)])),"observed",("a",nothing),1;cursor)
    @test changed.execution == "invalidated" && isempty(changed.rows)
    malformed = TC.relation_page!(first_view,"observed",("a",nothing),1;cursor=true)
    @test malformed.execution == "invalidated"
    partial = TC.relation_page!(observed(rows;complete=false),"observed",("a",nothing),9)
    @test partial.coverage == "unknown" && length(partial.rows) == 2
end

@testset "An exact count can separate a mechanism guard with the same neighbor colors" begin
    base = fill(UInt8(0),24,24)
    base[10:12,10:12] .= 4
    base[9,11] = 2
    two = copy(base)
    two[13,11] = 2
    function witness(frame,id,truth)
        support = TC.point_component(TC.public_components(frame),(10,10))
        sample = TC.MotionExample(id,"before-" * id,1,frame,frame,[0])
        return TC.AssociationExample(sample,TC.MotionBinding(support,TC.anchor(support)),truth)
    end
    negative = witness(base,"one",TC.disproven)
    positive = witness(two,"two",TC.proven)
    predicate = TC.construct_relation([negative,positive])
    @test !isnothing(predicate)
    @test all(candidate["neighbor_count"] == 2 && candidate["pigment"] == 2
        for candidate in predicate.certificate["candidates"])
    @test TC.evaluate_predicate(predicate,two,positive.binding,(0,0),[0]) == TC.proven
    @test TC.evaluate_predicate(predicate,base,negative.binding,(0,0),[0]) == TC.disproven
end

@testset "A compound role keeps the typed colors of its external neighbors" begin
    function witness(x,y,count,name,verdict)
        frame = zeros(UInt8,24,24)
        frame[y:y+1,x:x+1] .= 0x04
        frame[y:y+1,x+2:x+3] .= 0x08
        frame[y-1,x] = 0x02
        count == 2 && (frame[y+2,x+3] = 0x02)
        groups = TC.color_components(frame).groups
        support = sort!(reduce(vcat,filter(s->first(s)[3] in (0x04,0x08),groups)))
        sample = TC.MotionExample(name,"before-" * name,1,frame,frame,[0])
        return TC.AssociationExample(sample,TC.MotionBinding(support,TC.anchor(support)),verdict)
    end
    negative = witness(8,9,1,"compound-one",TC.disproven)
    positive = witness(8,9,2,"compound-two",TC.proven)
    frame = positive.sample.before
    support = positive.binding.support
    features = TC.support_features(frame,support)
    @test features.composite && !isnothing(features.subject)
    @test Set(pigment for (role,pigment) in features.colors if role == features.subject) == Set([4,8])
    @test !((features.subject,features.subject) in features.neighbor)
    @test length(TC.color_components(frame).groups) == 5
    @test length(unique(first.(features.colors))) == 4
    context = TC.observed_relation_context(frame,positive.binding,positive.sample.before_id)
    counts = TC.observed_neighbor_counts(context,4)
    @test counts[3] == 2 && counts[5] == counts[9] == 0
    @test context.context.scope.view != "color-support"

    predicate = TC.construct_relation([negative,positive])
    @test !isnothing(predicate)
    @test all(candidate["neighbor_count"] == 2 && candidate["pigment"] == 2
        for candidate in predicate.certificate["candidates"])
    held = witness(12,15,2,"compound-held",TC.proven)
    @test TC.evaluate_predicate(predicate,held.sample.before,held.binding,(0,0),[0]) == TC.proven
    @test TC.evaluate_predicate(predicate,negative.sample.before,negative.binding,(0,0),[0]) == TC.disproven
    cut = TC.MotionBinding(support[1:end-1],positive.binding.anchor)
    @test isnothing(TC.support_features(frame,cut.support).subject)
    @test TC.evaluate_predicate(predicate,frame,cut,(0,0),[0]) == TC.unknown_truth
end

@testset "A learned joint condition binds pigments to the same observed role" begin
    base = zeros(UInt8,28,28)
    base[10:12,10:12] .= 4
    red,blue = copy(base),copy(base)
    red[11,9] = 2
    blue[11,13] = 3
    together = copy(red)
    together[11,13] = 3
    function example(frame,name,verdict)
        support = TC.point_component(TC.public_components(frame),(10,10))
        sample = TC.MotionExample(name,"before-" * name,1,frame,frame,[0])
        return TC.AssociationExample(sample,TC.MotionBinding(support,TC.anchor(support)),verdict)
    end
    positive = example(together,"together",TC.proven)
    negative = [example(red,"red",TC.disproven),example(blue,"blue",TC.disproven)]
    predicate = TC.construct_relation([positive;negative])
    @test !isnothing(predicate)
    @test all(row["pigments"] == [2,3] for row in predicate.certificate["candidates"])
    withheld = copy(base)
    withheld[9,11] = 2
    withheld[13,11] = 3
    binding = example(withheld,"held-out",TC.proven).binding
    @test TC.evaluate_predicate(predicate,withheld,binding,(0,0),[0]) == TC.proven
    elsewhere = copy(red)
    elsewhere[20:22,20:22] .= 4
    elsewhere[19,21] = 3
    binding = example(elsewhere,"different-role",TC.disproven).binding
    @test TC.evaluate_predicate(predicate,elsewhere,binding,(0,0),[0]) == TC.disproven
end

@testset "Runtime backend capabilities restrict dispatch" begin
    config = load_run_config(joinpath(ROOT,"config","v13_public25.toml"))
    TC.with_compute(config) do workers
        factor = workers["factor_kernel"]
        @test factor.capabilities["numeric"] == "exact_rational"
        count = factor.request_id
        @test TC.compute_request!(factor,"scope","query_circuit").execution == "unsupported"
        @test factor.request_id == count
        @test workers["circuit_python"].capabilities["cirkit"]["version"] == "0.3.1"
        @test "synthesize_guard" in workers["policy_synthesis"].capabilities["operations"]
    end
end

@testset "Author ATDD finite Boolean execution" begin
    with_worker(joinpath(ROOT,"target/release/factor-kernel")) do worker
        request(op,payload=nothing) = TC.compute_request!(worker,"finite-domain",op,payload)
        value(op,payload=nothing) = TC.require_compute_value(request(op,payload))
        @test value("capabilities")["backend"] == "atddc"
        encoding = TC.finite_encoding((0:2,0:4))
        domain = TC.require_compute_value(TC.factor_compile!(worker,"finite-domain",encoding,TC.legal_factor_domain(encoding)))
        @test value("count_models",(;value=domain)) == "15"
        example = TC.require_compute_value(TC.factor_compile!(worker,"finite-domain",encoding,
            TC.factor_rows(encoding,[(0,0),(2,4),(2,3)])))
        @test value("count_models",(;value=example)) == "3"
        complement = value("negate_bool",(;value=example,domain))
        @test value("count_models",(;value=complement)) == "12"
        projected = value("project_bool",(;value=example,bits=collect(encoding.bits[2])))
        scalar = value("project_bool",(;value=projected,bits=collect(encoding.bits[1])))
        @test value("count_models",(;value=projected)) == "2"
        @test value("evaluate_bool",(;value=scalar,assignment=[])) === true
        @test value("entails_bool",(;left=example,right=domain))["entailed"] === true
        witness = value("entails_bool",(;left=domain,right=example))["counterexample"]
        @test value("evaluate_bool",(;value=domain,assignment=witness)) === true
        @test value("evaluate_bool",(;value=example,assignment=witness)) === false

        artifact = value("export_canonical",(;value=example))
        restored = value("import_canonical",(;artifact))
        @test value("equal_bool",(;left=restored,right=example)) === true
        lease = value("acquire",(;value=example,lease_id="reader"))
        @test value("acquire",(;value=example,lease_id="reader")) == lease
        @test value("release",(;value=example)) && value("release",(;value=example))
        @test request("count_models",(;value=example)).execution == "invalidated"
        @test value("count_models",(;value=lease)) == "3"

        image = fill(UInt8(0),64,64)
        image[8:15,21:30] .= UInt8(5)
        image[40:51,3:60] .= UInt8(11)
        frame = TC.finite_encoding((0:63,0:63,0:15))
        formula = TC.factor_frame_formula(image,frame)
        compiled = TC.require_compute_value(TC.factor_compile!(worker,"finite-domain",frame,formula))
        @test value("count_models",(;value=compiled)) == "4096"
        rows = [(x,y,color) for x in 0:63 for y in 0:63 for color in 0:15]
        correct = true
        for batch in Iterators.partition(rows,512)
            assignments = [TC.encode_factor_row(frame,row) for row in batch]
            actual = value("evaluate_bool_batch",(;value=compiled,assignments))
            expected = [image[y+1,x+1] == color for (x,y,color) in batch]
            correct &= actual == expected
        end
        @test correct

        tree = TC.finite_encoding((0:7,);style="right_linear")
        diagram = TC.require_compute_value(TC.factor_compile!(worker,"finite-domain",tree,
            TC.factor_rows(tree,[(0,),(4,),(7,)])))
        # Arena construction is post-order, so an n=3 right-linear root is 4.
        rotated = value("rotate_bool",(;value=diagram,node=4,left=true))
        @test request("equal_bool",(;left=rotated,right=diagram)).execution == "unsupported"
        assignments = [TC.encode_factor_row(tree,(row,)) for row in 0:7]
        @test value("evaluate_bool_batch",(;value=rotated,assignments)) ==
            value("evaluate_bool_batch",(;value=diagram,assignments))

        memo = Dict{Tuple,NamedTuple}()
        function role_proof(x,y,color,ref)
            board = zeros(UInt8,64,64)
            board[y+1,x+1] = color
            fragments = [(family=:pigment,basis=TC.ColorCell[(x,y,4)])]
            proposal = (;tests=[(;scope=:bound,fragments)])
            return TC.role_factor_proof!(worker,proposal,(frames=[board],),ref;memo)
        end
        first = role_proof(5,12,4,"role-1")
        issued = worker.request_id
        second = role_proof(18,24,4,"role-2")
        @test !first.reused && second.reused && second.receipt == "role-2"
        @test second.origin == (18,24) && second.value["entailed"] === true
        @test second.proved_at == "role-1" && second.proof_origin == (5,12)
        @test worker.request_id == issued
        refuted = role_proof(18,24,3,"role-3")
        @test !refuted.reused && refuted.value["entailed"] === false
        @test worker.request_id > issued
    end
end

@testset "cvc5 verified constraints" begin
    with_worker(joinpath(ROOT,"python/compute/.venv/bin/python"),"-m","tddesc_compute.worker") do worker
        first = TC.compute_request!(worker,"resource","capabilities")
        @test first.value["backend"] == "cvc5"
        var = TC.constraint_variable("v")
        constant = TC.constraint_value
        term = TC.constraint_term
        variables = Dict("v"=>"Int")
        domain = term("and",term("ge",var,constant(0)),term("le",var,constant(8)))
        @test TC.constraint_implication!(worker,"resource",variables,domain,
            term("eq",var,constant(4)),term("lt",var,constant(5))).status == :proven
        refuted = TC.constraint_implication!(worker,"resource",variables,domain,
            term("ge",var,constant(4)),term("lt",var,constant(5)))
        @test refuted.status == :refuted
        @test parse(Int,refuted.counterexample.value["model"]["v"]) >= 5
        empty = TC.constraint_implication!(worker,"resource",variables,domain,
            term("eq",var,constant(10)),term("lt",var,constant(5)))
        @test empty.status == :empty_premise
    end
end
