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
    @test TC.evaluate_predicate(TC.ClearDestination(), frame, binding, (1, 0), [0]) == TC.proven
    frame[7, 6] = 3
    @test frame[6, 6] == 0
    @test TC.evaluate_predicate(TC.ClearDestination(), frame, binding, (1, 0), [0]) == TC.disproven
    @test TC.evaluate_predicate(TC.ClearDestination(), frame, binding, (12, 0), [0]) == TC.unknown_truth
    samples = [(frame=copy(frame), history=[], effect=TC.unknown_truth),
               (frame=copy(frame), history=[0, 5], effect=TC.proven),
               (frame=copy(frame), history=[0], effect=TC.disproven)]
    q = TC.factor_query(samples, row -> Tuple(vec(row.frame)), row -> row.effect)
    @test q.witness == (samples[2], samples[3])
    @test q.unknown == [samples[1]]
end
