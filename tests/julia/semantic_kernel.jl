using Test
using TddESCat
import Catlab
import JSON

const REF0 = (event_id="prior", frame_index=0, interpretation="finite-pixel-v1")
const REF1 = (event_id="next", frame_index=1, interpretation="finite-pixel-v1")

@testset "Colored adjacency and windows" begin
    frame = UInt8[2 2 2 2 2; 2 2 0 2 2; 0 0 0 0 0]
    all_cells = color_components(frame)
    @test length([g for g in all_cells.groups if g[1][3] == 2]) == 1
    window = Window(0, 1, 5, 1)
    view_pixels = crop_frame(frame, window)
    @test length([g for g in color_components(view_pixels).groups if g[1][3] == 2]) == 2
    @test embed_point(window, (3, 0)) == (3, 1)
    @test_throws ArgumentError crop_frame(frame, Window(2, 0, 5, 1))
    @test length(color_components(UInt8[1 0; 0 1], 4).groups) == 4
    @test length(color_components(UInt8[1 0; 0 1], 8).groups) == 2
    @test color_components(permutedims(frame)).owner[2, 1] ==
        color_components(permutedims(frame)).owner[5, 2]
end

@testset "Complete support, overlap and competing candidate roles" begin
    before = UInt8[0 9 9 9 0 0; 0 9 9 9 0 0; 0 0 0 0 0 0]
    after =  UInt8[0 0 9 9 9 0; 0 0 9 9 9 0; 0 0 0 0 0 0]
    result = correspondence_candidates(before, after, REF0, REF1; max_support_pixels=6)
    @test result.complete
    motion = only(c for c in result.candidates if c.delta == (1, 0) && length(c.before) == 6)
    @test length(intersect(motion.before, motion.after)) == 4
    @test all(ref -> ref.event_id == "prior", motion.source_before)
    @test all(ref -> ref.event_id == "next" && ref.response_frame_index == 1, motion.source_after)
    @test check_available(motion.source_before, Dict("prior" => 1, "next" => 2), 2).available
    @test !check_available(motion.source_after, Dict("prior" => 1, "next" => 2), 2).available
    @test check_available(motion.source_after, Dict("prior" => 1, "next" => 2), 3).available

    relabeled = correspondence_candidates(0x0f .- before, 0x0f .- after, REF0, REF1; max_support_pixels=6)
    @test [c.delta for c in relabeled.candidates] == [c.delta for c in result.candidates]
    incomplete = correspondence_candidates(before, after, REF0, REF1; max_work=1)
    @test !incomplete.complete && incomplete.reason == "grounding_budget"

    peers = UInt8[3 3 0 0 3 3]
    candidates = correspondence_candidates(peers, peers, REF0, REF1; max_support_pixels=2).candidates
    @test any(c -> c.delta == (0, 0) && c.before[1] == (0, 0, 0x03), candidates)
    @test any(c -> c.delta == (4, 0) && c.before[1] == (0, 0, 0x03), candidates)

    one = UInt8[9 4 0 0 0; 9 0 0 0 0]
    moved = UInt8[0 9 4 0 0; 0 9 0 0 0]
    joint = correspondence_candidates(one, moved, REF0, REF1; max_support_pixels=3)
    @test any(c -> c.delta == (1, 0) && length(unique([cell[3] for cell in c.before])) == 2, joint.candidates)
    touch = correspondence_candidates(UInt8[2 2 0 2 2], UInt8[0 2 2 2 2], REF0, REF1; max_support_pixels=4)
    @test any(c -> c.delta == (1, 0) && length(c.before) == 2 && !c.full_after_candidate, touch.candidates)
end

@testset "Explicit Catlab model and typed terms" begin
    pattern = support_graph(Tuple{Int,Int,UInt8}[(0, 0, 2), (1, 0, 2)])
    scene = support_graph(Tuple{Int,Int,UInt8}[(5, 2, 2), (6, 2, 2), (7, 2, 2)])
    all_matches = match_pattern(pattern, scene)
    @test all_matches.complete && Set(Tuple.(all_matches.bindings)) == Set([(1, 2), (2, 3)])
    @test !match_pattern(pattern, scene; max_witnesses=1).complete
    @test isempty(glue_matches([Dict("a" => 1)], [Dict("b" => 1)], String[]; distinct=[("a", "b")]))
    @test glue_matches([Dict("a" => 1)], [Dict("a" => 1, "b" => 2)], ["a"]) == [Dict("a" => 1, "b" => 2)]
    interface = Catlab.Graph(1)
    category = TddESCat.SUPPORT_CATEGORY
    left = Catlab.ACSetTransformation(interface, pattern.graph; V=[2], cat=category)
    right = Catlab.ACSetTransformation(interface, pattern.graph; V=[1], cat=category)
    @test check_schema_map(left).natural
    @test Catlab.nv(Catlab.ob(glue_patterns(left, right))) == 3
    registry = evidence_signature()
    delta = Call("vec", Literal("Integer", 1), Literal("Integer", 0))
    relation = Call("link", Slot(0), Slot(1), delta)
    result = infer_term(relation, registry; slots=["RoleBefore", "RoleAfter"])
    @test result.sort == "Relation" && result.reads == [(:slot, 0), (:slot, 1)]
    @test_throws ArgumentError infer_term(relation, registry; slots=["RoleAfter", "RoleBefore"])
    @test_throws ArgumentError infer_term(Slot(0), registry; params=["RoleBefore"], mode=:definition)
    @test_throws ArgumentError Literal("Integer", true)
end

if !isempty(ARGS)
    @testset "Grounding from official local HTTP evidence" begin
        events = with_run(recover_run, ARGS[1])
        result = ground_event(events[1], events[2])
        @test length(result.changed) == 16
        candidate = only(c for c in result.candidates if length(c.before) == 24 && c.delta == (2, 0))
        @test candidate.full_after_candidate
        @test length(intersect(candidate.before, candidate.after)) == 16
        term = historical_program(candidate)
        @test infer_term(term, evidence_signature(); slots=["RoleBefore", "RoleAfter"]).sort == "Relation"
        println(JSON.json((from=result.before_event, to=result.after_event, delta=candidate.delta,
            support_pixels=length(candidate.before), unchanged_overlap=16,
            closed_scope=result.complete, program=render_term(term))))
    end
end
