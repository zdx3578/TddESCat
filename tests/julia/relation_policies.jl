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
            @test all(row->TC.verify_relation_episode(row.body,row,agenda,entries),typed_repeats)
        finally
            close(worker)
        end
    end
end
