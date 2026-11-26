using Test, TddESCat

const TC = TddESCat
config = load_run_config(first(ARGS))

@testset "A less observed sequence can get a dispatch without consuming the regular obligation" begin
    with_run(last(ARGS)) do store
        rec = Recorder(store,config)
        schedule = TC.ExperimentSchedule()
        history = [0]
        @test open_scorecard!(rec)["completion"] == "confirmed"
        @test reset!(rec,config.environment["game_id"])["completion"] == "confirmed"
        for id in (1,2,1,2,2,1,2)
            before = rec.observation
            @test submit_action!(rec,id)["completion"] == "confirmed"
            TC.record_experiment_prefix!(schedule,before.levels_completed,before.available_actions,history,
                rec.observation.action,rec.before_ref)
            push!(history,id)
        end
        obs = rec.observation
        ranked = [(;action=Dict("id"=>id),reason="coverage") for id in obs.available_actions]
        proposal = TC.select_experiment!(schedule,store,ranked,obs.available_actions,rec.before_ref;
            level=obs.levels_completed,history)
        @test proposal.action == Dict("id"=>3)
        @test proposal.obligation.prefix == (1,2)
        @test proposal.obligation.baseline == Dict("id"=>1)
        @test proposal.obligation.baseline_experiments == 1 && proposal.obligation.previous_experiments == 0
        selected = TC.task_arbitration(first(ranked),nothing,nothing,nothing,proposal;
            program=false,continuing_contact=false,conditional=false,object_probes=false)
        @test selected.choice.action == proposal.action && selected.choice.source == :experiment
        @test schedule.cursor == 1 && !schedule.deferred_once
        @test submit_action!(rec,selected.choice.action["id"])["completion"] == "confirmed"
        event = TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json"))
        TC.record_experiment_service!(schedule,store,proposal,event)
        @test schedule.cursor == 1 && schedule.deferred_once
        @test rec.observation.state == "WIN"
        TC.atomic_json(TC.store_path(store,"sequence-experiment.json"),(;proposal,event=rec.before_ref))
        @test close_scorecard!(rec)["completion"] == "confirmed"
        @test last(recover_run(store)).event["event_id"] == rec.before_ref
    end
end
