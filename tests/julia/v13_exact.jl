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
