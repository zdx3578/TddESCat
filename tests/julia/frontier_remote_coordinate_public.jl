using Test, TddESCat

const TC = TddESCat
const CONFIG = load_run_config(first(ARGS))

@testset "A legal coordinate reachable after failure keeps the agenda open" begin
    with_run(last(ARGS)) do store
        rec = Recorder(store,CONFIG)
        agenda, frontier = TC.RelationAgenda(), TC.PublicFrontier()
        @test open_scorecard!(rec)["completion"] == "confirmed"
        @test reset!(rec,CONFIG.environment["game_id"])["completion"] == "confirmed"
        entry() = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),
            observation=rec.observation)
        function dispatch(action,proposal=nothing)
            before = entry()
            task = isnothing(proposal) ? nothing : TC.relation_task_record(proposal)
            prediction = isnothing(task) ? nothing : TC.relation_prediction(rec,proposal,nothing,task)
            options = action["id"] == 6 ? (x=action["x"],y=action["y"]) : (;)
            @test submit_action!(rec,action["id"];prediction,options...)["completion"] == "confirmed"
            after = entry()
            result = TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),
                nothing,NamedTuple[],proposal)
            TC.finish_relation_dispatch!(agenda,proposal;feedback=result.feedback)
            TC.frontier_observe!(frontier,agenda)
            return result
        end
        function next_task(representative)
            obs = rec.observation
            context = TC.relation_context(obs)
            ranked = [(;action=representative,rank=(0,0),reason="uncovered")]
            groups = TC.public_components(last(obs.frames))
            return TC.relation_experiment(agenda,obs,(;ranked,groups),nothing,context;frontier)
        end

        enable = Dict("id"=>2)
        representative = TC.click_action((9,11))
        first = dispatch(enable)
        failed = dispatch(representative)
        @test rec.observation.state == "GAME_OVER"
        start = TC.frontier_state(agenda,first.context,0)
        @test isempty(TC.frontier_untried(frontier,start))
        @test isnothing(TC.frontier_path(frontier,agenda,start))
        @test isnothing(TC.frontier_new_configuration(frontier,start,[2]))
        retry = TC.failure_retry!(agenda;frontier)
        @test retry.experiment_path == [1]
        @test reset!(rec,CONFIG.environment["game_id"])["completion"] == "confirmed"
        reset = rec.before_ref
        TC.begin_relation_attempt!(agenda,retry;observation=rec.observation)

        route = next_task(enable)
        @test route.intent == :restore_failure_experiment_context && route.action == enable
        restored = dispatch(route.action,route)
        @test restored.feedback.result == :established
        experiment = next_task(representative)
        @test experiment.intent == :revise_failed_trace && experiment.action == TC.click_action((0,0))
        won = dispatch(experiment.action,experiment)
        @test rec.observation.state == "WIN"
        @test close_scorecard!(rec)["completion"] == "confirmed"
        TC.atomic_json(TC.store_path(store,"frontier-remote-coordinate.json"),
            (;first=first.event,failed=failed.event,reset,restored=restored.event,won=won.event))
        @test last(recover_run(store)).event["event_id"] == won.event
    end
end
