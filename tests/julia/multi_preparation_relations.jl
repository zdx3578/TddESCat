using Test, TddESCat
const TC = TddESCat

@testset "Two contrasted roles are live inputs to a local information experiment" begin
    agenda,entries = TC.RelationAgenda(),Any[]
    function scene(ref,previous,frame,id)
        action = Dict("id"=>id)
        observation = TC.PublicObservation("preparations","session",[copy(frame)],"NOT_FINISHED",0,1,action,[1,2,3,4],false)
        return (;event=Dict("event_id"=>ref,"before_ref"=>previous),observation)
    end
    base = zeros(UInt8,24,24)
    base[2:3,3:4] .= 2
    base[7:8,12:13] .= 3
    base[16:17,5:6] .= 5
    function reset(label)
        TC.begin_relation_attempt!(agenda,nothing)
        push!(entries,scene("reset-$label",nothing,base,0))
    end
    function dispatch(label,id,selected=nothing;respond=true)
        before = last(entries)
        frame = copy(last(before.observation.frames))
        id == 1 && (frame[2:3,3:4].=7)
        id == 2 && (frame[7:8,12:13].=8)
        id == 3 && respond && (frame[16:17,5:6].=9)
        after = scene(label,before.event["event_id"],frame,id)
        push!(entries,after)
        proposal = isnothing(selected) ? nothing : TC.bind_relation_reads(agenda,selected.proposal,before.observation,Dict("id"=>id))
        info = TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),nothing,NamedTuple[],proposal)
        return isnothing(selected) ? info : TC.confirm_relation_policy!(selected,agenda,info,after)
    end
    reset("neither")
    dispatch("joint-omission",3;respond=false)
    reset("uncontrolled")
    dispatch("coincident-A",1)
    dispatch("coincident-B",2)
    dispatch("coincident-response",3)
    @test isempty(TC.policy_preparation_inputs(agenda,length(agenda.samples),()))
    for i in 1:2
        reset("A$i")
        dispatch("A-only-$i",1)
        dispatch("without-B-$i",3;respond=false)
        reset("B$i")
        dispatch("B-only-$i",2)
        dispatch("without-A-$i",3;respond=false)
        reset("both$i")
        dispatch("A-$i",1)
        dispatch("B-$i",2)
        dispatch("productive-$i",3)
    end
    corpus = TC.policy_corpus(agenda,entries)
    joined = filter(e->hasproperty(e,:preparations),corpus.episodes)
    @test length(joined) == 2
    @test all(e->TC.verify_relation_episode(e.body,e,agenda,entries),joined)
    swapped = deepcopy(first(joined).body)
    reverse!(swapped["layout"]["preparations"])
    @test !TC.verify_relation_episode(swapped,first(joined),agenda,entries)
    trials = [(;reader=last(e.members),event=TC.relation_ref(agenda.samples[last(e.members)]),
        inputs=e.preparations) for e in joined]
    body = Dict("tree"=>first(joined).body,"structure"=>"sequence","scope"=>"two-preparations","preparation_trials"=>trials)
    policy = TC.LearnedPolicy("fixture","relation",2,"policy",body,unique(reduce(vcat,[e.events for e in joined])),"productive-2")
    function choose(cursor=nothing)
        obs = last(entries).observation
        decision = (;ranked=[(action=Dict("id"=>i),) for i in (4,3,2,1)],groups=TC.public_components(last(obs.frames)))
        return TC.relation_policy_choice([policy],cursor,Set(),agenda,obs,decision)
    end
    reset("experiment")
    a = choose()
    @test a.proposal.action["id"]==1 && a.proposal.obligation.purpose.kind==:test_policy_precondition
    a_done = dispatch("live-A",1,a)
    b = choose(a_done.cursor)
    @test b.proposal.action["id"]==2
    b_done = dispatch("live-B",2,b)
    c = choose(b_done.cursor)
    @test c.proposal.action["id"]==3
    @test [read.writer for read in c.proposal.obligation.role_reads]==["live-A","live-B"]
    @test dispatch("live-target",3,c).result==:stopped
    @test [f.writer_event for f in TC.relation_inputs(agenda,length(agenda.samples)) if f.usage==:policy_preparation_read]==["live-A","live-B"]
    # A later, successful omission supersedes a claimed conjunction even at
    # identical pixels and prevents this information experiment restarting.
    reset("counter")
    dispatch("counter-A",1)
    dispatch("counter-response",3)
    reset("after-counter")
    @test isnothing(choose())
    @test all(e->!TC.verify_relation_episode(e.body,e,agenda,entries),joined)
end
