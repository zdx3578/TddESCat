using Test, TddESCat

const TC = TddESCat
const CONFIG = load_run_config(first(ARGS))

@testset "Role-conditioned CirKit scores change a confirmed experiment" begin
    with_run(last(ARGS)) do store
        rec = Recorder(store,CONFIG)
        agenda,memory = TC.RelationAgenda(),TC.ResponseLearning()
        @test open_scorecard!(rec)["completion"] == "confirmed"
        entry() = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),
            observation=rec.observation)
        function start_attempt()
            @test reset!(rec,CONFIG.environment["game_id"])["completion"] == "confirmed"
            TC.begin_relation_attempt!(agenda,nothing)
        end
        function dispatch(action;prediction=nothing,proposal=nothing)
            before = entry()
            options = action["id"] == 6 ? (x=action["x"],y=action["y"]) : (;)
            @test submit_action!(rec,action["id"];prediction,options...)["completion"] == "confirmed"
            after = entry()
            TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),
                nothing,NamedTuple[],proposal)
            TC.observe_response!(memory,agenda)
        end
        left,right = TC.click_action((9,11)),TC.click_action((39,11))
        for index in 1:30
            start_attempt()
            dispatch(index % 3 == 0 ? right : left)
        end
        @test memory.dimensions == (7,2,4) && length(memory.roles) == 2
        cut = rec.before_ref
        TC.with_compute(CONFIG) do workers
            TC.request_response_model!(memory,workers["circuit_python"],agenda,cut,8)
            wait(memory.job)
            TC.collect_response_model!(memory,store,agenda)
        end
        @test memory.scope == cut
        isnothing(memory.scope) && error("Role-conditioned model was not published")
        start_attempt()
        dispatch(Dict("id"=>7))
        dispatch(Dict("id"=>7))
        layout = Dict(role=>index-1 for (index,role) in enumerate(memory.roles))
        @test TC.response_encoding(agenda,last(agenda.samples),false,layout).values[2] === nothing
        obs = rec.observation
        groups = TC.public_components(last(obs.frames))
        context = TC.relation_context(obs)
        scores = TC.circuit_experiment_scores(memory,agenda)
        @test all(key->key isa Tuple && first(key) == 6,keys(scores)) && length(scores) == 2
        @test !haskey(scores,6)
        @test TC.experimental_response_score(scores,TC.click_action((0,0)),groups) == 0.0
        candidates = sort([left,right];by=action->TC.experimental_response_score(scores,action,groups))
        baseline,chosen = candidates
        @test TC.experimental_response_score(scores,baseline,groups) < TC.experimental_response_score(scores,chosen,groups)
        ranked = [(;action,rank=(i,0),reason="ordinary_public_candidate") for (i,action) in enumerate(candidates)]
        decision = (;ranked,groups)
        proposal = TC.relation_experiment(agenda,obs,decision,nothing,context;uncertainty=scores,circuit_ref=cut)
        @test proposal.action == chosen && proposal.obligation.baseline == baseline
        @test proposal.obligation.circuit == cut
        arbitration = TC.task_arbitration(first(ranked),nothing,nothing,proposal,nothing;
            program=false,continuing_contact=false,conditional=false,object_probes=true)
        @test arbitration.choice.action == chosen
        task = TC.relation_task_record(proposal)
        prediction = TC.relation_prediction(rec,proposal,nothing,task)
        dispatch(chosen;prediction,proposal)
        @test rec.observation.action == chosen
        @test close_scorecard!(rec)["completion"] == "confirmed"
        TC.atomic_json(TC.store_path(store,"circuit-role.json"),
            (;task,baseline,chosen,event=rec.before_ref,artifact=cut))
        @test last(recover_run(store)).event["event_id"] == rec.before_ref
    end
end
