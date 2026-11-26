using Test, TddESCat

const TC = TddESCat
const CONFIG = load_run_config(first(ARGS))

@testset "A failed advancement transfer withdraws its unqualified scope" begin
    with_run(last(ARGS)) do store
        rec = Recorder(store,CONFIG)
        agenda = TC.RelationAgenda()
        @test open_scorecard!(rec)["completion"] == "confirmed"
        @test reset!(rec,CONFIG.environment["game_id"])["completion"] == "confirmed"
        entry() = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),
            observation=rec.observation)
        function dispatch(action,proposal=nothing)
            before = entry()
            options = action["id"] == 6 ? (x=action["x"],y=action["y"]) : (;)
            @test submit_action!(rec,action["id"];options...)["completion"] == "confirmed"
            after = entry()
            result = TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),
                nothing,NamedTuple[],proposal)
            TC.finish_relation_dispatch!(agenda,proposal;feedback=result.feedback)
            return result
        end

        prelude = TC.click_action((0,0))
        target = TC.click_action((39,11))
        alternative = Dict("id"=>5)
        dispatch(prelude)
        source = dispatch(TC.click_action((9,11)))
        @test rec.observation.levels_completed == 1
        dispatch(prelude)

        function propose()
            obs = rec.observation
            view = TC.public_action_candidates(obs,512;object_probes=true)
            ranked = [(;action,rank=(i,0),reason="ordinary_public_candidate")
                for (i,action) in enumerate((alternative,target))]
            decision = (;ranked,view.groups)
            candidate = TC.advancement_probe(agenda,obs,decision,TC.relation_context(obs))
            selected = TC.task_arbitration(first(ranked),nothing,nothing,candidate,nothing;
                program=false,continuing_contact=false,conditional=false,object_probes=true)
            return (;candidate,selected=selected.choice.action)
        end

        probe = propose()
        @test probe.candidate.obligation.source == source.event
        @test probe.candidate.obligation.scope == "new_instance" && probe.selected == target
        @test isempty(agenda.advancement_counterexamples)
        failed = dispatch(probe.selected,probe.candidate)
        @test failed.feedback.result == :refuted
        transfer = failed.feedback.withdrawn_transfer
        @test transfer.event == failed.event && transfer.scope == probe.candidate.obligation.transfer
        @test failed.after != failed.context
        @test !haskey(agenda.visits,(failed.after,TC.action_key(target)))

        revised = propose()
        @test isnothing(revised.candidate) && revised.selected == alternative
        won = dispatch(revised.selected)
        @test rec.observation.state == "WIN" && rec.observation.levels_completed == 2
        @test close_scorecard!(rec)["completion"] == "confirmed"
        TC.atomic_json(TC.store_path(store,"advancement-refutation.json"),
            (;source=source.event,failed=failed.event,won=won.event,transfer))
        @test last(recover_run(store)).event["event_id"] == won.event
    end
end
