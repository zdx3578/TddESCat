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

@testset "One learned progress relation rebinds to different first steps" begin
    spatial = TS.SpatialLearning()
    spatial.role = [(0,0,0x0c)]
    spatial.role_reads = ["pose"]
    spatial.offsets[2] = Dict((1,0)=>["right"])
    spatial.offsets[3] = Dict((0,-1)=>["up"])
    spatial.offsets[4] = Dict((-1,0)=>["left"])
    spatial.floors[0x00] = 1
    visual = TS.VisualControl()
    field = TS.VisualField(Window(5,5,1,1),0x00,1)
    value = TS.VisualValue(1,1,UInt64(1),0x02)
    function bind(scene, player, sites)
        frame = fill(0x00,6,6)
        frame[6,6] = 0x02
        frame[player[2]+1,player[1]+1] = 0x0c
        visual.field = field
        empty!(visual.targets)
        for (x,y) in sites
            frame[y+1,x+1] = 0x02
            name = TS.VisualField(Window(x,y,1,1),0x00,1)
            visual.targets[(x,y)] = TS.VisualSite(name,value,scene)
        end
        return frame
    end
    function contact(stem, action, hit, advances)
        player = (2,2)
        frame = bind(stem,player,((3,2),(2,1)))
        initial = observed_step(stem,nothing,5,frame)
        post = copy(frame)
        post[player[2]+1,player[1]+1] = 0x00
        post[hit[2]+1,hit[1]+1] = 0x0c
        after = TS.PublicObservation("test-game","test-session",[post],"NOT_FINISHED",
            Int(advances),2,Dict("id"=>action),[2,3,4,5],false)
        return TS.observe_visual_contact!(visual,spatial,initial,
            (event=Dict("event_id"=>stem * "-confirmed"),observation=after))
    end

    entry = contact("entry",2,(3,2),false)
    @test entry.outcome == :entered
    @test isnothing(TS.fit_progress_relations(visual.contact_samples).model)
    TS.begin_visual_level!(visual,spatial)
    progress = contact("advance",3,(2,1),true)
    @test progress.outcome == :progress
    @test progress.public_state == "NOT_FINISHED"
    model = TS.fit_progress_relations(visual.contact_samples)
    @test length(model.rules) == 1
    @test only(model.rules).variable == :action
    @test TS.progress_conditions(model,progress.facts,2).judgment == :enter_only
    @test TS.progress_conditions(model,progress.facts,3).judgment == :progress
    @test TS.progress_conditions(model,progress.facts,4).judgment == :unknown

    domain = (ranked=[(action=Dict("id"=>id),) for id in (2,3,4)],)
    for (scene,sites,expected) in [("fresh-a",((3,2),(2,1)),3),
            ("fresh-b",((3,2),(1,1)),4)]
        TS.begin_visual_level!(visual,spatial)
        frame = bind(scene,(2,2),sites)
        obs = observed_step(scene,nothing,5,frame).observation
        proposal = TS.visual_plan(visual,spatial,obs,domain,scene)
        @test proposal.id == expected
        @test proposal.contact.progress.model == model.model
        @test proposal.contact.progress.judgment == :progress
        @test proposal.contact.progress.action == 3
        @test Set(proposal.contact.progress.sample_events) == Set(["entry-confirmed","advance-confirmed"])
    end
end

@testset "History restores contact after contradictory visual signatures" begin
    state = TS.SpatialLearning()
    state.role = [(0,0,0x0c)]
    state.role_reads = ["motion"]
    state.offsets[4] = Dict((1,0)=>["right"])
    state.floors[0x00] = 1
    controller = TS.VisualControl()
    controller.field = TS.VisualField(Window(4,3,1,1),0x00,1)
    frame = fill(0x00,5,6)
    frame[2,2] = 0x0c
    frame[2,3] = frame[4,5] = 0x02
    value = TS.visual_value(frame,controller.field)
    mark = TS.VisualSite(TS.VisualField(Window(2,1,1,1),0x00,1),value,"initial")
    controller.targets[(2,1)] = mark

    waiting = observed_step("initial",nothing,3,frame)
    blocked = observed_step("blocked",waiting,4,frame)
    @test TS.observe_visual_contact!(controller,state,waiting,blocked).outcome == :blocked
    changed = observed_step("changed",blocked,5,frame)
    next = copy(frame)
    next[2,2] = 0x00
    next[2,3] = 0x0c
    passed = observed_step("passed",changed,4,next)
    @test TS.observe_visual_contact!(controller,state,changed,passed).outcome == :entered
    TS.begin_visual_attempt!(controller)
    fit = TS.fit_contact_guards(controller.contact_samples)
    @test isempty(fit.rules)
    @test first(only(fit.scoped)) == :previous_action
    signature = TS.contact_signature(value,value)
    @test TS.contact_judgment(fit,signature,TS.contact_facts(controller,3),4) == :blocked
    @test TS.contact_judgment(fit,signature,TS.contact_facts(controller,5),4) == :admitted
    @test TS.contact_judgment(fit,signature,TS.contact_facts(controller,0),4) == :unknown

    domain = (ranked=[(action=Dict("id"=>4),)],)
    denied = TS.visual_plan(controller,state,waiting.observation,domain,"initial")
    @test isnothing(denied)
    admitted = TS.visual_plan(controller,state,changed.observation,domain,"changed")
    @test admitted.reason == "learned_visual_contact"
    @test admitted.contact.conditions.judgment == :admitted
    @test Set(admitted.contact.conditions.scope_events) == Set(["blocked","passed"])

    TS.observe_visual_contact!(controller,state,changed,
        observed_step("same-history-refutation",changed,4,frame))
    @test isempty(TS.fit_contact_guards(controller.contact_samples).scoped)
end

@testset "The whole response qualifies one step only when its trace agrees" begin
    function frame_at(x)
        frame = fill(0x00,8,10)
        frame[3:4,x:x+1] .= 0x03
        return frame
    end
    function snapshot(i, action, frames)
        observation = TS.PublicObservation("public-trace","test-session",frames,"NOT_FINISHED",
            0,1,Dict("id"=>action),[1],false)
        event = Dict("event_id"=>"trace-$i","before_ref"=>i == 1 ? nothing : "trace-$(i-1)",
            "sequence"=>i,"response_blob"=>"blob-$i")
        return (;event,observation)
    end
    a,b,c = frame_at.(2:4)
    initial = snapshot(1,0,[a])
    first = snapshot(2,1,[a,b,b])
    last = snapshot(3,1,[b,c,c])
    effects = TS.observed_effects(initial,first)
    @test effects.complete
    @test length(effects.public_delta["response_trace"]) == 3
    @test isempty(effects.residual)
    corpus = TS.compile_sequence_corpus([[initial,first,last]])
    @test corpus.confirmed_program_actions == 2
    @test [step["frame_count"] for step in only(corpus.scopes)["steps"]] == [3,3]
    @test only(corpus.scopes)["events"] == ["trace-2","trace-3"]

    transient = snapshot(2,1,[a,b,a])
    effects = TS.observed_effects(initial,transient)
    @test !effects.complete
    @test "intermediate_frames_require_separate_interpretation" in effects.alternatives
    @test isempty(TS.compile_sequence_corpus([[initial,transient,last]]).programs)
end
