using Test, TddESCat
const T = TddESCat

function screen(frame,action;level=0,state="NOT_FINISHED")
    T.PublicObservation("public","session",[frame],state,level,4,action,[3,6],nothing)
end
entry(id,parent,obs) = (event=Dict("event_id"=>id,"before_ref"=>parent),observation=obs)
components(obs) = T.public_components(last(obs.frames))
click(x,y) = Dict("id"=>6,"x"=>x,"y"=>y)

function record!(agenda,before,after,proposal=nothing)
    effects = T.observed_effects(before,after)
    T.observe_relations!(agenda,before,after,effects,nothing,NamedTuple[],proposal;
        groups=components(before.observation),after_groups=components(after.observation))
end

function bars(width;offset=0,noise=false)
    frame = zeros(UInt8,28,40)
    frame[5:7,6+offset:5+offset+width] .= 3
    frame[19:21,3+offset:5+offset] .= 4
    noise && (frame[24,30]=7)
    return frame
end

@testset "A local boundary can be tested and refuted independently of unrelated pixels" begin
    agenda = T.RelationAgenda()
    action = click(3,19)
    base = entry("a",nothing,screen(bars(3),Dict("id"=>0)))
    first = entry("b","a",screen(bars(5;noise=true),action))
    learning = record!(agenda,base,first)
    @test !isempty(learning.transition_observations)
    @test !isempty(T.JSON.json(learning.transition_observations))
    obs = first.observation
    ranked = [(;action=Dict("id"=>3),rank=(1,0),reason="coverage")]
    decision = (;ranked,groups=components(obs))
    proposal = T.relation_experiment(agenda,obs,decision,nothing,T.relation_context(obs))
    @test proposal.intent==:test_endpoint_transform
    arb = T.task_arbitration(only(ranked),nothing,nothing,proposal,nothing;
        program=false,continuing_contact=false,conditional=false,object_probes=true)
    @test arb.choice.action==action && arb.choice.source==:relation
    task = T.relation_task_record(proposal)
    prediction = T.relation_prediction((;before_ref="b"),proposal,nothing,task)
    expected = only(values(prediction.payload["predicted_values"]))
    @test expected.box==(5,4,11,6)
    @test Set(prediction.payload["event_reads"])==Set(["a","b"])
    second = entry("c","b",screen(bars(7),action))
    @test record!(agenda,first,second,proposal).feedback.result==:established

    shifted = screen(bars(4;offset=4),action)
    shifted_action = click(7,19)
    transfer = T.bind_transition_trials(agenda,nothing,shifted,shifted_action,components(shifted))
    @test only(transfer.transitions).expected.box==(9,4,14,6)
    @test isnothing(T.bind_transition_trials(agenda,nothing,shifted,click(25,15),components(shifted)))
    # A no-op in the novel binding contradicts the proposed growth.
    wrong = entry("e","d",screen(bars(4;offset=4),shifted_action))
    negative = record!(agenda,entry("d",nothing,shifted),wrong,transfer)
    @test negative.feedback.result==:refuted
    @test isnothing(T.bind_transition_trials(agenda,nothing,shifted,shifted_action,components(shifted)))
    @test isnothing(T.bind_transition_trials(agenda,nothing,screen(bars(8),action),action,
        components(screen(bars(8),action))))
    @test !isnothing(T.bind_transition_trials(agenda,nothing,base.observation,action,components(base.observation)))

    # At the same input length, a different remote context can retain its own positive witness.
    other = screen(bars(4;offset=4,noise=true),shifted_action)
    good = entry("g","f",screen(bars(6;offset=4,noise=true),shifted_action))
    record!(agenda,entry("f",nothing,other),good)
    restricted = T.bind_transition_trials(agenda,nothing,other,shifted_action,components(other))
    @test only(restricted.transitions).scope == :observed_context
    @test Set(["e","g"]) ⊆ Set(only(restricted.transitions).reads)
    @test isnothing(T.bind_transition_trials(agenda,nothing,shifted,shifted_action,components(shifted)))

    joined = bars(3)
    joined[5:7,10:11] .= 3
    before = T.EndpointView(joined,T.public_components(joined))
    after = T.EndpointView(bars(6),T.public_components(bars(6)))
    @test isempty(T.edge_examples(before,after,(0,0)))
end

function slots(colors)
    frame = zeros(UInt8,30,30)
    for ((x,y),color) in zip([(3,3),(7,17),(14,10),(23,6)],colors)
        frame[y:y+1,x:x+2] .= color
    end
    return frame
end

@testset "Learn an arbitrary permutation with repeated colors and retain uncertainty" begin
    agenda = T.RelationAgenda()
    action = Dict("id"=>3)
    reorder(c) = c[[3,4,1,2]]
    function trial(colors,ref;terminal=false,wrong=false)
        current = screen(slots(colors),action)
        proposal = T.bind_transition_trials(agenda,nothing,current,action,components(current))
        next = screen(slots(wrong ? colors : reorder(colors)),action;state=terminal ? "WIN" : "NOT_FINISHED")
        result = record!(agenda,entry(ref*"a",nothing,current),entry(ref*"b",ref*"a",next),proposal)
        return (;proposal,result)
    end
    @test isnothing(trial([1,1,2,3],"first").proposal)
    partial = trial([4,6,8,7],"second")
    claim = only(partial.proposal.transitions).expected
    @test claim.total==4 && claim.colors==[8,7]
    @test only(partial.result.feedback.transition_checks).status==:established
    heldout = trial([9,1,3,6],"third")
    @test only(heldout.proposal.transitions).expected.colors==[3,6,9,1]
    @test heldout.result.feedback.result==:established
    @test trial([2,4,5,9],"terminal";terminal=true).result.feedback.result==:unresolved
    @test trial([2,4,5,9],"counter";wrong=true).result.feedback.result==:refuted
    @test isnothing(trial([2,4,5,9],"withdrawn";wrong=true).proposal)
end

@testset "No-op or counterexample can separate repeated slot colors" begin
    agenda = T.RelationAgenda()
    action = Dict("id"=>3)
    function observe(colors,output,ref)
        obs = screen(slots(colors),action)
        test = T.bind_transition_trials(agenda,nothing,obs,action,components(obs))
        return record!(agenda,entry(ref*"a",nothing,obs),entry(ref*"b",ref*"a",
            screen(slots(output),action)),test)
    end
    observe([1,1,2,2],[2,2,1,1],"training")
    check = only(observe([4,5,6,7],[4,5,6,7],"no-op").feedback.transition_checks)
    @test check.query_status==:unresolved && check.status==:refuted
    obs = screen(slots([4,5,6,7]),action)
    @test isnothing(T.bind_transition_trials(agenda,nothing,obs,action,components(obs)))
end
