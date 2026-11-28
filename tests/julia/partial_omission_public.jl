using Test, TddESCat
const TC = TddESCat
const CONFIG = load_run_config(first(ARGS))

@testset "A real incomplete writer motivates a click and keeps the revealed ambiguity" begin
    with_run(last(ARGS)) do store
        rec,agenda = Recorder(store,CONFIG),TC.RelationAgenda()
        @test open_scorecard!(rec)["completion"]=="confirmed"
        function reopen()
            TC.begin_relation_attempt!(agenda,nothing)
            @test reset!(rec,CONFIG.environment["game_id"])["completion"]=="confirmed"
        end
        entry() = (;event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),
            observation=rec.observation)
        function dispatch(action;proposal=nothing)
            before = entry()
            prediction = isnothing(proposal) ? nothing :
                TC.relation_prediction(rec,proposal,nothing,TC.relation_task_record(proposal))
            options = action["id"]==6 ? (;x=action["x"],y=action["y"]) : (;)
            @test submit_action!(rec,action["id"];prediction,options...)["completion"]=="confirmed"
            after = entry()
            result = TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),
                nothing,NamedTuple[],proposal)
            TC.finish_relation_dispatch!(agenda,proposal;feedback=result.feedback)
            return result
        end
        reopen()
        prepare,click = Dict("id"=>1),TC.click_action((44,40))
        writer = dispatch(prepare)
        first_win = dispatch(click)
        @test first_win.public_outcome.result==:win
        reopen()
        obs = rec.observation
        groups = TC.public_components(last(obs.frames))
        # A cold coordinate list contains the primitive action only. The saved click is public and bindable.
        ranked = [(action=prepare,rank=(1,0),reason="ordinary_public_candidate")]
        proposal = TC.relation_experiment(agenda,obs,(;ranked,groups),nothing,TC.relation_context(obs))
        @test proposal.intent==:test_preparation_omission && !proposal.obligation.isolated
        arbitration = TC.task_arbitration(first(ranked),nothing,nothing,proposal,nothing;
            program=false,conditional=false,continuing_contact=false,object_probes=true)
        @test arbitration.choice.source==:relation && arbitration.choice.action==click
        selected = TC.bind_relation_reads(agenda,proposal,obs,click)
        task = TC.relation_task_record(selected)
        comparison = dispatch(click;proposal=selected)
        @test comparison.feedback.omission.status==:changed_to_no_effect
        dispatch(prepare)
        repeat = dispatch(click)
        @test repeat.public_outcome.result==:win && isnothing(repeat.public_outcome.relationship)
        @test close_scorecard!(rec)["completion"]=="confirmed"
        TC.atomic_json(TC.store_path(store,"partial-omission.json"),(;writer,first_win,task,comparison,repeat))
    end
end
