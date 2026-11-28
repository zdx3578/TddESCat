using Test, TddESCat
const TC = TddESCat
const CONFIG = load_run_config(first(ARGS))

@testset "A first-level omission selected from confirmed public effects" begin
    with_run(last(ARGS)) do store
        rec = Recorder(store,CONFIG)
        agenda = TC.RelationAgenda()
        @test open_scorecard!(rec)["completion"] == "confirmed"
        @test reset!(rec,CONFIG.environment["game_id"])["completion"] == "confirmed"
        entry() = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),
            observation=rec.observation)
        function dispatch(id;proposal=nothing)
            before = entry()
            prediction = isnothing(proposal) ? nothing :
                TC.relation_prediction(rec,proposal,nothing,TC.relation_task_record(proposal))
            @test submit_action!(rec,id;prediction)["completion"] == "confirmed"
            after = entry()
            result = TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),
                nothing,NamedTuple[],proposal)
            TC.finish_relation_dispatch!(agenda,proposal;feedback=result.feedback)
            return result
        end
        foreach(dispatch,(1,2,4,4,3))
        obs = rec.observation
        view = TC.public_action_candidates(obs,512;object_probes=true)
        ranked = [(;action,rank=(action["id"],0),reason="ordinary_public_candidate")
            for action in sort(view.actions;by=action->action["id"])]
        proposal = TC.relation_experiment(agenda,obs,(;ranked,view.groups),nothing,TC.relation_context(obs))
        arbitration = TC.task_arbitration(first(ranked),nothing,nothing,proposal,nothing;
            program=false,continuing_contact=false,conditional=false,object_probes=true)
        if length(ARGS)==3 && ARGS[2]=="--choice-only"
            selected = arbitration.choice.source == :relation ? proposal : nothing
            result = dispatch(arbitration.choice.action["id"];proposal=selected)
            @test close_scorecard!(rec)["completion"] == "confirmed"
            TC.atomic_json(TC.store_path(store,"choice.json"),(;arbitration.choice,
                intent=isnothing(selected) ? nothing : selected.intent,receipt=result.event))
            return
        end
        @test proposal.intent == :test_preparation_omission
        disjoint = (action=first(ranked).action,effect_experiment=(comparison=:distinguish_concrete_effects,),
            tests=[(expected=Dict("translation-2-2"=>(1,0)),),(expected=Dict("translation-5-5"=>(-1,0)),)])
        compatible = TC.relation_experiment(agenda,obs,(;ranked,view.groups),disjoint,TC.relation_context(obs))
        @test compatible.intent == proposal.intent && compatible.obligation == proposal.obligation
        @test arbitration.choice.source == :relation && arbitration.choice.action == Dict("id"=>2)
        selected = TC.bind_relation_reads(agenda,proposal,obs,arbitration.choice.action)
        task = TC.relation_task_record(selected)
        comparison = dispatch(arbitration.choice.action["id"];proposal=selected)
        @test comparison.feedback.omission.status == :changed_to_no_effect
        foreach(dispatch,(1,4,4))
        response = dispatch(2)
        edge = only(filter(e->e.usage==:omission_contrast,response.fact_flow.inputs))
        @test (edge.writer,edge.comparison,edge.through) == (7,6,9)
        @test obs.levels_completed == rec.observation.levels_completed == 0
        @test close_scorecard!(rec)["completion"] == "confirmed"
        TC.atomic_json(TC.store_path(store,"relation-use.json"),(;ordinary=first(ranked).action,
            task,comparison,response))
    end
end
