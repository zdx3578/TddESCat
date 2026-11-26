using Test, TddESCat

const TC = TddESCat
const CONFIG = load_run_config(first(ARGS))
const MODE = length(ARGS) == 3 ? ARGS[2] : "role-outcome"

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
        target = MODE == "primitive-outcome" ? Dict("id"=>2) : TC.click_action((9,11))
        comparison = dispatch(target)
        @test rec.observation.levels_completed == 0
        preparation = dispatch(Dict("id"=>5))
        progress = dispatch(target)
        @test rec.observation.levels_completed == 1
        @test progress.public_outcome.relationship.comparison == comparison.event
        @test progress.public_outcome.relationship.preparation == preparation.event
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
        @test setup.proposal.action == Dict("id"=>5) && setup.baseline["id"] == target["id"]
        @test isnothing(agenda.preparing)
        effect = dispatch(setup.proposal.action;setup.proposal,setup.task)
        @test effect.feedback.result == :established && agenda.preparing.event == effect.event
        follow = propose()
        @test follow.proposal.intent == :continue_outcome_relation
        rebound = MODE == "primitive-outcome" ? target : TC.click_action((39,11))
        @test follow.proposal.action == rebound
        win = dispatch(follow.proposal.action;follow.proposal,follow.task)
        @test win.public_outcome.dependency == effect.event
        @test rec.observation.state == "WIN" && rec.observation.levels_completed == 2
        @test close_scorecard!(rec)["completion"] == "confirmed"
        TC.atomic_json(TC.store_path(store,MODE * ".json"),
            (;comparison,preparation,progress,setup=(;setup.task,setup.baseline,effect),follow=(;follow.task,win)))
        @test last(recover_run(store)).event["event_id"] == win.event
    end
end
