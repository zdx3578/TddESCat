using Test, TddESCat

const TC = TddESCat
config = load_run_config(first(ARGS))

@testset "A ready history result changes the next confirmed API request" begin
    with_run(last(ARGS)) do store
        rec = Recorder(store,config)
        agenda, frontier, memory = TC.RelationAgenda(), TC.PublicFrontier(), TC.ResponseLearning()
        game = config.environment["game_id"]
        @test open_scorecard!(rec)["completion"] == "confirmed"
        entry() = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref*".json")),observation=rec.observation)
        refined = nothing
        for first_action in (1,4)
            @test reset!(rec,game)["completion"] == "confirmed"
            TC.begin_relation_attempt!(agenda,nothing)
            for action in (first_action,5,7)
                before = entry()
                @test submit_action!(rec,action)["completion"] == "confirmed"
                after = entry()
                TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),nothing,NamedTuple[],nothing)
                refined = TC.frontier_observe!(frontier,agenda)
                TC.observe_response!(memory,agenda;refinement=refined)
            end
            @test rec.observation.state == (first_action == 1 ? "GAME_OVER" : "NOT_FINISHED")
        end
        @test refined.width == 2
        cut = rec.before_ref
        TC.with_compute(config) do backends
            TC.request_history_model!(memory,backends["circuit_python"],agenda,cut,8;priority=true)
            wait(memory.history.job)
            TC.collect_history_model!(memory,store,agenda)
        end
        obs = rec.observation
        context = TC.relation_context(obs)
        history_model = TC.history_experiment(memory,agenda,context,obs.levels_completed)
        candidates = [(action=Dict("id"=>id),rank=(0,0)) for id in (7,2) if id in obs.available_actions]
        decision = (ranked=candidates,groups=TC.public_components(last(obs.frames)))
        ordinary = TC.relation_experiment(agenda,obs,decision,nothing,context)
        @test isnothing(ordinary)
        proposal = TC.relation_experiment(agenda,obs,decision,nothing,context;history_model,frontier)
        @test proposal.intent == :test_history_response && proposal.obligation.history.changed_action
        @test proposal.action == Dict("id"=>2)
        task = TC.relation_task_record(proposal)
        prediction = TC.relation_prediction(rec,proposal,nothing,task)
        sent = submit_action!(rec,proposal.action["id"];prediction)
        @test sent["completion"] == "confirmed"
        @test rec.observation.action == proposal.action
        TC.atomic_json(TC.store_path(store,"history-experiment.json"),(;task,event=rec.before_ref))
        @test close_scorecard!(rec)["completion"] == "confirmed"
        @test last(recover_run(store)).event["event_id"] == rec.before_ref
    end
end
