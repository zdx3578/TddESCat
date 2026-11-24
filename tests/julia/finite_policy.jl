using Test
using TddESCat

const TC = TddESCat

@testset "Exact relation algebra and execution domain" begin
    domain = Set(0:3)
    relation = TC.finite_relation(domain,domain,[(0,1,["r01"]),(0,2,["r02"]),(1,3,["r13"])])
    subsets = [Set(i for i in domain if (n & (1 << i)) != 0) for n in 0:15]
    @test all((TC.post_image(relation,p) ⊆ q) == (p ⊆ TC.liberal_precondition(relation,q))
        for p in subsets, q in subsets)
    @test TC.liberal_precondition(relation,Set([3])) == Set([1,2,3])
    @test TC.safe_precondition(relation,Set([3]),Set([0,1,2]),Set([0,1,2]),domain) == Set([1])
    successor = TC.compose_relations(relation,relation;max_work=50)
    @test successor.complete
    @test successor.relation.evidence == Dict((0,3)=>Set(["r01","r13"]))
    @test successor.witnesses[(0,3)] == Set([1])
    right = TC.finite_relation(domain,domain,[(1,3,["r13"]),(2,3,["r23"])])
    full = TC.compose_relations(relation,right;max_work=20)
    @test full.witnesses[(0,3)] == Set([1,2])
    @test full.relation.evidence[(0,3)] == Set(["r01","r02","r13","r23"])
    cut = TC.compose_relations(relation,right;max_work=1)
    @test !cut.complete && cut.stop_reason == "work_limit"
    @test isempty(TC.safe_precondition(cut.relation,Set([3]),domain,domain,domain))
end

function scope(states;known=true,complete=true,refs=["rule"])
    return TC.SuccessorScope(Set{Int}(states),known ? TC.proven : TC.unknown_truth,complete,Set(refs))
end

@testset "Identical public observations cannot split a belief" begin
    states = Set(0:3)
    enabled = Dict(0=>Set([1]),1=>Set([2]),2=>Set([3]),3=>Set{Int}())
    effects = Dict((0,1)=>scope([1,2]),(1,2)=>scope([3]),(2,3)=>scope([3]))
    shared = Dict(0=>Set(["start"]),1=>Set(["same"]),2=>Set(["same"]),3=>Set(["finished"]))
    known = Dict("rule"=>"v1")
    model = TC.PlanningModel(states,enabled,effects,shared,known)
    @test TC.solve_policy(model,Set([0]),Set([3]);depth=2,max_work=10).policy === nothing
    distinct = merge(shared,Dict(1=>Set(["left"]),2=>Set(["right"])))
    model = TC.PlanningModel(states,enabled,effects,distinct,known)
    result = TC.solve_policy(model,Set([0]),Set([3]);depth=2,max_work=10)
    @test result.status == "policy"
    @test result.policy.action == 1
    @test result.policy.branches["left"].action == 2
    @test result.policy.branches["right"].action == 3
    @test TC.revalidate_policy(model,result.policy,Set([0])) == "ready"
    @test TC.continue_policy(model,result.policy,"left",Set([1])).policy.action == 2
    @test TC.continue_policy(model,result.policy,"same",Set([1])).policy === nothing
    @test TC.solve_policy(model,Set{Int}(),Set([3]);depth=2,max_work=10).status == "belief_needs_revision"
    @test TC.solve_policy(model,Set([0]),Set([3]);depth=2,max_work=1).policy === nothing
    effects2 = merge(effects,Dict((0,1)=>scope([1];complete=false)))
    limited = TC.PlanningModel(states,enabled,effects2,distinct,known)
    @test TC.solve_policy(limited,Set([0]),Set([3]);depth=2,max_work=10).policy === nothing
    effects3 = merge(effects,Dict((0,1)=>scope(Int[])))
    empty = TC.PlanningModel(states,enabled,effects3,distinct,known)
    @test TC.solve_policy(empty,Set([0]),Set([3]);depth=2,max_work=10).policy === nothing
    revised = TC.PlanningModel(states,enabled,effects,distinct,Dict("rule"=>"v2"))
    @test TC.revalidate_policy(revised,result.policy,Set([0])) == "dependency_changed"
    prevented = TC.PlanningModel(states,merge(enabled,Dict(1=>Set{Int}())),effects,distinct,known)
    @test TC.continue_policy(prevented,result.policy,"left",Set([1])).status == "action_unavailable"
end

@testset "Resource order and transitive invalidation" begin
    # One consumable is shared by two alternatives. Only doing action 2 while
    # still at state 0 establishes the required order.
    states = Set(0:4)
    enabled = Dict(0=>Set([1,2]),1=>Set([2]),2=>Set([1]),3=>Set{Int}(),4=>Set{Int}())
    effects = Dict((0,1)=>scope([1]),(0,2)=>scope([2]),(1,2)=>scope([4]),(2,1)=>scope([3]))
    observed = Dict(i=>Set([string(i)]) for i in states)
    model = TC.PlanningModel(states,enabled,effects,observed,Dict("rule"=>"v1"))
    result = TC.solve_policy(model,Set([0]),Set([3]);depth=2,max_work=20)
    @test result.policy.action == 2
    @test result.policy.branches["2"].action == 1
    index = TC.DependencyIndex()
    TC.track_reads!(index,"relation",["role"])
    TC.track_reads!(index,"negative-match-cache",["relation"])
    TC.track_reads!(index,"mechanism",["relation","resource"])
    TC.track_reads!(index,"unexecuted-action",["mechanism","negative-match-cache"])
    @test Set(TC.invalidate_dependents!(index,["role"])) ==
        Set(["role","relation","negative-match-cache","mechanism","unexecuted-action"])
    @test "resource" ∉ index.invalid
end

@testset "Strong strategy reaches beyond the former short horizon" begin
    finish = 24
    states = Set(0:finish)
    actions = Dict(i=>Set([1,2]) for i in 0:finish-1)
    effects = Dict((i,action)=>scope([action == 1 ? i+1 : i])
        for i in 0:finish-1 for action in (1,2))
    observed = Dict(i=>Set([string(i)]) for i in 0:finish)
    model = TC.PlanningModel(states,actions,effects,observed,Dict("rule"=>"v1"))
    result = TC.solve_policy(model,Set([0]),Set([finish]))
    @test result.status == "policy" && result.rank == finish
    node = result.policy
    for index in 1:finish
        @test node.action == 1
        node = node.branches[string(index)]
    end
    @test isnothing(node.action)
    broken = TC.PlanningModel(states,actions,merge(effects,Dict((15,1)=>scope([16];complete=false))),
        observed,model.versions)
    @test TC.solve_policy(broken,Set([0]),Set([finish])).status == "incomplete"
end

@testset "Sufficient queries and bounded partition refinement" begin
    partition = Dict(0=>"same",1=>"same",2=>"open",3=>"uncertain")
    resource = Dict(0=>0,1=>1,2=>1)
    failed = TC.factor_query(partition,resource;max_work=4)
    @test failed.complete && !failed.sufficient
    @test failed.disagreements["same"] == (left=0,right=1,left_value=0,right_value=1)
    @test "uncertain" in failed.unresolved
    @test !TC.factor_query(partition,resource;max_work=1).complete

    states = Set(0:5)
    evidence = Dict("rule"=>"v1")
    enabled = Dict(0=>Set([1]),1=>Set([1]))
    effects = Dict((0,1)=>scope([2,3]),(1,1)=>scope([4,5]))
    observations = Dict(2=>Set(["left"]),3=>Set(["right"]),4=>Set(["right"]),5=>Set(["left"]))
    model = TC.PlanningModel(states,enabled,effects,observations,evidence)
    values = Dict(0=>:source,1=>:source,2=>:a,3=>:b,4=>:a,5=>:b)
    initial = Dict(state=>0 for state in states)
    refined = TC.refine_partition(model,initial,[values];max_work=20)
    @test refined.complete && refined.partition[0] != refined.partition[1]
    @test refined.partition[2] == refined.partition[4]
    @test TC.factor_query(refined.partition,values;max_work=6).sufficient
    @test TC.refine_partition(model,initial,[values];max_work=1).reason == "work_limit"

    concrete = TC.finite_relation(states,states,[(0,2,["a"]),(1,3,["b"])])
    merged = Dict(0=>0,1=>0,2=>1,3=>2,4=>2,5=>2)
    abstracted = TC.finite_relation(Set(values for values in Base.values(merged)),Set(0:2),
        [(0,1,["a"]),(0,2,["b"])])
    @test TC.check_causal_square(concrete,abstracted,merged,Set([0])) == TC.disproven
    mismatch = TC.causal_square_witness(concrete,abstracted,merged,Set([0,1]))
    @test mismatch.truth == TC.disproven
    @test mismatch.witness.state == 0
    @test mismatch.witness.low == Set([1]) && mismatch.witness.high == Set([1,2])
    isolated = TC.finite_relation(Set(0:5),Set(0:5),[(0,2,["a"]),(1,3,["b"])])
    @test TC.check_causal_square(concrete,isolated,Dict(i=>i for i in 0:5),Set([0,1])) == TC.proven
    incomplete = TC.finite_relation(Set(0:2),Set(0:2),[];complete=false)
    @test TC.check_causal_square(concrete,incomplete,merged,Set([0,1])) == TC.unknown_truth
end

@testset "Active experiments separate observable predictions" begin
    map = [Dict("gate"=>true, "camera"=>nothing), Dict("gate"=>false, "camera"=>1),
        Dict("gate"=>false, "camera"=>2)]
    separated = TC.distinguish_predictions(map;max_work=12)
    @test separated.complete && separated.separated == 3
    @test [row.query for row in separated.witnesses] == ["gate","gate","camera"]
    @test !TC.distinguish_predictions(map;max_work=2).complete
    @test TC.distinguish_predictions([Dict("brief"=>nothing),Dict("brief"=>false)];max_work=4).separated == 0
end

@testset "Competing projected observations block a deterministic suffix" begin
    before = zeros(UInt8,4,5)
    before[2,2] = 9
    part = (family=:translation,basis=TC.MotionShape([(1,1,0x09)]),value=(1,1),expected=(1,0))
    scope = TC.plan_channels([part])
    effect = TC.EffectModel(:translation,[(0,0,0x09)],nothing,[1,0],TC.MotionShape(),false)
    premise = TC.GuardSearch(TC.MotionPredicate[],["e1"],String[],String[],true,true,1)
    function record(label, underlay)
        patch = TC.FramePatch(size(before),[(0,0,0x09,underlay),(1,0,0x00,0x09)],TC.PixelChange[])
        rule = TC.JointMechanism(label,1,[effect],["def"],"e1",[(1,1)],[(0,0)],UInt8[0],nothing,patch)
        return (model=TC.ActiveMechanism(rule,premise,String[],String[]),fragments=[part],expected=scope)
    end
    first, second = record("one",0x00),record("two",0x01)
    @test !isnothing(TC.project_frame(first,before))
    @test !isnothing(TC.project_frame(second,before))
    result = TC.compatible_frame_projection([first,second],scope,before)
    @test result.conflict && isnothing(result.frame) && isnothing(result.choice)
end
