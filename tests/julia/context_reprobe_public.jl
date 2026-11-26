using Test, TddESCat

const TC = TddESCat
const CONFIG = load_run_config(first(ARGS))

@testset "Confirmed context comparisons give a less tested binding a turn" begin
    with_run(last(ARGS)) do store
        rec = Recorder(store,CONFIG)
        agenda = TC.RelationAgenda()
        @test open_scorecard!(rec)["completion"] == "confirmed"
        @test reset!(rec,CONFIG.environment["game_id"])["completion"] == "confirmed"
        entry() = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),
            observation=rec.observation)
        function dispatch(action,proposal=nothing)
            before = entry()
            task = isnothing(proposal) ? nothing : TC.relation_task_record(proposal)
            prediction = isnothing(task) ? nothing : TC.relation_prediction(rec,proposal,nothing,task)
            kwargs = action["id"] == 6 ? (x=action["x"],y=action["y"]) : (;)
            @test submit_action!(rec,action["id"];prediction,kwargs...)["completion"] == "confirmed"
            after = entry()
            result = TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),
                nothing,NamedTuple[],proposal)
            TC.finish_relation_dispatch!(agenda,proposal;feedback=result.feedback)
            return result
        end
        function proposal()
            obs = rec.observation
            groups = TC.public_components(last(obs.frames))
            scene = TC.intervention_scene(last(obs.frames),groups)
            choice = TC.changed_context_probe(agenda,obs,scene)
            return (;action=choice.action,intent=:distinguish_changed_context,tests=NamedTuple[],
                reads=choice.changed_context.reads,obligation=choice.changed_context)
        end
        left, right = TC.click_action((9,11)), TC.click_action((24,11))
        change = Dict("id"=>5)
        dispatch(left)
        dispatch(right)
        dispatch(change)
        first = proposal()
        @test first.action == left && first.obligation.prior_confirmed_tests == 0
        @test proposal() == first && isempty(agenda.context_comparisons)
        observed = dispatch(first.action,first)
        @test observed.feedback.comparison.confirmed_tests == 1
        @test !observed.feedback.comparison.response_changed

        dispatch(change)
        dispatch(change)
        next = proposal()
        @test next.action == right && next.obligation.prior_confirmed_tests == 0
        @test observed.event in next.reads
        won = dispatch(next.action,next)
        @test won.feedback.comparison.confirmed_tests == 1
        @test won.feedback.comparison.response_changed
        @test rec.observation.state == "WIN"
        @test close_scorecard!(rec)["completion"] == "confirmed"
        @test last(recover_run(store)).event["event_id"] == won.event
        TC.atomic_json(TC.store_path(store,"context-reprobe.json"),(;
            first=observed.event,won=won.event,next.reads,next.obligation.prior_confirmed_tests))
    end
end
