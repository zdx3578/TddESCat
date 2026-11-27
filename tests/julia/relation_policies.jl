using Test, TddESCat

const TC = TddESCat

@testset "Closed rectangles expand to exactly the supported incidence" begin
    vocabulary = ["shared","allied","adjacent","excluded"]
    incidence = Dict((i,attribute)=>TC.proven for i in 1:3 for attribute in vocabulary[1:3])
    incidence[(4,"shared")] = TC.proven
    incidence[(4,"adjacent")] = TC.disproven
    incidence[(5,"adjacent")] = TC.proven
    actual = TC.relational_factors(1:5,vocabulary,incidence,[1:3])
    rectangle = only(actual.factors)
    @test rectangle.extent == [1,2,3]
    @test rectangle.possible == [1,2,3,5]
    @test rectangle.intent == vocabulary[1:3]
    expanded = Set((i,attribute) for i in rectangle.extent for attribute in rectangle.intent)
    union!(expanded,actual.residual)
    @test expanded == Set(key for (key,value) in incidence if value == TC.proven)
    @test (5,"allied") ∉ expanded
end

function recorded_frame(ref,previous,frame,action,available)
    observation = TC.PublicObservation("relation-trial","relation-session",[frame],
        "NOT_FINISHED",0,1,action,available,false)
    return (event=Dict("event_id"=>ref,"before_ref"=>previous),observation=observation)
end

@testset "Two witnessed suffixes can share more than one preparation" begin
    agenda = TC.RelationAgenda()
    entries = Any[]
    for (attempt,final) in enumerate((3,4,3,4))
        attempt > 1 && TC.begin_relation_attempt!(agenda,nothing)
        frame = fill(0x00,64,64)
        frame[11:13,9:11] .= 0x04
        frame[40:41,44:45] .= final == 3 ? 0x03 : 0x05
        previous = recorded_frame("fork-reset-$attempt",nothing,frame,Dict("id"=>0),[1,2,3,4])
        push!(entries,previous)
        for (action,color) in zip((1,2,final),(0x07,0x08,UInt8(9+final)))
            changed = copy(last(previous.observation.frames))
            changed[11:13,9:11] .= color
            row = recorded_frame("fork-$attempt-$action",previous.event["event_id"],
                changed,Dict("id"=>action),[1,2,3,4])
            TC.observe_relations!(agenda,previous,row,TC.observed_effects(previous,row),
                nothing,NamedTuple[],nothing)
            push!(entries,row)
            previous = row
        end
    end
    corpus = TC.policy_corpus(agenda,entries)
    @test !isnothing(corpus)
    forks = filter(corpus.episodes) do episode
        body = episode.body
        episode.structure == "branch" && body["kind"] == "RelationSequence" &&
            body["children"][2]["kind"] == "RelationBranch"
    end
    @test length(forks) == 4
    @test all(episode->TC.verify_relation_episode(episode.body,episode,agenda,entries),forks)
    @test Set(last(agenda.samples[episode.members]).effects.action["id"] for episode in forks) == Set((3,4))
    for episode in forks
        prefix,branch = episode.body["children"]
        @test getindex.(getindex.(prefix["children"],"layout"),"id") == [1,2]
        @test all(!isempty,branch["layout"]["shared_by_branch"])
        cursor = TC.RelationPolicyCursor(TC.LearnedPolicy("","",0,"",
            Dict("tree"=>episode.body),String[],""))
        by_ref = Dict(row.event["event_id"]=>row.observation for row in entries)
        choices = [TC.next_relation_instruction!(cursor,by_ref[agenda.samples[index].effects.before_id])
            for index in episode.members]
        @test isempty(choices[1].branches) && isempty(choices[2].branches)
        @test only(choices[3].branches).control == :branch
        @test choices[3].instruction.node["layout"]["id"] ==
            agenda.samples[last(episode.members)].effects.action["id"]
    end
end

@testset "A new guard preserves a bound continuation" begin
    task(id) = TC.policy_expr("RelationTask";layout=Dict(
        "id"=>id,"role"=>nothing,"wait"=>true,"relations"=>[]))
    sequence(after) = TC.policy_expr("RelationSequence",task(5),task(after);
        layout=Dict("shared"=>[]))
    marker = Dict("kind"=>"color_present","value"=>3)
    guard = TC.policy_expr("RelationTest";layout=Dict("guard_schema"=>"public-atoms-v1",
        "guard"=>Dict("var"=>"color"),"atoms"=>Dict("color"=>marker)))
    branch = TC.policy_expr("RelationBranch",guard,sequence(7),sequence(4))
    policy(id,structure,tree) = TC.LearnedPolicy("artifact",id,1,"model",
        Dict("scope"=>id,"structure"=>structure,"tree"=>tree),["evidence-" * id],"published")
    serial = policy("serial","sequence",sequence(7))
    guarded = policy("guarded","branch",branch)
    available = [4,5,7]
    decision = (ranked=[(action=Dict("id"=>id),) for id in available],)
    matching = recorded_frame("matching",nothing,fill(0x03,4,4),Dict("id"=>0),available)
    absent = recorded_frame("absent",nothing,fill(0x00,4,4),Dict("id"=>0),available)
    agenda = TC.RelationAgenda()
    cursor = TC.RelationPolicyCursor(serial)
    picked = TC.relation_policy_choice([guarded],cursor,Set(),agenda,matching.observation,decision)
    @test picked.cursor.policy.definition == "guarded"
    @test only(picked.branches).outcome
    @test Set(picked.proposal.reads) == Set(["evidence-serial","evidence-guarded","published"])
    retained = TC.relation_policy_choice([guarded],cursor,Set(),agenda,absent.observation,decision)
    @test retained.cursor.policy.definition == "serial"
    @test cursor.pending == TC.RelationPolicyCursor(serial).pending
end

@testset "A synthesized branch reads the role established by the preparation" begin
    python = joinpath(@__DIR__,"..","..","python","compute",".venv","bin","python")
    if isfile(python)
        agenda,entries = TC.RelationAgenda(),Any[]
        function scene(selected=nothing;origins=(8,24),signals=(0x03,0x08))
            frame = fill(0x00,64,64)
            for (x,color) in zip(origins,signals)
                frame[11:13,x+1:x+3] .= x == selected ? 0x09 : 0x04
                frame[19:20,x+1:x+2] .= color
            end
            return frame
        end
        for (attempt,following) in enumerate((3,4,3,4))
            attempt > 1 && TC.begin_relation_attempt!(agenda,nothing)
            root = recorded_frame("typed-reset-$attempt",nothing,scene(),Dict("id"=>0),[3,4,6])
            x = following == 3 ? 8 : 24
            prepared = recorded_frame("typed-prep-$attempt",root.event["event_id"],scene(x),
                TC.click_action((x+1,11)),[3,4,6])
            finished = scene(x)
            finished[11:13,x+1:x+3] .= UInt8(8+following)
            closed = recorded_frame("typed-follow-$attempt",prepared.event["event_id"],finished,
                Dict("id"=>following),[3,4,6])
            for (before,after) in ((root,prepared),(prepared,closed))
                TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),
                    nothing,NamedTuple[],nothing)
            end
            append!(entries,[root,prepared,closed])
        end
        worker = TC.ComputeWorker(`$python -m tddesc_compute.worker`)
        try
            corpus = TC.policy_corpus(agenda,entries;solver=worker,snapshot="bound-branch")
            @test !isnothing(corpus)
            branches = filter(row->row.structure == "branch",corpus.episodes)
            @test length(branches) == 4
            @test all(row->TC.verify_relation_episode(row.body,row,agenda,entries),branches)
            body = first(branches).body
            @test body["kind"] == "RelationSequence"
            suffix = last(body["children"])
            atoms = first(suffix["children"])["layout"]["atoms"]
            @test any(atom->atom["kind"] == "relative_component_color",values(atoms))
            policy = TC.LearnedPolicy("verified","branch",1,"typed",Dict("tree"=>body),String[],"")
            for (signal,expected) in ((0x03,3),(0x08,4))
                origins = (16,40)
                initial = recorded_frame("new-entry",nothing,scene(;origins,signals=(0x03,signal)),
                    Dict("id"=>0),[3,4,6]).observation
                prepared = recorded_frame("new-prep","new-entry",scene(40;origins,signals=(0x03,signal)),
                    TC.click_action((41,11)),[3,4,6]).observation
                cursor = TC.RelationPolicyCursor(policy)
                @test TC.next_relation_instruction!(cursor,initial).instruction.node["layout"]["id"] == 6
                pending = copy(cursor.pending)
                @test TC.peek_relation_instruction(cursor,prepared).status == :unknown_guard
                @test cursor.pending == pending
                roles = TC.public_components(last(prepared.frames))
                cursor.outputs = [only(filter(role->first(role)[3] == 0x09,roles))]
                @test TC.next_relation_instruction!(cursor,prepared).instruction.node["layout"]["id"] == expected
            end
        finally
            close(worker)
        end
    end
end

@testset "A policy prerequisite checks actual availability beyond its local effect" begin
    agenda = TC.RelationAgenda()
    frame = fill(0x00,64,64)
    frame[12:14,10:12] .= 0x04
    initial = recorded_frame("permission-initial",nothing,frame,Dict("id"=>0),[1])
    prepared_frame = copy(frame)
    prepared_frame[12:14,10:12] .= 0x09
    prepared = recorded_frame("permission-granted",initial.event["event_id"],prepared_frame,Dict("id"=>1),[7])
    completed_frame = copy(prepared_frame)
    completed_frame[12:14,10:12] .= 0x08
    completed = recorded_frame("permission-consumed",prepared.event["event_id"],completed_frame,Dict("id"=>7),[1])
    first_effect = TC.observe_relations!(agenda,initial,prepared,TC.observed_effects(initial,prepared),
        nothing,NamedTuple[],nothing)
    second_effect = TC.observe_relations!(agenda,prepared,completed,TC.observed_effects(prepared,completed),
        nothing,NamedTuple[],nothing)
    first_step = TC.policy_expr("RelationTask";layout=TC.policy_step(agenda.samples[1],first_effect.producer.relations))
    second_step = TC.policy_expr("RelationTask";layout=TC.policy_step(agenda.samples[2],second_effect.producer.relations))
    program = TC.policy_expr("RelationSequence",first_step,second_step;layout=Dict("shared"=>[[1,1]]))
    policy = TC.LearnedPolicy("checked-publication","permission-program",1,"policy",
        Dict("tree"=>program,"structure"=>"sequence","scope"=>"permission-program"),
        [first_effect.event,second_effect.event],second_effect.event)
    TC.begin_relation_attempt!(agenda,nothing)
    restarted = recorded_frame("permission-restart",nothing,frame,Dict("id"=>0),[1])
    decision = (ranked=[(action=Dict("id"=>1),)],groups=TC.public_components(frame))
    choose() = TC.relation_policy_choice([policy],nothing,Set(),agenda,restarted.observation,decision)
    picked = choose()
    purpose = picked.proposal.obligation.purpose
    @test purpose.kind == :enable_policy_action && purpose.action == 7
    @test purpose.source == first_effect.event && purpose.consumer == second_effect.event
    @test all(in(picked.proposal.reads),(purpose.source,purpose.consumer))
    absent = recorded_frame("permission-missing",restarted.event["event_id"],prepared_frame,Dict("id"=>1),[1])
    feedback = TC.observe_relations!(agenda,restarted,absent,TC.observed_effects(restarted,absent),
        nothing,NamedTuple[],picked.proposal)
    @test feedback.feedback.result == :established
    checked = TC.confirm_relation_policy!(picked,agenda,feedback,absent)
    @test isnothing(checked.cursor) && checked.result == :withdrawn
    TC.begin_relation_attempt!(agenda,nothing)
    @test isnothing(choose())
end

@testset "Repeated relation tasks use a witnessed exit condition" begin
    agenda = TC.RelationAgenda()
    entries = Any[]
    for attempt in 1:2
        attempt > 1 && TC.begin_relation_attempt!(agenda,nothing)
        frame = fill(0x00,64,64)
        frame[13:15,11:13] .= 0x04
        frame[13:15,27:29] .= 0x04
        previous = recorded_frame("reset-$attempt",nothing,frame,Dict("id"=>0),[6])
        push!(entries,previous)
        for (index,x) in enumerate((10,26))
            painted = copy(last(previous.observation.frames))
            painted[13:15,x+1:x+3] .= 0x09
            applied = recorded_frame("click-$attempt-$index",previous.event["event_id"],painted,
                TC.click_action((x+1,13)),[7])
            TC.observe_relations!(agenda,previous,applied,TC.observed_effects(previous,applied),
                nothing,NamedTuple[],nothing)
            push!(entries,applied)
            resolved = copy(painted)
            resolved[13:15,x+1:x+3] .= 0x0a
            previous = recorded_frame("resolve-$attempt-$index",applied.event["event_id"],resolved,
                Dict("id"=>7),index == 1 ? [6] : [5])
            TC.observe_relations!(agenda,applied,previous,TC.observed_effects(applied,previous),
                nothing,NamedTuple[],nothing)
            push!(entries,previous)
        end
    end
    corpus = TC.policy_corpus(agenda,entries)
    @test !isnothing(corpus)
    repetitions = filter(row->row.structure == "repeat",corpus.episodes)
    @test length(repetitions) >= 2
    @test all(row->row.body["layout"]["observed_bound"] == 2,repetitions)
    @test all(row->TC.verify_relation_episode(row.body,row,agenda,entries),repetitions)
    registry,_ = TC.registry_from(corpus.signature,[])
    for (program,episode) in zip(corpus.programs,corpus.episodes)
        parsed = TC.decode_program(program,registry)
        @test TC.analyze_policy_body(parsed,registry).tree == episode.body
    end
    cutoff = length(agenda.samples)
    reads = TC.trajectory_reads(corpus,agenda)
    @test !isempty(reads)
    TC.begin_relation_attempt!(agenda,nothing)
    reset_frame = entries[1].observation.frames[end]
    reset = recorded_frame("new-reset",nothing,reset_frame,Dict("id"=>0),[6])
    ignored = recorded_frame("unrelated-click","new-reset",reset_frame,TC.click_action((0,0)),[6])
    TC.observe_relations!(agenda,reset,ignored,TC.observed_effects(reset,ignored),
        nothing,NamedTuple[],nothing)
    @test isempty(TC.trajectory_counterexamples(reads,cutoff,agenda))
    TC.begin_relation_attempt!(agenda,nothing)
    reset = recorded_frame("next-reset",nothing,reset_frame,Dict("id"=>0),[6])
    failed = recorded_frame("changed-response","next-reset",reset_frame,entries[2].observation.action,[6])
    TC.observe_relations!(agenda,reset,failed,TC.observed_effects(reset,failed),
        nothing,NamedTuple[],nothing)
    @test TC.trajectory_counterexamples(reads,cutoff,agenda) == ["changed-response"]

    python = joinpath(@__DIR__,"..","..","python","compute",".venv","bin","python")
    if isfile(python)
        worker = TC.ComputeWorker(`$python -m tddesc_compute.worker`)
        try
            compiled = TC.policy_corpus(agenda,entries;solver=worker,snapshot="fixture")
            @test !isnothing(compiled)
            typed_repeats = filter(row->row.structure == "repeat",compiled.episodes)
            @test length(typed_repeats) >= 2
            @test all(row->first(row.body["children"])["layout"]["synthesis"] == "cvc5",typed_repeats)
            @test all(row->first(row.body["children"])["layout"]["validation"] == "held_out",typed_repeats)
            @test all(row->TC.verify_relation_episode(row.body,row,agenda,entries),typed_repeats)
            positive = TC.policy_scene_atoms(entries[1].observation)
            negative = TC.policy_scene_atoms(entries[5].observation)
            @test TC.typed_policy_guard(worker,[positive,negative],[negative,negative],"withheld-conflict") === nothing
        finally
            close(worker)
        end
    end
end
