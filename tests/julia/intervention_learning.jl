using Test, TddESCat

const TC = TddESCat

@testset "Coordinate alternatives remain complete and spatially spread" begin
    points = TC.spatial_probe_point.(0:4095)
    @test length(Set(points)) == 4096
    @test Set(points[1:4]) == Set([(0,0),(0,32),(32,0),(32,32)])
    memory = TC.InterventionMemory()
    push!(memory.points,(0,(0,0)))
    @test TC.coordinate_intervention(memory,0,[6]) == ((0,32),1)
    @test TC.coordinate_intervention(memory,1,[6]) == ((0,0),0)
end

@testset "Click effects follow a witnessed object and exact relative point" begin
    before = fill(UInt8(2),64,64)
    before[11:13,11:13] .= UInt8(4)
    before[32:34,32:34] .= UInt8(4)
    groups = TC.public_components(before)
    source = TC.point_component(groups,(11,11))
    transformed = TC.MotionShape([(x,y,7) for (x,y,_) in source])
    expected = copy(before)
    expected[11:13,11:13] .= UInt8(7)
    change = TC.LocalEffect(:pigment,source,transformed,[4,7],sort!(collect(TC.effect_points(source))),(;))
    scope = TC.ClickBinding(source,(11,11),true)
    patch = TC.frame_patch((complete=true,residual=[],public_delta=Dict(),effects=[change]),
        before,expected,TC.Pixel[];click=scope)
    pigment = TC.EffectModel(:pigment,TC.shape_template(source),TC.anchor(source),[4,7],TC.MotionShape(),false)
    rule = TC.JointMechanism("role-pigment",6,[pigment],String[],"training-feedback",
        TC.Pixel[],TC.Pixel[],UInt8[],nothing,patch,scope)
    matches = TC.evaluate_joint_rule(rule,before,groups,[],TC.click_action((32,32)))
    @test matches.truth == TC.proven
    @test TC.anchor(only(matches.fragments).basis) == (31,31)
    @test TC.evaluate_joint_rule(rule,before,groups,[],TC.click_action((31,31))).truth == TC.unknown_truth
    @test TC.evaluate_joint_rule(rule,before,groups,[],TC.click_action((50,50))).truth == TC.unknown_truth
    guard = TC.GuardSearch(TC.MotionPredicate[],["training-feedback"],String[],String[],true,true,1)
    active = TC.ActiveMechanism(rule,guard,String[],String[])
    projection = TC.projected_contract(TC.ProjectionMemory(),(model=active,fragments=matches.fragments),before,[0])
    rebound = copy(before)
    rebound[32:34,32:34] .= UInt8(7)
    @test projection.origin == (31,31)
    @test projection.frame == rebound
end
