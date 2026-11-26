using Test, TddESCat

const TC = TddESCat

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
end
