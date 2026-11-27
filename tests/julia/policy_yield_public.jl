using Test, TddESCat

const TC = TddESCat
const CONFIG = load_run_config(first(ARGS))

@testset "A confirmed policy ending yields a dispatch to the experiment agenda" begin
    with_run(last(ARGS)) do store
        rec = Recorder(store,CONFIG)
        agenda = TC.RelationAgenda()
        @test open_scorecard!(rec)["completion"] == "confirmed"
        @test reset!(rec,CONFIG.environment["game_id"])["completion"] == "confirmed"
        entry() = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),
            observation=rec.observation)
        function dispatch(id,selection=nothing)
            before = entry()
            @test submit_action!(rec,id)["completion"] == "confirmed"
            after = entry()
            proposal = isnothing(selection) ? nothing : selection.proposal
            observed = TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),
                nothing,NamedTuple[],proposal)
            return (;observed,after)
        end
        source = dispatch(2)
        layout = TC.policy_step(last(agenda.samples),String[])
        @test layout["wait"]
        learned = TC.LearnedPolicy("fixture-publication","fixture-policy",1,"confirmed-wait",
            Dict("scope"=>"confirmed-wait","structure"=>"sequence",
                "tree"=>TC.policy_expr("RelationTask";layout)),[source.observed.event],source.observed.event)
        obs = rec.observation
        ranked = [(;action=Dict("id"=>id),reason="uncovered",rank=(0,0)) for id in obs.available_actions]
        decision = (;ranked,groups=TC.public_components(last(obs.frames)))
        attempted = Set{Tuple{String,String}}()
        @test isnothing(TC.relation_policy_choice([learned],nothing,attempted,agenda,obs,decision))
        preferred = (;action=Dict("id"=>2))
        relation = TC.relation_experiment(agenda,obs,decision,preferred,TC.relation_context(obs))
        @test relation.intent == :test_delayed_effect && relation.action == preferred.action
        attempt = TC.relation_policy_choice([learned],nothing,attempted,agenda,obs,decision;relation)
        @test attempt.proposal.action == Dict("id"=>2)
        @test attempt.cursor.purpose.comparison == :test_delayed_effect
        actual = dispatch(2,attempt)
        finished = TC.confirm_relation_policy!(attempt,agenda,actual.observed,actual.after)
        @test finished.result == :stopped && isnothing(finished.cursor)
        @test finished.experiment_after == actual.observed.event

        item = first(ranked)
        experiment = (;action=Dict("id"=>1))
        select(;policy_yield=false,continuing_policy=false) = TC.task_arbitration(
            item,nothing,nothing,nothing,experiment;
            program=false,continuing_contact=false,conditional=false,object_probes=false,
            policy=attempt.proposal,policy_yield,continuing_policy)
        baseline = select().choice
        @test baseline.source == :relation_policy && baseline.action == Dict("id"=>2)
        continued = select(policy_yield=true,continuing_policy=true).choice
        @test continued.source == :relation_policy
        winner = select(policy_yield=!isnothing(finished.experiment_after)).choice
        @test winner.source == :experiment && winner.action == Dict("id"=>1)
        result = dispatch(winner.action["id"])
        @test rec.observation.state == "WIN"
        @test close_scorecard!(rec)["completion"] == "confirmed"
        TC.atomic_json(TC.store_path(store,"policy-yield.json"),
            (;closed=actual.observed.event,won=result.observed.event,
                yield_source=finished.experiment_after,baseline=baseline.action))
        @test last(recover_run(store)).event["event_id"] == result.observed.event
    end
end
