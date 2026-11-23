using Test
using Catlab
import ACSets
import GATlab
import AlgebraicRewriting as Rewriting
using Catlab.CategoricalAlgebra.Misc.FinRelations: BoolRig, FinRel, FinRelationMatrix

const GRAPH_CAT = ACSetCategory(CSetCat(Graph()))

@testset "Category dependency contracts" begin
    @testset "Indexed C-set" begin
        graph = Graph(3)
        add_edges!(graph, [1, 1], [2, 3])
        @test collect(ACSets.incident(graph, 1, :src)) == [1, 2]
        @test ACSets.subpart(graph, 2, :tgt) == 3
        @test nv(Graph(1)) == 1
    end

    @testset "Pushout and complete hom search" begin
        edge = path_graph(Graph, 2)
        interface = Graph(1)
        left = ACSetTransformation(interface, edge; V=[2], cat=GRAPH_CAT)
        right = ACSetTransformation(interface, edge; V=[1], cat=GRAPH_CAT)
        glued = pushout[GRAPH_CAT](left, right)
        @test (nv(ob(glued)), ne(ob(glued))) == (3, 2)
        @test coproj1(glued)[:V](2) == coproj2(glued)[:V](1)

        target = path_graph(Graph, 4)
        locals = homomorphisms(edge, target; cat=GRAPH_CAT, alg=BacktrackingSearch())
        compatible = Set(
            (m[:V](1), m[:V](2), n[:V](2)) for m in locals for n in locals
            if m[:V](2) == n[:V](1)
        )
        whole = homomorphisms(ob(glued), target; cat=GRAPH_CAT, alg=BacktrackingSearch())
        tuples = [
            (m[:V](coproj1(glued)[:V](1)), m[:V](coproj1(glued)[:V](2)),
             m[:V](coproj2(glued)[:V](2))) for m in whole
        ]
        @test length(tuples) == length(compatible) == 2
        @test Set(tuples) == compatible == Set([(1, 2, 3), (2, 3, 4)])
    end

    @testset "Distinctness after gluing" begin
        one = Graph(1)
        local_match = only(homomorphisms(one, one; cat=GRAPH_CAT, monic=true))
        @test is_monic(local_match)
        interface = Graph()
        inclusion = ACSetTransformation(interface, one; cat=GRAPH_CAT)
        pair = ob(pushout[GRAPH_CAT](inclusion, inclusion))
        merged = only(homomorphisms(pair, one; cat=GRAPH_CAT))
        @test merged[:V](1) == merged[:V](2)
        @test isempty(homomorphisms(pair, one; cat=GRAPH_CAT, monic=true))
    end

    @testset "Naturality equations" begin
        source = FinCat(path_graph(Graph, 2))
        target = Category(FinSetC())
        functor = FinDomFunctor(
            [FinSet(4), FinSet(2)], [FinFunction([1, 1, 2, 2])], source, target
        )
        nonsquare = Transformation([FinFunction(1:4), FinFunction([2, 1])], functor, functor)
        @test is_natural(nonsquare; check_equations=false)
        @test !is_natural(nonsquare; check_equations=true)
        failures = naturality_failures(nonsquare; check_equations=true)
        @test only(failures)[1] == :eq
    end

    @testset "Typed composition" begin
        a, b = Ob(FreeCategory, :a), Ob(FreeCategory, :b)
        f, g = Hom(:f, a, b), Hom(:g, b, a)
        @test compose(id(a), f) == f == compose(f, id(b))
        @test compose(compose(f, g), f) == compose(f, compose(g, f))
        @test_throws GATlab.SyntaxDomainError compose(f, f)
    end

    @testset "Rectangular finite relations" begin
        first = FinRelationMatrix(BoolRig.([true false; false true; true false]))
        second = FinRelationMatrix(BoolRig.([true false true; false true false]))
        @test (dom(first), codom(first)) == (FinRel(2), FinRel(3))
        @test (dom(second), codom(second)) == (FinRel(3), FinRel(2))
        @test first(1, 3) && !first(2, 3)
        @test second(3, 1) && !second(3, 2)
        joined = compose(first, second)
        @test [joined(x, y) for x in 1:2, y in 1:2] == [true false; false true]
        post(xs) = Set(y for y in 1:3 if any(first(x, y) for x in xs))
        wlp(ys) = Set(x for x in 1:2 if all(!first(x, y) || y in ys for y in 1:3))
        @test post([1]) == Set([1, 3])
        @test wlp([1, 3]) == Set([1])
        @test isempty(wlp([1]))
    end

    @testset "DPO gluing" begin
        one, empty = Graph(1), Graph()
        erase = Rewriting.Rule{:DPO}(
            ACSetTransformation(empty, one; cat=GRAPH_CAT), id[GRAPH_CAT](empty); cat=GRAPH_CAT
        )
        legal = id[GRAPH_CAT](one)
        @test isnothing(Rewriting.can_match(erase, legal; cat=GRAPH_CAT))
        @test nv(Rewriting.rewrite_match(erase, legal; cat=GRAPH_CAT, check=true)) == 0
        edge = path_graph(Graph, 2)
        illegal = ACSetTransformation(one, edge; V=[1], cat=GRAPH_CAT)
        failure = Rewriting.can_match(erase, illegal; cat=GRAPH_CAT)
        @test !isnothing(failure)
        @test first(failure) == "Gluing conditions failed"
    end
end
