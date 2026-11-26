using Test, TddESCat

const TC = TddESCat
config = load_run_config(first(ARGS))

@testset "An unobserved response becomes a confirmed result under the live history" begin
    with_run(last(ARGS)) do store
        rec = Recorder(store,config)
        agenda = TC.RelationAgenda()
        widths = config.search["history_lengths"]
        receipt_scope = maximum(widths) == 1
        search = TC.PublicFrontier(widths)
        @test open_scorecard!(rec)["completion"] == "confirmed"
        entry() = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),
            observation=rec.observation)
        function dispatch(id;prediction=nothing,proposal=nothing)
            before = entry()
            @test submit_action!(rec,id;prediction)["completion"] == "confirmed"
            after = entry()
            TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),nothing,NamedTuple[],proposal)
            TC.frontier_observe!(search,agenda)
        end
        for (preparation,tail) in ((1,2),(1,7),(4,7),(4,0))
            @test reset!(rec,config.environment["game_id"])["completion"] == "confirmed"
            TC.begin_relation_attempt!(agenda,nothing)
            dispatch(preparation)
            dispatch(5)
            tail == 0 || dispatch(tail)
        end
        obs = rec.observation
        context = TC.relation_context(obs)
        matrix = TC.frontier_response_matrix(search,agenda,context)
        key = TC.relation_history_key(agenda,context,agenda.previous)
        live = only(filter(row->row.history == key,matrix.rows))
        @test (matrix.width,matrix.receipts) == (receipt_scope ? (1,true) : (2,false))
        @test length(matrix.rows) == 2
        @test matrix.unrecorded_response == :unknown && all(cell->first(cell.action) != 2,live.cells)
        ranked = [(;action=Dict("id"=>id),reason="coverage",rank=(0,0)) for id in (7,2)]
        decision = (;ranked,groups=TC.public_components(last(obs.frames)))
        @test TC.relation_experiment(agenda,obs,decision,nothing,context) === nothing
        history_model = receipt_scope ? (;edges=Dict("2:-1:-1"=>1)) : nothing
        candidate = TC.relation_experiment(agenda,obs,decision,nothing,context;frontier=search,history_model)
        @test candidate.intent == :test_history_response && candidate.action == Dict("id"=>2)
        selected = TC.task_arbitration(first(ranked),nothing,nothing,candidate,nothing;
            program=false,continuing_contact=false,conditional=false,object_probes=false)
        @test selected.choice.action == candidate.action
        task = TC.relation_task_record(candidate)
        prediction = TC.relation_prediction(rec,candidate,nothing,task)
        @test prediction.payload["guard_truth"] == "unknown"
        dispatch(selected.choice.action["id"];prediction,proposal=candidate)
        @test rec.observation.state == "WIN"
        revised = TC.frontier_response_matrix(search,agenda,context)
        live = only(filter(row->row.history == key,revised.rows))
        established = only(filter(cell->first(cell.action) == 2,live.cells))
        @test established.status == :observed && only(established.outcomes)[2] == "WIN"
        TC.atomic_json(TC.store_path(store,"history-matrix.json"),(;matrix,revised,task,event=rec.before_ref))
        @test close_scorecard!(rec)["completion"] == "confirmed"
        @test last(recover_run(store)).event["event_id"] == rec.before_ref
    end
end
