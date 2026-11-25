using TddESCat
using Test

const TS = TddESCat

function observed_step(name, prior, action, frame)
    ref = isnothing(prior) ? nothing : prior.event["event_id"]
    observation = TS.PublicObservation("test-game","test-session",[frame],"NOT_FINISHED",
        0,2,Dict("id"=>action),[3,4,5],false)
    return (event=Dict("event_id"=>name,"before_ref"=>ref),observation=observation)
end

@testset "Conflicting moves are resolved against observable context" begin
    function image(x, open; charge=8)
        frame = fill(0x00,20,24)
        frame[6,x+1:x+2] .= 0x03
        frame[7,x+1:x+2] .= 0x08
        frame[2,22] = open ? 0x0c : 0x05
        frame[18,2:charge+1] .= 0x0e
        frame[3:4,10:11] .= open ? 0x07 : 0x04
        return frame
    end
    spatial = TS.SpatialLearning()
    visual = TS.VisualControl()
    origin = (6,5)
    destination = (10,5)
    initial = observed_step("initial",nothing,5,image(6,true))
    passed = observed_step("accepted",initial,4,image(10,true))
    function learn(before,after)
        effects = TS.observed_effects(before,after)
        move = TS.observe_spatial!(spatial,before,after,effects)
        return TS.observe_visual!(visual,spatial,before,after,move,effects)
    end
    learn(initial,passed)
    @test length(spatial.role) == 4
    returned = observed_step("returned",passed,3,image(6,true))
    learn(passed,returned)
    visual.field = TS.VisualField(Window(9,2,2,2),0x00,1)
    toggled = observed_step("closed",returned,5,image(6,false;charge=6))
    observation = learn(returned,toggled)
    @test observation.motion == :stationary
    @test observation.counter.before == 8 && observation.counter.after == 6
    @test observation.signal.before.pigment == 7
    @test only(observation.signal.trace).pigment == 4
    @test observation.action_count == observation.movement_count+1

    stayed = observed_step("blocked",toggled,4,image(6,false;charge=6))
    learn(toggled,stayed)
    frame = only(stayed.observation.frames)
    evidence = TS.motion_evidence(spatial,origin,4,frame,4;current=true)
    @test evidence.status == :conditional_stop
    @test Set(evidence.reads) == Set(["initial","accepted","closed","blocked"])
    @test haskey(spatial.conditions[(origin,4)],(21,1))
    @test all(!rel.complete for rel in values(spatial.conditions[(origin,4)]))
    @test isnothing(TS.projected_motion(visual,spatial,frame,origin,4,(4,0),
        origin,0x00,[];current=true,previous_action=4))

    reopened = image(6,true)
    @test TS.motion_evidence(spatial,origin,4,reopened,5;current=true).point == destination
    @test TS.motion_evidence(spatial,origin,4,reopened,5;current=false).status == :conflict

    contradictory = copy(reopened)
    contradictory[2,22] = 0x05
    @test TS.motion_evidence(spatial,origin,4,contradictory,5;current=true).status == :conflict
    obs = observed_step("new-context",stayed,5,contradictory).observation
    domain = (ranked=[(action=Dict("id"=>id),) for id in (4,3)],)
    probe = TS.spatial_experiment(spatial,obs,domain)
    @test probe.reason == "distinguish_motion_context"
    @test isnothing(probe.destination)
end
