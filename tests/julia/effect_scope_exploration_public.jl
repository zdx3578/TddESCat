using Test, TddESCat

const TC = TddESCat
const CONFIG = load_run_config(first(ARGS))

@testset "A confirmed effect keeps its scope across unrelated frame changes" begin
    with_run(last(ARGS)) do store
        rec = Recorder(store,CONFIG)
        agenda, memory = TC.RelationAgenda(), TC.InterventionMemory()
        @test open_scorecard!(rec)["completion"] == "confirmed"
        @test reset!(rec,CONFIG.environment["game_id"])["completion"] == "confirmed"
        entry() = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),
            observation=rec.observation)
        function scene(obs)
            frame = last(obs.frames)
            groups = TC.public_components(frame)
            return (;groups,candidates=TC.intervention_scene(frame,groups))
        end
        function dispatch(action,proposal=nothing,choice=nothing)
            before = entry()
            view = scene(before.observation)
            intervention = TC.executed_intervention(choice,view.candidates,action)
            task = isnothing(proposal) ? nothing : TC.relation_task_record(proposal)
            prediction = isnothing(task) ? nothing : TC.relation_prediction(rec,proposal,nothing,task)
            kwargs = action["id"] == 6 ? (x=action["x"],y=action["y"]) : (;)
            @test submit_action!(rec,action["id"];prediction,kwargs...)["completion"] == "confirmed"
            after = entry()
            effect = TC.observed_effects(before,after)
            TC.observe_intervention!(memory,intervention,before,after,effect;ordinal=length(agenda.samples)+1)
            receipt = TC.observe_relations!(agenda,before,after,effect,nothing,NamedTuple[],proposal;view.groups)
            TC.finish_relation_dispatch!(agenda,proposal;feedback=receipt.feedback)
            return receipt
        end

        left,right = TC.click_action((9,11)),TC.click_action((39,11))
        refresh = Dict("id"=>5)
        dispatch(right)
        dispatch(refresh)
        first_effect = dispatch(left)
        @test !isnothing(first_effect.producer)
        dispatch(refresh)
        obs = rec.observation
        view = scene(obs)
        context = TC.relation_context(obs)
        left_roles = filter(row->row.point == (9,11),view.candidates)
        checked = TC.object_effect_followup(agenda,obs,context,left_roles;view.groups)
        @test !isnothing(checked) && checked.candidate.point == (9,11)
        proposal = (;action=left,intent=:test_concrete_effect,checked.tests,reads=String[],
            obligation=checked.purpose)
        measured = dispatch(left,proposal)
        @test measured.feedback.result == :established
        @test !isempty(agenda.checked_effects)
        dispatch(refresh)
        dispatch(refresh)

        obs = rec.observation
        view = scene(obs)
        context = TC.relation_context(obs)
        left_roles = filter(row->row.point == (9,11),view.candidates)
        @test isnothing(TC.object_effect_followup(agenda,obs,context,left_roles;view.groups))
        ranked = [(;action,rank=(0,0)) for action in (refresh,left,right)]
        attempts = Dict{TC.PublicActionKey,Int}()
        count = length(agenda.samples)
        choice = TC.choose_intervention(memory,view.candidates,obs,ranked,attempts;
            explore=true,goal_learning=true,confirmed_count=count,agenda,view.groups)
        @test choice.action == right && choice.reason == "extend_observed_object_effect"
        decision = (;ranked,view.groups)
        experiment = TC.relation_experiment(agenda,obs,decision,choice,context)
        @test experiment.intent == :test_concrete_effect && experiment.obligation == choice.effect_experiment
        baseline = (;action=left,reason="published_joint_effects")
        final = TC.task_arbitration(baseline,nothing,choice,experiment,nothing;
            program=false,continuing_contact=false,conditional=false,object_probes=true)
        @test final.choice.action == right && final.choice.source == :relation
        won = dispatch(final.choice.action,experiment,choice)
        @test rec.observation.state == "WIN" && won.public_outcome.result == :win
        @test close_scorecard!(rec)["completion"] == "confirmed"
        @test last(recover_run(store)).event["event_id"] == won.event
        TC.atomic_json(TC.store_path(store,"effect-scope-exploration.json"),(;
            measured=measured.event,selected=won.event,purpose=experiment.obligation))
    end
end
