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
