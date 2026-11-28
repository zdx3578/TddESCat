using Test, TddESCat
const TC = TddESCat
const CONFIG = load_run_config(ARGS[1])

@testset "An outcome policy rebinds two independently contrasted preparations" begin
    with_run(ARGS[3]) do store
        rec = Recorder(store,CONFIG)
        agenda,knowledge = TC.RelationAgenda(),TC.OnlineKnowledge()
        @test open_scorecard!(rec)["completion"] == "confirmed"
        @test reset!(rec,CONFIG.environment["game_id"])["completion"] == "confirmed"
        entry() = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref*".json")),observation=rec.observation)
        entries = [entry()]
        TC.register_evidence_obligation!(store,first(entries))
        function apply(action,selection=nothing)
            before = last(entries)
            proposal = isnothing(selection) ? nothing : TC.bind_relation_reads(agenda,selection.proposal,before.observation,action)
            task = isnothing(proposal) ? nothing : TC.relation_task_record(proposal)
            prediction = isnothing(task) ? nothing : TC.relation_prediction(rec,proposal,nothing,task)
            xy = action["id"]==6 ? (x=action["x"],y=action["y"]) : (;)
            @test submit_action!(rec,action["id"];prediction,xy...)["completion"] == "confirmed"
            after = entry()
            push!(entries,after)
            TC.register_evidence_obligation!(store,after)
            receipt = TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),nothing,NamedTuple[],proposal)
            TC.finish_relation_dispatch!(agenda,proposal;feedback=receipt.feedback)
            result = isnothing(selection) ? nothing : TC.confirm_relation_policy!(selection,agenda,receipt,after)
            return (;receipt,result)
        end
        act(id) = Dict("id"=>id)
        training = NamedTuple[]
        for x in (9,39)
            target = TC.click_action((x,11))
            apply(act(5))
            without_second = apply(target).receipt
            apply(act(2))
            apply(act(7))
            without_first = apply(target).receipt
            apply(act(1))
            a = apply(act(5)).receipt
            b = apply(act(7)).receipt
            outcome = apply(target).receipt
            inputs = sort(filter(f->f.usage==:omission_contrast,TC.relation_inputs(agenda,length(agenda.samples)));by=f->f.writer)
            comparisons = TC.relation_ref.(agenda.samples[[f.comparison for f in inputs]])
            @test [f.writer_event for f in inputs] == [a.event,b.event]
            @test comparisons == [without_first.event,without_second.event]
            push!(training,(;outcome=outcome.event,comparisons))
        end
        job = TC.prepare_policy_learning!(knowledge,CONFIG,store,ARGS[4],agenda;entries)
        @test !isnothing(job)
        joint = filter(e->hasproperty(e,:preparations),job.corpus.episodes)
        @test length(joint)==2
        @test all(e->[agenda.samples[i].effects.action["id"] for i in e.members]==[5,7,6],joint)
        removed = deepcopy(agenda)
        empty!(removed.outcome_relations)
        @test all(e->!TC.verify_relation_episode(e.body,e,removed,entries),joint)
        status = TC.wait_worker(job.job,TC.store_path(store))
        learned = TC.collect_policy_learning!(knowledge,store,job,status;available_after=rec.before_ref,live_agenda=agenda)
        @test learned["result"] == "published"
        target = TC.click_action((24,11))
        function choose(cursor=nothing)
            scene = (;ranked=[(action=cmd,) for cmd in (target,act(5),act(7),act(2),act(1))],
                groups=TC.public_components(last(rec.observation.frames)))
            return TC.relation_policy_choice(knowledge.policies,cursor,Set(),agenda,rec.observation,scene)
        end
        first_step = choose()
        @test !isnothing(first_step) && first_step.proposal.action == act(5)
        @test only(first_step.proposal.tests).scope==:unverified
        first_result = apply(first_step.proposal.action,first_step)
        @test first_result.result.result == :continue
        second_step = choose(first_result.result.cursor)
        @test second_step.proposal.action == act(7)
        @test only(second_step.proposal.tests).scope==:unverified
        second_result = apply(second_step.proposal.action,second_step)
        @test second_result.result.result == :continue
        cursor = second_result.result.cursor
        target_step = choose(cursor)
        @test !isnothing(target_step) && target_step.proposal.action == target
        obligation = target_step.proposal.obligation
        @test obligation.scope == :hypothesis
        @test obligation.comparisons in [row.comparisons for row in training]
        reads = obligation.role_reads
        @test [r.writer for r in reads]==[first_result.receipt.event,second_result.receipt.event]
        @test all(r->r.usage=="omission_contrast" && r.port==1,reads)
        # Same pixels with an interrupted lineage must block dispatch.
        support = only(cursor.output_history[1])
        old = pop!(agenda.uses.roles,support)
        @test isnothing(choose(cursor))
        agenda.uses.roles[support] = old
        final = apply(target,target_step)
        @test final.result.result==:stopped_at_public_advance && rec.observation.state=="WIN"
        @test [f.writer_event for f in TC.relation_inputs(agenda,length(agenda.samples)) if f.usage==:policy_preparation_read] == getproperty.(reads,:writer)
        @test close_scorecard!(rec)["completion"]=="confirmed"
        TC.atomic_json(TC.store_path(store,"multi-preparation.json"),(;training,role_reads=reads,final=final.receipt.event))
    end
end
