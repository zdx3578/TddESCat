using Test
using TddESCat

const TC = TddESCat

@testset "Three-valued guard repair preserves counterexamples" begin
    ids = ["s1", "s2", "b1", "b2"]
    p, q = TC.RecentAction(1), TC.RecentAction(2)
    results = Dict(
        1 => [TC.proven, TC.proven, TC.disproven, TC.unknown_truth],
        2 => [TC.proven, TC.proven, TC.unknown_truth, TC.disproven],
    )
    evaluate = (atom, index) -> results[atom.id][index]
    combined = TC.search_guards(ids, [1, 2], [3, 4], [p, q], evaluate)
    @test combined.feasible
    @test length(combined.atoms) == 2
    @test combined.support == ids[1:2]
    @test combined.excluded == ids[3:4]
    @test combined.complete
    limited = TC.search_guards(ids, [1, 2], [3, 4], [p, q], evaluate; max_work=1)
    @test !limited.feasible && !limited.complete
    results[2][4] = TC.unknown_truth
    unresolved = TC.search_guards(ids, [1, 2], [3, 4], [p, q], evaluate)
    @test !unresolved.feasible && unresolved.unresolved == ids[3:4]
end

@testset "Whole support and actual read boundaries" begin
    frame = fill(UInt8(0), 14, 14)
    frame[6:7, 4:5] .= 2
    support = TC.support_candidates(frame)
    shape = only(filter(shape -> length(shape) == 4, support))
    template = TC.shape_template(shape)
    binding = TC.bind_motion(frame, template)
    @test TC.evaluate_predicate(TC.DestinationColor(0x00), frame, binding, (1, 0), [0]) == TC.proven
    frame[7, 6] = 3
    @test frame[6, 6] == 0
    @test TC.evaluate_predicate(TC.DestinationColor(0x00), frame, binding, (1, 0), [0]) == TC.disproven
    @test TC.evaluate_predicate(TC.DestinationColor(0x00), frame, binding, (12, 0), [0]) == TC.unknown_truth
    samples = [(frame=copy(frame), history=[], effect=TC.unknown_truth),
               (frame=copy(frame), history=[0, 5], effect=TC.proven),
               (frame=copy(frame), history=[0], effect=TC.disproven)]
    q = TC.factor_query(samples, row -> Tuple(vec(row.frame)), row -> row.effect)
    @test q.witness == (samples[2], samples[3])
    @test q.unknown == [samples[1]]
end

@testset "Unpredicted feedback restores a feasible mechanism" begin
    early = fill(UInt8(0), 14, 14)
    early[6:7, 4:5] .= 2
    early[2:3, 10:11] .= 4
    moved = copy(early)
    moved[6:7, 4] .= 0
    moved[6:7, 6] .= 2
    template = TC.shape_template(only(filter(s -> first(s)[3] == 2, TC.support_candidates(early))))
    supported = TC.MotionExample("support", "start-1", 1, early, moved, [0])
    refuted = TC.MotionExample("refute", "start-2", 1, early, early, [0])
    parameter = TC.MotionParameter((1, 0), ["support"], "(vec i1 i0)")
    stale = TC.fit_motion_claim("lib-motion", 1, template, parameter, [supported, refuted])
    @test !stale.guard.feasible
    controller = TC.MotionController(stale, [supported, refuted])
    new_before, new_after = copy(early), copy(moved)
    new_before[2:3, 10:11] .= 7
    new_after[2:3, 10:11] .= 7
    sample = TC.MotionExample("restoring", "start-3", 1, new_before, new_after, [0, 5])
    old = TC.cached_judgment(controller, 1, new_before, "start-3", [0, 5])
    @test old.predicate == TC.unknown_truth
    result = TC.assess_motion!(controller, sample, old)
    @test result.status == "recovered"
    @test result.revision["invalidated"] == ["start-3-action-1"]
    @test result.revision["withdrawn"] == stale.version
    @test controller.claim.guard.feasible
    @test Set(TC.claim_record(controller.claim)["outstanding"]) == Set(["support", "refute"])
    @test TC.cached_judgment(controller, 1, new_before, "start-4", [0, 5]).expected == (1, 0)
    frozen = TC.freeze_motion(controller)
    judgment = TC.cached_judgment(frozen, 1, new_before, "start-4", [0, 5])
    trial = TC.MotionExample("holdout-failure", "start-4", 1, new_before, new_before, [0, 5])
    snapshot = TC.claim_record(frozen.claim)
    @test TC.assess_motion!(frozen, trial, judgment).status == "refuted"
    @test snapshot == TC.claim_record(frozen.claim)
    @test trial.event_id ∉ controller.seen_events
    @test_throws ErrorException TC.assess_motion!(controller, sample, old)
end

@testset "The condition follows the affected role across concrete bindings" begin
    origins = (7,19,31)
    function board(colors)
        scene = fill(0x00,28,44)
        for (x,color) in zip(origins,colors)
            scene[15:16,x+1:x+2] .= 0x02
            scene[7:8,x+3:x+4] .= color
        end
        return scene
    end
    function trial(name,scene,x,dx)
        post = copy(scene)
        post[15:16,x+1:x+2] .= 0x00
        post[15:16,x+1+dx:x+2+dx] .= 0x02
        action = TC.click_action((x,14))
        source = "$(name)-before"
        origin = (event=Dict("event_id"=>source,"before_ref"=>nothing),
            observation=TC.PublicObservation("test","guid",[scene],"NOT_FINISHED",0,1,Dict("id"=>5),[5,6],false))
        response = (event=Dict("event_id"=>name,"before_ref"=>source),
            observation=TC.PublicObservation("test","guid",[post],"NOT_FINISHED",0,1,action,[5,6],false))
        return TC.PublicTrial(TC.motion_example(origin,response;history=[0,5]),action,TC.observed_effects(origin,response))
    end
    left = board((0x03,0x08,0x08))
    right = board((0x08,0x03,0x08))
    known = [trial("left-good",left,origins[1],3),trial("left-bad",left,origins[2],-3),
        trial("right-good",right,origins[2],3),trial("right-bad",right,origins[1],-3)]
    actual = first(known)
    rule = TC.observed_joint_model(actual.effects,actual.sample.before,actual.sample.after)
    outcomes = [TC.evaluate_joint_trial(rule,row).verdict for row in known]
    @test outcomes == [TC.proven,TC.disproven,TC.proven,TC.disproven]
    fitted = TC.fit_joint_condition(rule,known,(;allow_full_frame=true,history_lengths=(1,2)))
    @test fitted.condition.feasible
    @test fitted.condition.support == ["left-good","right-good"]
    @test fitted.condition.excluded == ["left-bad","right-bad"]
    guard = only(fitted.condition.atoms)
    @test guard isa TC.RelativeComponentColor
    @test guard.offset == (2,-8) && guard.pigment == 0x03
    check(frame) = begin
        groups = TC.public_components(frame)
        TC.candidate_evaluation(fitted,frame,groups,TC.enclosure_pairs(groups),
            TC.click_action((last(origins),14)),[0,5];relative_transfer=true)
    end
    @test check(board((0x08,0x08,0x03))).truth == TC.proven
    @test check(board((0x03,0x03,0x08))).truth == TC.disproven
    @test check(board((0x03,0x03,0x00))).truth == TC.unknown_truth
end
