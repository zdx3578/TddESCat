using Test, TddESCat

const TC = TddESCat
const CONFIG = load_run_config(ARGS[1])
const MODE = ARGS[2]

@testset "A learned policy checks its public outcome after the confirmed preparation" begin
    with_run(ARGS[3]) do store
        rec = Recorder(store,CONFIG)
        agenda, knowledge = TC.RelationAgenda(), TC.OnlineKnowledge()
        @test open_scorecard!(rec)["completion"] == "confirmed"
        @test reset!(rec,CONFIG.environment["game_id"])["completion"] == "confirmed"
        entry() = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),
            observation=rec.observation)
        entries = [entry()]
        TC.register_evidence_obligation!(store,first(entries))

        function dispatch(action,selection=nothing)
            before = last(entries)
            proposal = isnothing(selection) ? nothing : selection.proposal
            task = isnothing(proposal) ? nothing : TC.relation_task_record(proposal)
            prediction = isnothing(task) ? nothing : TC.relation_prediction(rec,proposal,nothing,task)
            kwargs = action["id"] == 6 ? (x=action["x"],y=action["y"]) : (;)
            @test submit_action!(rec,action["id"];prediction,kwargs...)["completion"] == "confirmed"
            after = entry()
            push!(entries,after)
            TC.register_evidence_obligation!(store,after)
            observed = TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),
                nothing,NamedTuple[],proposal)
            TC.finish_relation_dispatch!(agenda,proposal;feedback=observed.feedback)
            policy = isnothing(selection) ? nothing : TC.confirm_relation_policy!(selection,agenda,observed,after)
            return (;observed,policy,prediction,after)
        end

        preparation = Dict("id"=>5)
        for (level,x) in enumerate((9,39))
            target = TC.click_action((x,11))
            omitted = dispatch(target)
            @test omitted.after.observation.levels_completed == level-1
            applied = dispatch(preparation)
            @test !applied.observed.reached.advanced
            advanced = dispatch(target)
            @test advanced.after.observation.levels_completed == level
            @test !isnothing(advanced.observed.public_outcome.relationship)
        end
        training_outcomes = [row.event for row in agenda.outcomes if row.result == :advancement]
        @test length(training_outcomes) == 2
        job = TC.prepare_policy_learning!(knowledge,CONFIG,store,ARGS[4],agenda;entries)
        @test !isnothing(job)
        @test any(episode->last(episode.members) == last(agenda.outcomes).index,job.corpus.episodes)
        status = TC.wait_worker(job.job,TC.store_path(store))
        learned = TC.collect_policy_learning!(knowledge,store,job,status;
            available_after=rec.before_ref,live_agenda=agenda)
        @test learned["result"] == "published"

        basis = Dict("id"=>1)
        dispatch(basis)
        dispatch(preparation)
        dispatch(Dict("id"=>7))
        dispatch(basis)
        target = TC.click_action((24,11))
        attempted = Set{Tuple{String,String}}()
        function choose(cursor=nothing)
            obs = rec.observation
            ranked = [(;action) for action in (preparation,target)]
            decision = (;ranked,groups=TC.public_components(last(obs.frames)))
            return TC.relation_policy_choice(knowledge.policies,cursor,attempted,agenda,obs,decision)
        end

        selected = choose()
        @test !isnothing(selected) && selected.proposal.action == preparation
        prepared_dispatch = dispatch(selected.proposal.action,selected)
        @test prepared_dispatch.observed.feedback.result == :established && prepared_dispatch.policy.result == :continue
        next = choose(prepared_dispatch.policy.cursor)
        @test !isnothing(next) && next.proposal.action == target
        obligation = next.proposal.obligation
        @test obligation.public_outcome == "advancement" && obligation.scope == :hypothesis
        @test obligation.preparation == prepared_dispatch.observed.event && obligation.outcome in training_outcomes
        result = dispatch(next.proposal.action,next)
        @test result.prediction.payload["guard_truth"] == "unknown"
        @test !haskey(result.prediction.payload["predicted_values"],"public_advancement")
        successful = MODE == "outcome-policy"
        @test rec.observation.state == (successful ? "WIN" : "GAME_OVER")
        @test result.policy.result == (successful ? :stopped_at_public_advance : :withdrawn)
        @test result.observed.feedback.result == (successful ? :established : :refuted)
        @test isnothing(result.policy.cursor)
        @test close_scorecard!(rec)["completion"] == "confirmed"
        @test last(recover_run(store)).event["event_id"] == result.observed.event
        TC.atomic_json(TC.store_path(store,"outcome-policy.json"),(;
            event=result.observed.event,training_outcomes,obligation,publication=learned["publication"],
            prediction=result.prediction.payload,policy=result.policy.result))
    end
end
