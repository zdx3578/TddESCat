using Test, TddESCat

const TC = TddESCat
config = load_run_config(first(ARGS))

@testset "A reachable experiment changes the first-level decision" begin
    with_run(last(ARGS)) do store
        rec = Recorder(store,config)
        agenda,search = TC.RelationAgenda(),TC.PublicFrontier()
        @test open_scorecard!(rec)["completion"] == "confirmed"
        @test reset!(rec,config.environment["game_id"])["completion"] == "confirmed"
        entry() = (;event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),
            observation=rec.observation)
        function decision()
            actions = TC.public_action_candidates(rec.observation,512;object_probes=true)
            ranked = [(;action,rank=(action["id"],0),reason="coverage")
                for action in sort(actions.actions;by=action->action["id"])]
            return (;ranked,actions.groups)
        end
        function dispatch(action,proposal=nothing)
            before = entry()
            TC.frontier_options!(search,TC.relation_context(before.observation),decision().ranked,nothing)
            task = isnothing(proposal) ? nothing : TC.relation_task_record(proposal)
            prediction = isnothing(task) ? nothing : TC.relation_prediction(rec,proposal,nothing,task)
            @test submit_action!(rec,action["id"];prediction)["completion"] == "confirmed"
            after = entry()
            result = TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),
                nothing,NamedTuple[],proposal)
            TC.frontier_observe!(search,agenda)
            continuation = TC.confirm_frontier_route!(search,agenda,proposal)
            TC.finish_relation_dispatch!(agenda,proposal;feedback=result.feedback)
            return (;task,continuation,result.feedback)
        end
        for action in (4,4,1,2,3,4,1)
            dispatch(Dict("id"=>action))
        end
        TC.begin_relation_attempt!(agenda,nothing)
        @test reset!(rec,config.environment["game_id"])["completion"] == "confirmed"
        dispatch(Dict("id"=>4))
        function choose()
            obs = rec.observation
            view = decision()
            context = TC.relation_context(obs)
            frontier = (;search,agenda,observation=obs,decision=view,context)
            relation = TC.relation_experiment(agenda,obs,view,nothing,context;frontier=search)
            pick = TC.task_arbitration(first(view.ranked),nothing,nothing,relation,nothing;
                program=false,continuing_contact=false,conditional=false,object_probes=true,frontier)
            task = pick.choice.source == :relation ? something(pick.frontier_task,relation) : nothing
            bound = TC.bind_relation_reads(agenda,task,obs,pick.choice.action)
            return (;bound,pick)
        end
        start = choose()
        if "--choice-only" in ARGS
            chosen = dispatch(start.pick.choice.action,start.bound)
            @test close_scorecard!(rec)["completion"] == "confirmed"
            TC.atomic_json(TC.store_path(store,"choice.json"),(;start.pick.choice,start.pick.baseline,
                intent=isnothing(chosen.task) ? nothing : chosen.task.intent,receipt=rec.before_ref))
            return
        end
        @test start.bound.intent == :explore_observed_frontier_path
        @test start.bound.action != start.pick.baseline.action && isnothing(search.route)
        route = dispatch(start.pick.choice.action,start.bound)
        @test route.continuation.status == :confirmed
        finish = choose()
        @test finish.bound.intent == :test_preparation_omission
        trial = dispatch(finish.pick.choice.action,finish.bound)
        @test trial.feedback.omission.status == :changed_to_no_effect
        @test rec.observation.state == "NOT_FINISHED" && rec.observation.levels_completed == 0
        @test close_scorecard!(rec)["completion"] == "confirmed"
        TC.atomic_json(TC.store_path(store,"reachable-omission.json"),(;baseline=start.pick.baseline.action,
            route=route.task,trial=trial.task,trial.feedback))
    end
end
