using Test
using TddESCat

const TC = TddESCat

function recorded(ref,previous,frame,action,available;state="NOT_FINISHED")
    observation = TC.PublicObservation("frontier-fixture","fixture-run",[frame],state,0,1,
        Dict("id"=>action),available,false)
    return (event=Dict("event_id"=>ref,"before_ref"=>previous),observation=observation)
end

@testset "Frontier routes reach new experiments and reject a contradicted edge" begin
    agenda, search = TC.RelationAgenda(), TC.PublicFrontier()
    left, right = zeros(UInt8,4,4), zeros(UInt8,4,4)
    left[1,1],right[1,2] = 0x04,0x04
    current = recorded("reset",nothing,left,0,[1])
    function observe!(after,available,action;state="NOT_FINISHED")
        prior = TC.previous_key(agenda,agenda.previous)
        scene = TC.relation_context(current.observation)
        ranked = [(action=Dict("id"=>id),) for id in current.observation.available_actions]
        TC.frontier_options!(search,scene,prior,ranked,nothing)
        ref = "action-" * string(length(agenda.samples)+1)
        next = recorded(ref,current.event["event_id"],after,action,available;state)
        TC.observe_relations!(agenda,current,next,TC.observed_effects(current,next),
            nothing,NamedTuple[],nothing)
        TC.frontier_observe!(search,agenda)
        current = next
    end
    observe!(right,[2,3],1)
    observe!(left,[1],2)
    observe!(right,[2,3],1)
    observe!(left,[1],2)
    decision = (ranked=[(action=Dict("id"=>1),)],)
    plan = TC.frontier_choice(search,agenda,current.observation,decision,nothing,Dict("id"=>1))
    @test plan.intent == :explore_observed_frontier_path
    @test plan.obligation.future_experiment == Dict("id"=>3)
    @test plan.obligation.path == ["action-3"]
    observe!(right,[2,3],1)
    decision = (ranked=[(action=Dict("id"=>id),) for id in [2,3]],)
    next = TC.frontier_choice(search,agenda,current.observation,decision,nothing,Dict("id"=>2))
    @test next.action == Dict("id"=>3)
    @test next.intent == :distinguish_public_frontier
    observe!(left,[1],2)
    alternative = copy(left)
    alternative[1,1] = 0x07
    observe!(alternative,[2,3],1;state="GAME_OVER")
    initial = (TC.relation_context(recorded("bound",nothing,left,2,[1]).observation),(2,-1,-1))
    @test TC.frontier_path(search,agenda,initial) === nothing
end
