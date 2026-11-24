using Test
using TddESCat
import JSON

const TC = TddESCat

function observations(row)
    previous = nothing
    pairs = []
    for (index, request) in enumerate(row["trace"])
        startswith(request["path"], "/api/cmd/") || continue
        response = request["response"]
        action = Dict("id"=>response["action_input"]["id"])
        for field in ("x","y")
            haskey(request["request"], field) && (action[field] = request["request"][field])
        end
        event_id = "event-" * row["variant"] * "-" * string(index)
        event = Dict("event_id"=>event_id, "before_ref"=>isnothing(previous) ? nothing : previous.event["event_id"])
        entry = (event=event, observation=TC.validate_response(collect(codeunits(JSON.json(response))),
            response["game_id"], response["guid"], action))
        isnothing(previous) || push!(pairs, (previous,entry))
        previous = entry
    end
    return pairs
end

@testset "Multiple effects from public interface responses" begin
    wanted = ["push-open", "resource-one", "panel-toggle", "click-interior"]
    captured = Dict(row["variant"]=>observations(row) for row in JSON.parse.(readlines(ARGS[1]))
        if row["variant"] in wanted && row["seed"] == 0 && row["trial"] == 1)
    @test length(captured) == length(wanted)
    push_event = TC.observed_effects(first(captured["push-open"])...)
    @test [effect.family for effect in push_event.effects] == [:translation, :translation]
    @test Set([length(effect.before) for effect in push_event.effects]) == Set([8,16])
    @test all(effect.values == [2,0] for effect in push_event.effects)
    @test isempty(push_event.residual)
    resource = TC.observed_effects(first(captured["resource-one"])...)
    @test [effect.family for effect in resource.effects] == [:translation,:count]
    @test last(resource.effects).context.before_count == 1
    @test last(resource.effects).context.after_count == 0
    @test isempty(resource.residual)
    panel = TC.observed_effects(captured["panel-toggle"][2]...)
    @test only(panel.effects).family == :pigment
    selection = TC.observed_effects(first(captured["click-interior"])...)
    @test any(effect -> effect.family == :selection && effect.values == [30,24], selection.effects)
    @test isempty(selection.residual)
    corpus = TC.relation_corpus([first(captured["push-open"]), first(captured["resource-one"])])
    @test length(corpus.programs) == 2
    @test length(corpus.slots) == 4
    @test all(length(row["catlab_role_vertices"]) == 2 for row in values(corpus.bindings))
    @test all(startswith(program, "(pair") for program in corpus.programs)
    @test isempty(first(corpus.observed).residual)
end
