using Test, TddESCat

const TC = TddESCat
config = load_run_config(first(ARGS))

@testset "Public frontier changes a repeated arbitration winner" begin
    with_run(last(ARGS)) do store
        rec = Recorder(store,config)
        agenda, search = TC.RelationAgenda(), TC.PublicFrontier()
        @test open_scorecard!(rec)["completion"] == "confirmed"
        @test reset!(rec,config.environment["game_id"])["completion"] == "confirmed"
        entry() = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),
            observation=rec.observation)
        for _ in 1:2
            before = entry()
            @test submit_action!(rec,2)["completion"] == "confirmed"
            after = entry()
            TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),nothing,NamedTuple[],nothing)
            TC.frontier_observe!(search,agenda)
        end
        obs = rec.observation
        item = (;action=Dict("id"=>1),reason="uncovered")
        experiment = (;action=Dict("id"=>2))
        decision = (;ranked=[item,experiment])
        frontier = (;search,agenda,observation=obs,decision,context=TC.relation_context(obs))
        selection = TC.task_arbitration(item,nothing,nothing,nothing,experiment;
            program=false,continuing_contact=false,conditional=false,object_probes=false,frontier)
        @test selection.baseline.source == :experiment && selection.baseline.action == experiment.action
        @test selection.choice.action == item.action && selection.choice.source == :relation
        task = TC.relation_task_record(selection.frontier_task)
        prediction = TC.relation_prediction(rec,selection.frontier_task,nothing,task)
        @test submit_action!(rec,selection.choice.action["id"];prediction)["completion"] == "confirmed"
        @test rec.observation.state == "WIN"
        TC.atomic_json(TC.store_path(store,"frontier-experiment.json"),(;task,event=rec.before_ref))
        @test close_scorecard!(rec)["completion"] == "confirmed"
        @test last(recover_run(store)).event["event_id"] == rec.before_ref
    end
end
