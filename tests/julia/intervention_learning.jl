using Test, TddESCat

const TC = TddESCat

function intervention_entry(ref,action,frame,available;before="")
    observation = TC.PublicObservation("abstract-trial","test-session",[frame],"NOT_FINISHED",
        0,2,action,available,false)
    return (;event=Dict("event_id"=>ref,"before_ref"=>before),observation)
end

@testset "Frame role postings keep coordinates, counts and ambiguous bindings" begin
    frame = fill(UInt8(0),64,64)
    frame[11:13,11:13] .= 4
    frame[32:34,32:34] .= 4
    groups = TC.public_components(frame)
    candidates = filter(shape->first(shape)[3] == 4,groups)
    source = TC.point_component(groups,(11,11))
    model = TC.EffectModel(:translation,TC.shape_template(source),nothing,[3,0],TC.MotionShape(),false)
    roles = TC.EffectRoleIndex()
    @test TC.model_binding(model,groups,[];role_index=roles) === nothing
    @test TC.model_binding(model,groups,[];position=(10,10),role_index=roles) == source
    @test TC.model_binding(model,groups,[];role_index=roles) === nothing
    @test TC.result_model(model,frame,groups,[],Dict("id"=>1);position=(31,31),role_index=roles) ==
        TC.result_model(model,frame,groups,[],Dict("id"=>1);position=(31,31))

    count = TC.EffectModel(:count,TC.shape_template(source),nothing,[1],TC.ColorCell[(10,10,4)],false)
    measured = TC.result_model(count,frame,groups,[],Dict("id"=>1);role_index=roles)
    @test measured == TC.result_model(count,frame,groups,[],Dict("id"=>1))
    @test measured.value == 2 && measured.expected == 3
    @test measured.token_support == sort!(vcat(candidates...))
    @test TC.result_model(count,frame,groups,[],Dict("id"=>1);shift=(0,3),role_index=roles) === nothing
end

@testset "Relative placement binds jointly moving supports with a duplicate" begin
    function scene(motion=0; origin=(4,4), unit=2)
        frame = zeros(UInt8,64,64)
        for (x,y,color) in ((origin[1]+motion,origin[2],0x04),
                (origin[1]+3unit+motion,origin[2],0x08),(24,24,0x04))
            frame[y+1:y+unit,x+1:x+unit] .= color
        end
        return frame
    end
    action = Dict("id"=>2)
    before, after = scene(), scene(2)
    initial = intervention_entry("base",Dict("id"=>0),before,[2])
    next = intervention_entry("moved",action,after,[2];before="base")
    effects = TC.observed_effects(initial,next)
    agenda = TC.RelationAgenda()
    learned = TC.observe_relations!(agenda,initial,next,effects,nothing,NamedTuple[],nothing)
    rule = agenda.producers[learned.producer.key].rule
    groups = TC.public_components(before)
    @test isnothing(TC.model_binding(first(rule.effects),groups,[]))
    admitted = TC.evaluate_joint_rule(rule,before,groups,[],action;role_index=TC.EffectRoleIndex())
    @test admitted == TC.evaluate_joint_rule(rule,before,groups,[],action)
    @test admitted.truth == TC.proven
    @test [part.value for part in admitted.fragments] == rule.anchors
    @test all(part->part.relative,admitted.fragments)
    choice = (model=rule,fragments=admitted.fragments)
    @test all(==("supported"),values(TC.measure_joint(choice,after;effects).assessments))
    @test all(==("refuted"),values(TC.measure_joint(choice,before).assessments))

    projection = (model=(;rule,condition=(complete=true,)),fragments=admitted.fragments)
    predicted = TC.project_frame(projection,before)
    @test predicted == after
    outputs = TC.projected_program_ports(projection,predicted)
    @test outputs == [effect.after for effect in effects.effects]
    @test isnothing(TC.projected_program_ports(projection,before))
    step = Dict{String,Any}("action"=>action,"effects"=>TC.effect_record.(effects.effects))
    program = TC.LearnedProgram("publication","move-pair",1,["moved"],[step,step],
        [[(0,0),(1,1)]],nothing)
    cursor = TC.ProgramCursor(program,2,outputs)
    following = TC.evaluate_joint_rule(rule,predicted,TC.public_components(predicted),[],action)
    decision = (ranked=[(;action,chosen=merge(projection,(;fragments=following.fragments)))],)
    @test TC.current_program_step(cursor,decision).action == action
    @test cursor.next_step == 2 && cursor.outputs == outputs

    TC.begin_relation_attempt!(agenda,nothing;observation=initial.observation)
    seen = TC.prepare_relation_tests(agenda,TC.relation_context(initial.observation),initial.observation,groups,action)
    @test only(seen).scope == :bound
    before_view, after_view = TC.frame_regions(before), TC.frame_regions(after)
    @test TC.measure_joint(choice,after;effects,groups=after_view.groups) ==
        TC.measure_joint(choice,after;effects)
    contract = (intent=:apply_relation,tests=seen)
    @test TC.relation_checks(contract,after,effects;groups=after_view.groups) ==
        TC.relation_checks(contract,after,effects)
    reused = TC.observe_relations!(TC.RelationAgenda(),initial,next,effects,nothing,NamedTuple[],nothing;
        groups=before_view.groups,after_groups=after_view.groups)
    @test reused.producer == learned.producer
    elsewhere = scene(;origin=(13,17),unit=3)
    other = intervention_entry("other",Dict("id"=>0),elsewhere,[2])
    other_groups = TC.public_components(elsewhere)
    comparison = only(TC.prepare_relation_tests(agenda,TC.relation_context(other.observation),
        other.observation,other_groups,action))
    @test comparison.scope == :unverified
    @test [part.value for part in comparison.fragments] == [(13,17),(22,17)]
    @test all(part->part.expected == (3,0),comparison.fragments)

    rival = copy(before)
    rival[25:26,31:32] .= 0x08
    @test TC.evaluate_joint_rule(rule,rival,TC.public_components(rival),[],action).truth == TC.unknown_truth
end

@testset "An intermediate frame witnesses a split and a merge within one receipt" begin
    merged = fill(UInt8(0),5,7)
    merged[3,2:6] .= 4
    split = copy(merged)
    split[3,4] = 0
    event(ref,parent,frames) = (event=Dict("event_id"=>ref,"before_ref"=>parent,
        "frame_count"=>length(frames),"completion"=>"confirmed"),observation=(;frames))
    initial = event("base",nothing,[merged])
    view = TC.receipt_regions(initial)
    next = event("transition","base",[split,merged,merged])
    region = TC.receipt_regions(next;previous=initial,previous_regions=view)
    @test region.differences == [1,1,0]
    @test region.frames[2] === region.frames[3]
    cutting = only(region.topology[1].splits)
    @test cutting.before == view.frames[1].owner[3,4]
    @test Dict(cutting.after) == Dict(region.frames[1].owner[3,2]=>2,region.frames[1].owner[3,6]=>2)
    @test cutting.lost == 1
    joining = only(region.topology[2].merges)
    @test joining.after == region.frames[2].owner[3,4]
    @test joining.gained == 1 && joining.before == cutting.after
    @test isnothing(region.topology[3])
    reframe = TC.receipt_regions(event("small","transition",[merged[1:4,:]]);
        previous=next,previous_regions=region)
    @test only(reframe.topology).status == "incompatible_frame_domains"
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
    agenda = TC.RelationAgenda()
    next = intervention_entry("first",Dict("id"=>0),image,[6])
    for (ordinal,x) in enumerate((5,20))
        scene = TC.intervention_scene(image,TC.public_components(image))
        action = TC.click_action((x+1,11))
        choice = TC.executed_intervention(nothing,scene,action)
        @test choice.probe == :representative
        painted = copy(image)
        painted[11:13,x+1:x+3] .= 0x04
        before = next
        next = intervention_entry("confirmed-$ordinal",action,painted,[6];before=before.event["event_id"])
        effects = TC.observed_effects(before,next)
        TC.observe_intervention!(memory,choice,before,next,effects;ordinal)
        TC.observe_relations!(agenda,before,next,effects,nothing,NamedTuple[],nothing)
        image = painted
    end
    scene = TC.intervention_scene(image,TC.public_components(image))
    choice = TC.choose_intervention(memory,scene,next.observation,[],Dict{String,Int}();
        explore=true,goal_learning=true,confirmed_count=2,agenda)
    @test choice.action == TC.click_action((31,11))
    @test choice.reason == "extend_observed_object_effect"
    tests = TC.prepare_relation_tests(agenda,TC.relation_context(next.observation),
        next.observation,TC.public_components(image),choice.action)
    @test Set(only(tests).reads) == Set(["first","confirmed-1","confirmed-2"])
    @test only(tests).scope == :replicated && only(only(tests).rule.effects).family == :pigment
    condition = TC.GuardSearch(TC.MotionPredicate[TC.RecentAction(7)],["confirmed-2"],
        ["confirmed-1"],String[],true,true,1)
    rule = only(tests).rule
    active = TC.ActiveMechanism(rule,condition,["confirmed-1"],String[])
    view = (models=Dict(TC.relation_condition_key(rule)=>[active]),history=[7],
        transients=nothing,reads=(_ -> ["revision-source"]))
    context = TC.relation_context(next.observation)
    groups = TC.public_components(image)
    admitted = TC.prepare_relation_tests(agenda,context,next.observation,groups,choice.action;condition_view=view)
    @test only(only(admitted).conditions).version == TC.active_id(active)
    @test "revision-source" in only(admitted).reads
    withdrawn = merge(view,(history=[5],))
    @test isempty(TC.prepare_relation_tests(agenda,context,next.observation,groups,choice.action;condition_view=withdrawn))
    refused = TC.choose_intervention(memory,scene,next.observation,[],Dict{String,Int}();
        explore=true,goal_learning=true,confirmed_count=2,agenda,groups,condition_view=withdrawn)
    @test refused.probe == :representative && refused.reason == "probe_visible_object"
    @test !hasproperty(refused,:tests)
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
    regions = TC.frame_regions(before)
    signatures = IdDict{Vector{TC.ColorCell},NamedTuple}()
    trained = TC.click_role_signature(TC.click_support_signature(source),scope.point)
    for point in ((11,11),(32,32),(31,31),(50,50),(51,51),(-1,11))
        action = TC.click_action(point)
        role = TC.role_at_click(groups,point,regions,signatures)
        @test role == TC.role_at_click(groups,point)
        @test TC.evaluate_joint_rule(rule,before,groups,[],action;observed_click=role,trained_click=trained) ==
            TC.evaluate_joint_rule(rule,before,groups,[],action)
    end
    @test length(signatures) == 3
    guard = TC.GuardSearch(TC.MotionPredicate[],["training-feedback"],String[],String[],true,true,1)
    active = TC.ActiveMechanism(rule,guard,String[],String[])
    projection = TC.projected_contract(TC.ProjectionMemory(),(model=active,fragments=matches.fragments),before,[0])
    rebound = copy(before)
    rebound[32:34,32:34] .= UInt8(7)
    @test projection.origin == (31,31)
    @test projection.frame == rebound
end
