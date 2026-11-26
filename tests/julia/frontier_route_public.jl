using Test, TddESCat

const TC = TddESCat
config = load_run_config(first(ARGS))

@testset "The observed route commits before its experiment is dispatched" begin
    with_run(last(ARGS)) do store
        rec = Recorder(store,config)
        agenda, search = TC.RelationAgenda(), TC.PublicFrontier()
        @test open_scorecard!(rec)["completion"] == "confirmed"
        @test reset!(rec,config.environment["game_id"])["completion"] == "confirmed"
        entry() = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),
            observation=rec.observation)
        ranked() = [(;action=Dict("id"=>id),reason="uncovered") for id in rec.observation.available_actions]
        function dispatch(id,proposal=nothing)
            before = entry()
            task = isnothing(proposal) ? nothing : TC.relation_task_record(proposal)
            prediction = isnothing(task) ? nothing : TC.relation_prediction(rec,proposal,nothing,task)
            @test submit_action!(rec,id;prediction)["completion"] == "confirmed"
            after = entry()
            TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),nothing,NamedTuple[],proposal)
            TC.frontier_observe!(search,agenda)
            feedback = TC.confirm_frontier_route!(search,agenda,proposal)
            return (;task,event=rec.before_ref,feedback)
        end
        for _ in 1:4
            TC.frontier_options!(search,TC.relation_context(rec.observation),ranked(),nothing)
            dispatch(2)
        end
        function select(id)
            obs = rec.observation
            decision = (;ranked=ranked())
            frontier = (;search,agenda,observation=obs,decision,context=TC.relation_context(obs))
            item = (;action=Dict("id"=>id),reason="coverage")
            return TC.task_arbitration(item,nothing,nothing,nothing,nothing;
                program=false,continuing_contact=false,conditional=false,object_probes=false,frontier)
        end
        route = select(2).frontier_task
        @test route.intent == :explore_observed_frontier_path
        @test search.route === nothing
        followed = dispatch(2,route)
        @test followed.feedback.status == :confirmed
        proposed = select(3)
        @test proposed.baseline.action == Dict("id"=>3)
        @test proposed.choice.action == Dict("id"=>1)
        @test proposed.frontier_task.obligation.source == "reachable_frontier_obligation"
        completed = dispatch(1,proposed.frontier_task)
        @test rec.observation.state == "WIN" && search.route === nothing
        TC.atomic_json(TC.store_path(store,"frontier-route.json"),(;followed,completed))
        @test close_scorecard!(rec)["completion"] == "confirmed"
        @test last(recover_run(store)).event["event_id"] == rec.before_ref
    end
end
