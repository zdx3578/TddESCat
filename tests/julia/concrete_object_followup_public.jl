using Test, TddESCat

const TC = TddESCat
const CONFIG = load_run_config(first(ARGS))

@testset "A follow-up chooses the binding with the witnessed remote effect" begin
    with_run(last(ARGS)) do store
        rec = Recorder(store,CONFIG)
        agenda = TC.RelationAgenda()
        memory = TC.InterventionMemory()
        @test open_scorecard!(rec)["completion"] == "confirmed"
        @test reset!(rec,CONFIG.environment["game_id"])["completion"] == "confirmed"
        entry() = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),
            observation=rec.observation)
        function dispatch(action;choice=nothing,proposal=nothing,task=nothing)
            before = entry()
            frame = last(before.observation.frames)
            groups = TC.public_components(frame)
            scene = TC.intervention_scene(frame,groups)
            binding = TC.executed_intervention(choice,scene,action)
            prediction = isnothing(task) ? nothing : TC.relation_prediction(rec,proposal,nothing,task)
            options = action["id"] == 6 ? (x=action["x"],y=action["y"]) : (;)
            @test submit_action!(rec,action["id"];prediction,options...)["completion"] == "confirmed"
            after = entry()
            effects = TC.observed_effects(before,after)
            TC.observe_intervention!(memory,binding,before,after,effects;ordinal=length(agenda.samples)+1)
            result = TC.observe_relations!(agenda,before,after,effects,nothing,NamedTuple[],proposal;groups)
            TC.finish_relation_dispatch!(agenda,proposal;feedback=result.feedback)
            return result
        end

        source = dispatch(TC.click_action((9,11)))
        obs = rec.observation
        view = TC.public_action_candidates(obs,512;object_probes=true)
        ranked = [(;action,rank=(i,0),reason="ordinary_public_candidate")
            for (i,action) in enumerate(view.actions)]
        decision = (;ranked,view.groups)
        scene = TC.intervention_scene(last(obs.frames),view.groups)
        context = TC.relation_context(obs)
        nearby = TC.click_action((24,11))
        farther = TC.click_action((39,11))
        support(action) = TC.point_component(view.groups,TC.action_key(action)[2:3])
        @test TC.click_profile(support(nearby),(24,11)) == TC.click_profile(support(farther),(39,11))
        @test isempty(TC.prepare_relation_tests(agenda,context,obs,view.groups,nearby))
        choice = TC.choose_intervention(memory,scene,obs,ranked,Dict();explore=true,goal_learning=true,
            confirmed_count=1,agenda,groups=view.groups)
        @test choice.action == farther && choice.reason == "extend_observed_object_effect"
        test = only(choice.tests)
        @test test.scope == :unverified && source.event in test.reads
        @test any(part->part.family == :pigment,test.fragments)
        proposal = TC.relation_experiment(agenda,obs,decision,choice,context)
        @test proposal.tests === choice.tests
        arbitration = TC.task_arbitration(first(ranked),nothing,choice,proposal,nothing;
            program=false,continuing_contact=false,conditional=false,object_probes=true)
        @test arbitration.choice.action == farther && arbitration.choice.source == :relation
        task = TC.relation_task_record(proposal)
        selected = dispatch(farther;choice,proposal,task)
        @test selected.feedback.result == :established
        won = dispatch(Dict("id"=>5))
        @test rec.observation.state == "WIN"
        @test close_scorecard!(rec)["completion"] == "confirmed"
        TC.atomic_json(TC.store_path(store,"concrete-object-followup.json"),
            (;source=source.event,nearby,selected=selected.event,won=won.event,task))
        @test last(recover_run(store)).event["event_id"] == won.event
    end
end
