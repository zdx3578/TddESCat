using Test, TddESCat

const TC = TddESCat

function intervention_entry(ref,action,frame,available)
    observation = TC.PublicObservation("abstract-trial","test-session",[frame],"NOT_FINISHED",
        0,2,action,available,false)
    return (;event=Dict("event_id"=>ref),observation)
end

@testset "Coordinate alternatives remain complete and spatially spread" begin
    points = TC.spatial_probe_point.(0:4095)
    @test length(Set(points)) == 4096
    @test Set(points[1:4]) == Set([(0,0),(0,32),(32,0),(32,32)])
    memory = TC.InterventionMemory()
    push!(memory.points,(0,(0,0)))
    @test TC.coordinate_intervention(memory,0,[6]) == ((0,32),1)
    @test TC.coordinate_intervention(memory,1,[6]) == ((0,0),0)
end

@testset "Repetitive primitive feedback leaves room for continuing experiments" begin
    base = fill(UInt8(0),64,64)
    base[13:14,13:14] .= 0x08
    changed = fill(UInt8(0),64,64)
    changed[13:14,15:16] .= 0x08
    restored = copy(base)
    restored[1,1] = 0x03
    for id in (4,7)
        available = [id,6]
        initial = intervention_entry("initial",Dict("id"=>0),base,available)
        primitive = Dict("id"=>id)
        still = intervention_entry("still",primitive,base,available)
        ranked = [(action=primitive,rank=(1,0))]
        schedule = TC.InterventionMemory()
        source = TC.intervention_scene(base,TC.public_components(base))
        counts = Dict{String,Int}()
        choose(obs,scene,confirmed_count) = TC.choose_intervention(schedule,scene,obs,ranked,counts;
            explore=true,goal_learning=false,confirmed_count)
        effects = (effects=TC.LocalEffect[],)
        first_trial = choose(initial.observation,source,0)
        @test first_trial.probe == :primitive
        first_check = TC.observe_intervention!(schedule,first_trial,initial,still,effects;ordinal=1)
        @test first_check.schedule.outcome == :unchanged
        @test choose(still.observation,source,2).probe == :representative

        clicked = choose(still.observation,source,2)
        moved = intervention_entry("moved",clicked.action,changed,available)
        TC.observe_intervention!(schedule,clicked,still,moved,effects;ordinal=9)
        rebound = TC.intervention_scene(changed,TC.public_components(changed))
        retry = choose(moved.observation,rebound,10)
        @test retry.probe == :primitive
        echoed = intervention_entry("echoed",primitive,restored,available)
        check = TC.observe_intervention!(schedule,retry,moved,echoed,effects;ordinal=11)
        @test check.schedule.outcome == :revisited && check.schedule.earlier == "still"
        current = TC.intervention_scene(restored,TC.public_components(restored))
        @test choose(echoed.observation,current,12).probe != :primitive
        next_trial = choose(echoed.observation,current,isodd(check.schedule.eligible_at) ?
            check.schedule.eligible_at+1 : check.schedule.eligible_at)
        @test next_trial.probe == :primitive
    end
end

@testset "Replicated object effects guide the next experiment before any advancement" begin
    image = fill(UInt8(0),64,64)
    for x in (5,20,30,50)
        image[11:13,x+1:x+3] .= 0x08
    end
    image[4,4] = 0x02
    memory = TC.InterventionMemory()
    next = intervention_entry("first",Dict("id"=>0),image,[6])
    for (ordinal,x) in enumerate((5,20))
        scene = TC.intervention_scene(image,TC.public_components(image))
        action = TC.click_action((x+1,11))
        choice = TC.executed_intervention(nothing,scene,action)
        @test choice.probe == :representative
        painted = copy(image)
        painted[11:13,x+1:x+3] .= 0x04
        before = next
        next = intervention_entry("confirmed-$ordinal",action,painted,[6])
        support = choice.candidate.support
        after_support = TC.MotionShape([(u,v,0x04) for (u,v,_) in support])
        pixels = sort!(collect(TC.effect_points(support)))
        change = TC.LocalEffect(:pigment,support,after_support,[8,4],pixels,(;))
        TC.observe_intervention!(memory,choice,before,next,(effects=[change],);ordinal)
        image = painted
        if ordinal == 1
            remaining = TC.intervention_scene(image,TC.public_components(image))
            @test isnothing(TC.object_effect_followup(memory,0,remaining))
        end
    end
    scene = TC.intervention_scene(image,TC.public_components(image))
    choice = TC.choose_intervention(memory,scene,next.observation,[],Dict{String,Int}();
        explore=true,goal_learning=true,confirmed_count=2)
    @test choice.action == TC.click_action((31,11))
    @test choice.reason == "extend_observed_object_effect"
    @test Set(choice.hypothesis.reads) == Set(["first","confirmed-1","confirmed-2"])
    @test choice.hypothesis.effects == [:pigment] && isnothing(choice.goal)
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
