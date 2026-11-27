using Test, TddESCat

const TC = TddESCat
const CONFIG = load_run_config(first(ARGS))
const MODE = length(ARGS) == 3 ? ARGS[2] : "role-outcome"
const REBOUND_EFFECT = MODE == "outcome-role-equivalence"
const FAILED_COMPARISON = MODE == "outcome-failure-contrast"
const CLICK_TARGET = MODE == "role-outcome" || FAILED_COMPARISON

@testset "A witnessed visual prerequisite controls a new outcome instance" begin
    with_run(last(ARGS)) do store
        rec = Recorder(store,CONFIG)
        agenda = TC.RelationAgenda()
        @test open_scorecard!(rec)["completion"] == "confirmed"
        @test reset!(rec,CONFIG.environment["game_id"])["completion"] == "confirmed"
        entry() = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),
            observation=rec.observation)
        function dispatch(action;proposal=nothing,task=nothing)
            before = entry()
            prediction = isnothing(task) ? nothing : TC.relation_prediction(rec,proposal,nothing,task)
            options = action["id"] == 6 ? (x=action["x"],y=action["y"]) : (;)
            @test submit_action!(rec,action["id"];prediction,options...)["completion"] == "confirmed"
            after = entry()
            result = TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),
                nothing,NamedTuple[],proposal)
            TC.finish_relation_dispatch!(agenda,proposal;feedback=result.feedback)
            return result
        end
        function reopen()
            TC.begin_relation_attempt!(agenda,nothing)
            @test reset!(rec,CONFIG.environment["game_id"])["completion"] == "confirmed"
        end
        target = CLICK_TARGET ? TC.click_action((9,11)) : Dict("id"=>(REBOUND_EFFECT ? 5 : 2))
        comparison = dispatch(target)
        @test rec.observation.levels_completed == 0
        if FAILED_COMPARISON
            @test comparison.public_outcome.result == :failure
            reopen()
        end
        initial_action = REBOUND_EFFECT ? TC.click_action((9,11)) : Dict("id"=>5)
        preparation = dispatch(initial_action)
        second_source = MODE == "outcome-relation-chain" ? dispatch(Dict("id"=>7)) : nothing
        progress = dispatch(target)
        @test rec.observation.levels_completed == 1
        @test progress.public_outcome.relationship.comparison == comparison.event
        @test progress.public_outcome.relationship.preparation == preparation.event
        omitted_live = nothing
        rebound = CLICK_TARGET ? TC.click_action((39,11)) : target
        if FAILED_COMPARISON
            failed = dispatch(rebound)
            @test failed.public_outcome.result == :failure
            omitted_live = failed.event
            reopen()
            if rec.observation.levels_completed == 0
                dispatch(initial_action)
                @test dispatch(target).reached.advanced
            end
            @test rec.observation.levels_completed == 1
            @test TC.observed_failure(agenda,TC.relation_context(rec.observation),
                TC.action_key(rebound),agenda.previous)
        end
        appearance_witnesses = String[]
        live_action = initial_action
        if REBOUND_EFFECT
            groups = TC.public_components(last(rec.observation.frames))
            roles = sort!(filter(shape->all(cell->cell[3] == 11,shape),groups);by=TC.anchor)
            @test length(roles) == 3
            actions = TC.click_action.(TC.component_probe.(roles))
            witnesses = dispatch.(actions[1:2])
            @test length(unique(row.producer.key for row in witnesses)) == 1
            @test first(witnesses).binding.appearance != preparation.binding.appearance
            @test first(witnesses).producer.relations == preparation.producer.relations
            append!(appearance_witnesses,getproperty.(witnesses,:event))
            live_action = last(actions)
        end
        function propose()
            obs = rec.observation
            view = TC.public_action_candidates(obs,512;object_probes=true)
            candidates = sort(view.actions;by=action->action["id"] != target["id"])
            ranked = [(;action,rank=(i,0),reason="ordinary_public_candidate") for (i,action) in enumerate(candidates)]
            decision = (;ranked,view.groups)
            proposal = TC.relation_experiment(agenda,obs,decision,nothing,TC.relation_context(obs))
            @test !isnothing(proposal)
            arbitration = TC.task_arbitration(first(ranked),nothing,nothing,proposal,nothing;
                program=false,continuing_contact=false,conditional=false,object_probes=true)
            @test arbitration.choice.source == :relation && arbitration.choice.action == proposal.action
            task = TC.relation_task_record(proposal)
            return (;proposal,task,baseline=first(ranked).action)
        end
        setup = propose()
        @test setup.proposal.intent == :establish_outcome_relation
        @test setup.proposal.action == live_action && setup.baseline["id"] == target["id"]
        if REBOUND_EFFECT
            proof = setup.task.obligation.role_equivalence
            @test proof.source == preparation.producer.key && proof.target != proof.source
            @test all(in(setup.task.reads),appearance_witnesses)
            @test only(setup.task.contracts).scope == :replicated
        end
        @test isnothing(agenda.preparing)
        effect = dispatch(setup.proposal.action;setup.proposal,setup.task)
        @test effect.feedback.result == :established && agenda.preparing.event == effect.event
        additional = nothing
        last_effect = effect
        if !isnothing(second_source)
            @test getproperty.(progress.public_outcome.relationship.chain,:event) ==
                [preparation.event,second_source.event]
            step = propose()
            @test step.proposal.intent == :continue_outcome_preparation
            @test step.proposal.action == Dict("id"=>7) && step.proposal.obligation.confirmed == [effect.event]
            last_effect = dispatch(step.proposal.action;step.proposal,step.task)
            @test last_effect.feedback.result == :established
            additional = (;step.task,effect=last_effect)
        end
        follow = propose()
        @test follow.proposal.intent == :continue_outcome_relation
        @test follow.proposal.action == rebound
        win = dispatch(follow.proposal.action;follow.proposal,follow.task)
        @test win.public_outcome.dependency == last_effect.event
        @test rec.observation.state == "WIN" && rec.observation.levels_completed == 2
        @test close_scorecard!(rec)["completion"] == "confirmed"
        TC.atomic_json(TC.store_path(store,MODE * ".json"),
            (;comparison,preparation,second_source,progress,setup=(;setup.task,setup.baseline,effect),
                additional,appearance_witnesses,omitted_live,follow=(;follow.task,win)))
        @test last(recover_run(store)).event["event_id"] == win.event
    end
end
