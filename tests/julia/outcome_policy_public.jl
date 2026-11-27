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

        if MODE == "outcome-availability-policy"
            training = NamedTuple[]
            for (level,x) in enumerate((9,39))
                before = last(entries).observation
                granted = dispatch(Dict("id"=>5))
                @test isnothing(granted.observed.producer)
                @test last(before.frames) == last(granted.after.observation.frames)
                @test granted.after.observation.available_actions == [6]
                advanced = dispatch(TC.click_action((x,11)))
                @test advanced.after.observation.levels_completed == level
                @test only(advanced.observed.public_outcome.requirements).event == granted.observed.event
                push!(training,(preparation=granted.observed.event,outcome=advanced.observed.event))
            end
            job = TC.prepare_policy_learning!(knowledge,CONFIG,store,ARGS[4],agenda;entries)
            @test !isnothing(job)
            status = TC.wait_worker(job.job,TC.store_path(store))
            learned = TC.collect_policy_learning!(knowledge,store,job,status;
                available_after=rec.before_ref,live_agenda=agenda)
            @test learned["result"] == "published"
            function choose_available_policy(cursor=nothing)
                obs = rec.observation
                scene = TC.public_action_candidates(obs,512;object_probes=true)
                decision = (ranked=[(;action) for action in scene.actions],groups=scene.groups)
                return TC.relation_policy_choice(knowledge.policies,cursor,Set(),agenda,obs,decision)
            end
            selection = choose_available_policy()
            @test !isnothing(selection) && selection.proposal.action == Dict("id"=>5)
            @test selection.proposal.obligation.public_available == [6] && isempty(selection.proposal.tests)
            purpose = selection.proposal.obligation.purpose
            @test purpose.kind == :enable_policy_action && purpose.action == 6
            preparation = dispatch(selection.proposal.action,selection)
            @test preparation.observed.feedback.result == :established
            @test preparation.policy.result == :continue
            next = choose_available_policy(preparation.policy.cursor)
            @test !isnothing(next) && next.proposal.action == TC.click_action((24,11))
            @test next.proposal.obligation.public_outcome == "advancement"
            result = dispatch(next.proposal.action,next)
            @test result.policy.result == :stopped_at_public_advance
            @test rec.observation.state == "WIN" && close_scorecard!(rec)["completion"] == "confirmed"
            @test last(recover_run(store)).event["event_id"] == result.observed.event
            TC.atomic_json(TC.store_path(store,MODE * ".json"),(;
                training,live=(preparation=preparation.observed.event,outcome=result.observed.event),
                purpose,publication=learned["publication"],prediction=result.prediction.payload))
            return
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
        idle,restore,clear = Dict("id"=>1),Dict("id"=>7),Dict("id"=>2)
        for _ in 1:2
            dispatch(idle)
            dispatch(restore)
        end
        dispatch(preparation)
        dispatch(clear)
        dispatch(restore)
        job = TC.prepare_policy_learning!(knowledge,CONFIG,store,ARGS[4],agenda;entries)
        @test !isnothing(job)
        @test any(episode->last(episode.members) == last(agenda.outcomes).index,job.corpus.episodes)
        status = TC.wait_worker(job.job,TC.store_path(store))
        learned = TC.collect_policy_learning!(knowledge,store,job,status;
            available_after=rec.before_ref,live_agenda=agenda)
        @test learned["result"] == "published"

        target = TC.click_action((24,11))
        attempted = Set{Tuple{String,String}}()
        function scene()
            ranked = [(;action,reason="uncovered") for action in (idle,preparation,target)]
            return (;ranked,groups=TC.public_components(last(rec.observation.frames)))
        end
        choose(policies,cursor=nothing) = TC.relation_policy_choice(policies,cursor,attempted,
            agenda,rec.observation,scene())
        irrelevant = NamedTuple[]
        for policy in knowledge.policies
            isempty(policy.body["public_outcomes"]) || continue
            next = TC.peek_relation_instruction(TC.RelationPolicyCursor(policy),rec.observation)
            next.status == :task || continue
            bound = TC.bind_relation_instruction(next.cursor,next.instruction,rec.observation,scene(),agenda)
            isnothing(bound) || bound.action != idle || push!(irrelevant,(;policy,bound))
        end
        @test !isempty(irrelevant)
        unused = last(irrelevant)
        @test all(test->test.scope == :bound,unused.bound.tests)
        @test isnothing(choose([unused.policy]))
        policies = [filter(policy->!isempty(policy.body["public_outcomes"]),knowledge.policies);unused.policy]
        selected = choose(policies)

        @test !isnothing(selected) && selected.proposal.action == preparation
        purpose = selected.proposal.obligation.purpose
        @test purpose.kind == :establish_public_outcome && purpose.target == target
        @test purpose.outcome in training_outcomes && purpose.comparison in selected.proposal.reads
        arbitration = TC.task_arbitration(first(scene().ranked),nothing,nothing,nothing,nothing;
            program=false,continuing_contact=false,conditional=false,object_probes=true,policy=selected.proposal)
        @test arbitration.baseline.action == idle && arbitration.choice.action == preparation
        prepared_dispatch = dispatch(arbitration.choice.action,selected)
        @test prepared_dispatch.observed.feedback.result == :established && prepared_dispatch.policy.result == :continue
        next = choose(policies,prepared_dispatch.policy.cursor)
        @test !isnothing(next) && next.proposal.action == target
        obligation = next.proposal.obligation
        @test obligation.purpose == purpose
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
        replayed = [relation for relation in unused.policy.training if any(row->
            TC.relation_ref(row) == relation && row.effects.action["id"] in (1,7) && !row.unchanged,agenda.samples)]
        @test length(replayed) >= 2
        TC.atomic_json(TC.store_path(store,"outcome-policy.json"),(;
            event=result.observed.event,training_outcomes,obligation,publication=learned["publication"],
            prediction=result.prediction.payload,policy=result.policy.result,
            selection=(;purpose,ignored=(;action=unused.bound.action,replayed))))
    end
end
