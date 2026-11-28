using Test, TddESCat

const TC = TddESCat

function policy_frame(ref,previous,frames,action)
    obs = TC.PublicObservation("dependency","session",frames,"NOT_FINISHED",0,1,action,[1,2,3,4],false)
    return (;event=Dict("event_id"=>ref,"before_ref"=>previous),observation=obs)
end

@testset "A policy consumes a role across an independent public action" begin
    agenda, entries = TC.RelationAgenda(), Any[]
    for (attempt,suffix) in enumerate((3,4,3,4,3))
        attempt == 1 || TC.begin_relation_attempt!(agenda,nothing)
        frame = zeros(UInt8,64,64)
        # All commands remain legal in all five attempts.
        frame[11:13,9:11] .= 4
        frame[32:34,40:42] .= suffix
        frame[48:50,30:32] .= 5
        root = policy_frame("reset-$attempt",nothing,[frame],Dict("id"=>0))
        push!(entries,root)
        function apply(id,frames)
            before = last(entries)
            after = policy_frame("$attempt-$id",before.event["event_id"],frames,Dict("id"=>id))
            TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),nothing,NamedTuple[],nothing)
            push!(entries,after)
        end
        prep = copy(frame)
        prep[11:13,9:11] .= 7
        apply(1,[prep])
        noise = copy(prep)
        noise[48:50,30:32] .= 6
        if attempt == 5
            intermediate = copy(noise)
            intermediate[11:13,9:11] .= 8
            apply(2,[intermediate,noise])
        else
            apply(2,[noise])
        end
        changed = copy(noise)
        changed[11:13,9:11] .= 9 + suffix
        apply(suffix,[changed])
    end
    trace = TC.witnessed_relation_steps(agenda,entries)
    @test all(haskey(trace.links,(i,i+2)) for i in (1,4,7,10))
    @test !haskey(trace.links,(13,15))
    corpus = TC.policy_corpus(agenda,entries)
    @test !isnothing(corpus)
    gapped = filter(corpus.episodes) do episode
        length(episode.members)==2 && first(episode.members)+2==last(episode.members)
    end
    @test Set(e.structure for e in gapped) == Set(["sequence","branch"])
    @test Set(Tuple(e.members) for e in gapped if e.structure=="branch") == Set((i,i+2) for i in (1,4,7,10))
    @test all(e->TC.verify_relation_episode(e.body,e,agenda,entries),gapped)
    @test all(e->TC.relation_ref(agenda.samples[first(e.members)+1]) in e.events,gapped)
    source = first(gapped)
    ref = TC.relation_ref(agenda.samples[first(source.members)+1])
    index = findfirst(row->row.event["event_id"] == ref,entries)
    copy_entries = copy(entries)
    old = entries[index]
    intermediate = copy(last(old.observation.frames))
    intermediate[11:13,9:11] .= 8
    copy_entries[index] = policy_frame(ref,old.event["before_ref"],[intermediate,last(old.observation.frames)],
        old.observation.action)
    @test !TC.verify_relation_episode(source.body,source,agenda,copy_entries)

    # Re-check both choices directly after preparation, on a new placement of the
    # conditioned role. The nuisance action is never executed during these calls.
    branch = first(e.body for e in gapped if e.structure=="branch")
    policy = TC.LearnedPolicy("test","branch",1,"policy",Dict("tree"=>branch),String[],"")
    for id in (3,4)
        new = zeros(UInt8,64,64)
        new[21:23,17:19] .= 4
        new[32:34,40:42] .= id
        new[48:50,30:32] .= 5
        cursor = TC.RelationPolicyCursor(policy)
        @test TC.next_relation_instruction!(cursor,new).instruction.node["layout"]["id"] == 1
        new[21:23,17:19] .= 7
        step = TC.next_relation_instruction!(cursor,new)
        @test step.instruction.node["layout"]["id"] == id
        @test step.instruction.shared == [(1,1)]
    end
end

@testset "A concrete preparation can be tested while both public actions are legal" begin
    agenda, entries = TC.RelationAgenda(), Any[]
    base = zeros(UInt8,20,20)
    base[3:4,4:5] .= 2
    base[10:11,14:15] .= 5
    base[16:17,6:7] .= 3
    function restart(label)
        TC.begin_relation_attempt!(agenda,nothing)
        push!(entries,policy_frame("reset-$label",nothing,[copy(base)],Dict("id"=>0)))
    end
    function execute(ref,id,frame,proposal=nothing)
        before = last(entries)
        after = policy_frame(ref,before.event["event_id"],[frame],Dict("id"=>id))
        push!(entries,after)
        sample = TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),
            nothing,NamedTuple[],proposal)
        return sample,after
    end
    for i in 1:2
        restart("omission-$i")
        noise = copy(base)
        noise[16:17,6:7] .= 8
        execute("noise-unprepared-$i",3,noise)
        execute("omission-$i",2,noise)
        restart("source-$i")
        prepared = copy(base)
        prepared[3:4,4:5] .= 7
        execute("preparation-$i",1,prepared)
        distracted = copy(prepared)
        distracted[16:17,6:7] .= 8
        execute("noise-prepared-$i",3,distracted)
        response = copy(distracted)
        response[10:11,14:15] .= 6
        execute("target-$i",2,response)
    end
    corpus = TC.policy_corpus(agenda,entries)
    sources = filter(corpus.episodes) do e
        e.structure == "sequence" && [agenda.samples[i].effects.action["id"] for i in e.members]==[1,2]
    end
    @test length(sources) == 2
    e = first(sources)
    evidence = unique(reduce(vcat,[TC.observed_policy_preconditions(occ,agenda) for occ in sources]))
    @test all(input->input.comparison in ["omission-1","omission-2"],evidence)
    published = TC.LearnedPolicy("fixture","dependency",1,"policy",
        Dict("scope"=>"dependency","structure"=>"sequence","tree"=>e.body,"effect_preconditions"=>evidence),
        unique(reduce(vcat,[occ.events for occ in sources])),"target-2")
    decision(obs) = (ranked=[(action=Dict("id"=>id),) for id in (2,1,3,4)],
        groups=TC.public_components(last(obs.frames)))
    choose(obs,cursor=nothing) = TC.relation_policy_choice([published],cursor,Set(),agenda,obs,decision(obs))
    restart("live")
    prep = choose(last(entries).observation)
    @test prep.proposal.action["id"] == 1
    @test prep.proposal.obligation.purpose.kind == :test_policy_precondition
    prepared = copy(base)
    prepared[3:4,4:5] .= 7
    result,after = execute("live-preparation",1,prepared,prep.proposal)
    cursor = TC.confirm_relation_policy!(prep,agenda,result,after)
    @test cursor.result == :continue
    follow = choose(after.observation,cursor.cursor)
    @test follow.proposal.action["id"] == 2
    @test only(follow.proposal.tests).scope == :unverified
    read = only(follow.proposal.obligation.role_reads)
    @test read.writer=="live-preparation" && read.usage=="omission_contrast"
    # The local target contradicts the proposed program, even with its condition present.
    result,after = execute("refuted",2,prepared,follow.proposal)
    @test TC.confirm_relation_policy!(follow,agenda,result,after).result == :withdrawn
    restart("revised")
    @test isnothing(choose(last(entries).observation))
    @test !any(s->s.advanced,agenda.samples)
end

@testset "A witnessed repeat skips independent steps and checks its exit" begin
    agenda,entries = TC.RelationAgenda(),Any[]
    function record(id,frame,available;click=nothing,root=false)
        action = isnothing(click) ? Dict("id"=>id) : TC.click_action(click)
        previous = root ? nothing : last(entries)
        observation = TC.PublicObservation("repeat","session",[frame],"NOT_FINISHED",0,1,action,available,false)
        before = isnothing(previous) ? nothing : previous.event["event_id"]
        entry = (;observation,event=Dict("event_id"=>"repeat-$(length(entries)+1)","before_ref"=>before))
        if !isnothing(previous)
            TC.observe_relations!(agenda,previous,entry,TC.observed_effects(previous,entry),nothing,NamedTuple[],nothing)
        end
        push!(entries,entry)
    end
    for offset in (0,2)
        TC.begin_relation_attempt!(agenda,nothing)
        initial = zeros(UInt8,32,32)
        xs = (5+offset,15+offset)
        for x in xs
            initial[9:11,x:x+2] .= 4
        end
        initial[25:26,26:27] .= 2
        record(0,initial,[5,6];root=true)
        for (i,x) in enumerate(xs)
            prep = copy(last(last(entries).observation.frames))
            prep[9:11,x:x+2] .= 9
            record(6,prep,[5,7];click=(x,9))
            noise = copy(prep)
            noise[25:26,26:27] .= i == 1 ? 8 : 2
            record(5,noise,[5,7])
            done = copy(noise)
            done[9:11,x:x+2] .= 10
            record(7,done,i==1 ? [5,6] : [5])
        end
    end
    corpus = TC.policy_corpus(agenda,entries)
    @test !isnothing(corpus)
    loops = filter(corpus.episodes) do e
        e.structure=="repeat" && [agenda.samples[i].effects.action["id"] for i in e.members]==[6,7,6,7]
    end
    @test length(loops) >= 2
    @test all(e->TC.verify_relation_episode(e.body,e,agenda,entries),loops)
    @test all(e->length(e.evidence_only)==2 && e.body["layout"]["observed_bound"]==2,loops)
end

@testset "Dense evidence retains each pair without enumerating paths of one observation" begin
    n = 18
    observations = [(context=string(i),) for i in 1:2n]
    links = Dict((o+i,o+j)=>(layout=Dict("shared"=>[(1,1)]),reads=String[])
        for o in (0,n) for i in 1:n for j in i+1:n)
    followers = Dict(o+i=>collect(o+i+1:o+n) for o in (0,n) for i in 1:n)
    descriptors = Dict(o+i=>Dict("id"=>i) for o in (0,n) for i in 1:n)
    families = TC.source_policy_episodes((samples=observations,),(;descriptors,links,followers))
    pairs = [rows for group in values(families) for rows in group if length(rows)==2]
    @test length(pairs)==n*(n-1)
    @test [2,15] in pairs
    @test length(families) <= n*(n-1)
    @test all(length(group)==2 for group in values(families))
    @test all(row[3:end]==collect(row[2]+1:last(row)) for group in values(families) for row in group)
    # Every second instruction could skip any number of intervening repetitions.
    # Each occurrence and each distinguished episode is counted only once.
    members = [[i,i+1] for i in 1:2:2n]
    @test TC.repeated_policy_occurrences(followers,members)==[collect(1:n),collect(n+1:2n)]
end
