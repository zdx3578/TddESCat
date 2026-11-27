using Test, TddESCat

const TC = TddESCat
const CONFIG = load_run_config(first(ARGS))

@testset "Concrete counterexamples refine which effects can be reused" begin
    with_run(last(ARGS)) do store
        rec = Recorder(store,CONFIG)
        agenda,knowledge = TC.RelationAgenda(),TC.OnlineKnowledge()
        @test open_scorecard!(rec)["completion"] == "confirmed"
        @test reset!(rec,CONFIG.environment["game_id"])["completion"] == "confirmed"
        entry() = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),
            observation=rec.observation)
        history = [0]
        limits = (;context_radii=(1,2),allow_full_frame=true,history_lengths=(1,2))
        function dispatch(action;proposal=nothing)
            before = entry()
            task = isnothing(proposal) ? nothing : TC.relation_task_record(proposal)
            prediction = isnothing(task) ? nothing : TC.relation_prediction(rec,proposal,nothing,task)
            options = action["id"] == 6 ? (x=action["x"],y=action["y"]) : (;)
            @test submit_action!(rec,action["id"];prediction,options...)["completion"] == "confirmed"
            after = entry()
            effects = TC.observed_effects(before,after)
            sample = TC.motion_example(before,after;history)
            push!(knowledge.trials,TC.PublicTrial(sample,action,effects))
            push!(history,action["id"])
            observed = TC.observe_relations!(agenda,before,after,effects,nothing,NamedTuple[],proposal)
            TC.finish_relation_dispatch!(agenda,proposal;feedback=observed.feedback)
            revisions = TC.revise_observed_conditions!(knowledge,agenda,proposal,observed,limits)
            return (;observed,prediction,revisions)
        end

        refresh = Dict("id"=>5)
        left,second,third,last_role = [TC.click_action((x,11)) for x in (9,21,33,45)]
        first_support = dispatch(left).observed
        dispatch(refresh)
        groups = TC.public_components(last(rec.observation.frames))
        context = TC.relation_context(rec.observation)
        tests = TC.prepare_relation_tests(agenda,context,rec.observation,groups,left)
        @test only(tests).key == first_support.producer.key
        test = (;action=left,intent=:test_concrete_effect,tests,reads=String[],obligation=nothing)
        trial = dispatch(left;proposal=test)
        refuted = trial.observed
        @test refuted.feedback.result == :refuted
        @test refuted.producer.key != first_support.producer.key
        @test only(trial.revisions).status == :repaired
        @test only(trial.revisions).excluded == [refuted.event]
        dispatch(refresh)
        following = dispatch(second)
        next_support = following.observed
        @test next_support.producer.key == first_support.producer.key
        dispatch(refresh)

        function propose(action;condition_view=nothing,require_contrast=false)
            obs = rec.observation
            frame = last(obs.frames)
            groups = TC.public_components(frame)
            context = TC.relation_context(obs)
            point = TC.action_key(action)[2:3]
            candidate = filter(row->row.point == point,TC.intervention_scene(frame,groups))
            follow = TC.object_effect_followup(agenda,obs,context,candidate;groups,condition_view)
            @test !isnothing(follow)
            ranked = [(;action,rank=(i,0),reason="ordinary_public_candidate")
                for (i,action) in enumerate((refresh,action))]
            decision = (;ranked,groups,condition_view)
            intervention = (;action,reason="extend_observed_object_effect",goal=nothing,
                follow.tests,effect_experiment=follow.purpose)
            proposal = if require_contrast
                TC.relation_experiment(agenda,obs,decision,intervention,context)
            else
                (;action,intent=:test_concrete_effect,follow.tests,reads=String[],obligation=follow.purpose)
            end
            @test proposal.obligation == follow.purpose
            arbitration = TC.task_arbitration(first(ranked),nothing,intervention,proposal,nothing;
                program=false,continuing_contact=false,conditional=false,object_probes=true)
            @test arbitration.choice.source == :relation && arbitration.choice.action == action
            return proposal
        end

        choice = propose(third;require_contrast=true)
        @test choice.obligation.comparison == :distinguish_concrete_effects
        @test length(choice.tests) == 2
        @test Set(only(values(test.expected)) for test in choice.tests) == Set([(3,0),(-3,0)])
        contrasted = dispatch(third;proposal=choice)
        @test contrasted.prediction.payload["guard_truth"] == "unknown"
        @test Set(test.status for test in contrasted.observed.feedback.tests) == Set((:established,:refuted))
        dispatch(refresh)

        positive = (agenda.producers[first_support.producer.key]).rule
        negative = (agenda.producers[refuted.producer.key]).rule
        models = [knowledge.observed_conditions[TC.relation_condition_key(rule)] for rule in (positive,negative)]
        @test all(model->model.condition.feasible && !isempty(model.condition.atoms),models)
        @test refuted.event in first(models).condition.excluded
        @test next_support.event in first(models).condition.support
        @test isempty(knowledge.active)
        current = rec.observation
        condition_view = TC.relation_condition_view(knowledge,rec,history,current)
        learned = propose(last_role;condition_view)
        witness = only(learned.tests)
        @test witness.key == first_support.producer.key && witness.scope == :replicated
        @test refuted.event in witness.reads && next_support.event in witness.reads
        @test only(witness.conditions).version == TC.active_id(first(models))
        actual = dispatch(last_role;proposal=learned)
        @test actual.prediction.payload["guard_truth"] === true
        @test actual.observed.feedback.result == :established
        @test rec.observation.state == "WIN" && close_scorecard!(rec)["completion"] == "confirmed"
        TC.atomic_json(TC.store_path(store,"effect-condition-contrast.json"),(;
            refuted,contrasted=contrasted.observed,won=actual.observed,
            contrast=contrasted.prediction.payload,prediction=actual.prediction.payload,
            revisions=[trial.revisions;following.revisions;contrasted.revisions]))
        @test last(recover_run(store)).event["event_id"] == actual.observed.event
    end
end
