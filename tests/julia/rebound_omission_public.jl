using Test, TddESCat

const TC = TddESCat
config = load_run_config(first(ARGS))

@testset "A changed external display permits an explicitly confounded local experiment" begin
    with_run(last(ARGS)) do store
        rec = Recorder(store,config)
        agenda,search = TC.RelationAgenda(),TC.PublicFrontier()
        @test open_scorecard!(rec)["completion"] == "confirmed"
        @test reset!(rec,config.environment["game_id"])["completion"] == "confirmed"
        entry() = (;event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),
            observation=rec.observation)
        function decision()
            actions = TC.public_action_candidates(rec.observation,512;object_probes=true)
            ranked = [(;action,rank=(action["id"],0),reason="coverage") for action in actions.actions]
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
            TC.finish_relation_dispatch!(agenda,proposal;feedback=result.feedback)
            TC.frontier_observe!(search,agenda)
            TC.confirm_frontier_route!(search,agenda,proposal)
            return (;task,result,event=rec.before_ref)
        end
        for id in (5,1,2,3,5)
            dispatch(Dict("id"=>id))
        end
        function choose()
            obs = rec.observation
            context = TC.relation_context(obs)
            view = decision()
            frontier = (;search,agenda,observation=obs,decision=view,context)
            proposed = TC.relation_experiment(agenda,obs,view,nothing,context;frontier=search)
            voted = TC.task_arbitration(first(view.ranked),nothing,nothing,proposed,nothing;
                program=false,continuing_contact=false,conditional=false,object_probes=true,frontier)
            task = voted.choice.source == :relation ? something(voted.frontier_task,proposed) : nothing
            bound = TC.bind_relation_reads(agenda,task,obs,voted.choice.action)
            return (;voted.choice,bound)
        end
        picked = choose()
        if "--choice-only" in ARGS
            step = dispatch(picked.choice.action,picked.bound)
            @test close_scorecard!(rec)["completion"] == "confirmed"
            TC.atomic_json(TC.store_path(store,"choice.json"),(;picked.choice,
                intent=isnothing(step.task) ? nothing : step.task.intent,receipt=step.event))
            return
        end
        @test picked.bound.intent == :test_rebound_omission
        @test picked.choice.action == Dict("id"=>2)
        @test picked.bound.obligation.isolated == false
        @test !isempty(picked.bound.obligation.uncontrolled.pixel_spans)
        trial = dispatch(picked.choice.action,picked.bound)
        @test trial.result.feedback.result == :observed
        @test all(e->e.usage != :omission_contrast,trial.result.fact_flow.inputs)
        @test isempty(agenda.outcome_relations)
        @test rec.observation.levels_completed == 0
        TC.atomic_json(TC.store_path(store,"rebound-omission.json"),(;trial.task,trial.event,
            trial.result.feedback,inputs=trial.result.fact_flow.inputs))
        @test close_scorecard!(rec)["completion"] == "confirmed"
    end
end
