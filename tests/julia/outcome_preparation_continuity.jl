using Test, TddESCat
const TC=TddESCat

@testset "An ordinary goal checks each retained role across intermediate receipt frames" begin
    function exercise(rewrite,interrupted)
        agenda=TC.RelationAgenda()
        base=zeros(UInt8,24,24)
        base[3:4,4:5] .= 2
        base[12:13,14:15] .= 3
        entries=Any[]
        function entry(name,before,id,frames,level)
            observation=TC.PublicObservation("continuity","session",frames,"NOT_FINISHED",level,3,Dict("id"=>id),[1,2,3],false)
            return (;event=Dict("event_id"=>name,"before_ref"=>before),observation)
        end
        function reset(label,level=0)
            TC.begin_relation_attempt!(agenda,nothing)
            push!(entries,entry("reset-$label",nothing,0,[copy(base)],level))
        end
        function apply(label,id;advance=false,blink=false,proposal=nothing)
            before=last(entries)
            frame=copy(last(before.observation.frames))
            if id==1
                frame[3:4,4:5].=7
            elseif id==2
                if rewrite
                    frame[3:4,4:5].=8
                else
                    frame[12:13,14:15].=8
                end
            end
            frames=[frame]
            if blink
                hidden=copy(frame)
                hidden[3:4,4:5].=2
                pushfirst!(frames,hidden)
            end
            after=entry(label,before.event["event_id"],id,frames,before.observation.levels_completed+advance)
            push!(entries,after)
            task=TC.bind_relation_reads(agenda,proposal,before.observation,Dict("id"=>id))
            changed=TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),nothing,NamedTuple[],task)
            TC.finish_relation_dispatch!(agenda,task;feedback=changed.feedback)
            return changed
        end
        if rewrite
            reset("source")
            apply("without-chain",3)
        else
            reset("only-a")
            apply("a-alone",1)
            apply("without-b",3)
            reset("only-b")
            apply("b-alone",2)
            apply("without-a",3)
            reset("source")
        end
        apply("source-a",1)
        apply("source-b",2)
        apply("source-goal",3;advance=true)
        @test length(last(agenda.outcome_relations).steps)==2
        reset("live",1)
        function choose()
            obs=last(entries).observation
            decision=(;ranked=[(action=Dict("id"=>id),rank=(i,0),reason="candidate") for (i,id) in enumerate((3,2,1))],
                groups=TC.public_components(last(obs.frames)))
            return TC.relation_experiment(agenda,obs,decision,nothing,TC.relation_context(obs))
        end
        a=choose()
        @test !isnothing(a) && a.intent==:establish_outcome_relation && a.action["id"]==1
        apply("live-a",1;proposal=a)
        b=choose()
        @test !isnothing(b) && b.intent==:continue_outcome_preparation && b.action["id"]==2
        @test only(b.obligation.role_reads).writer=="live-a"
        info=apply("live-b",2;blink=interrupted,proposal=b)
        @test info.feedback.result==:established
        target=choose()
        if interrupted
            @test any(f->f.writer_event=="live-a" && f.status==:unknown,info.fact_flow.invalidated)
            @test isnothing(target) || target.intent!=:continue_outcome_relation
        else
            @test !isnothing(target) && target.intent==:continue_outcome_relation
            @test getproperty.(target.obligation.role_reads,:writer)==(rewrite ? ["live-b"] : ["live-a","live-b"])
            goal=apply("live-goal",3;advance=true,proposal=target)
            @test getproperty.(filter(f->f.usage==:outcome_preparation_read,goal.fact_flow.inputs),:writer_event)==
                getproperty.(target.obligation.role_reads,:writer)
        end
    end
    exercise(false,false)
    exercise(false,true)
    exercise(true,false)
end
