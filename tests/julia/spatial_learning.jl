using TddESCat
using Test

const TS = TddESCat

function picture_entry(ref, parent, action, frame)
    observation = TS.PublicObservation("abstract-trial","test-session",[frame],"NOT_FINISHED",
        0,2,Dict("id"=>action),[1,2,3,4],false)
    return (event=Dict("event_id"=>ref,"before_ref"=>parent),observation=observation)
end

@testset "Public contact evidence chooses between candidate relations" begin
    frame = fill(0x00,4,5)
    frame[1,:] = [0x07,0x0c,0x02,0x00,0x00]
    frame[3,4] = 0x02
    state = TS.SpatialLearning()
    state.role = [(0,0,0x0c)]
    state.role_reads = ["motion"]
    state.offsets[2] = Dict((1,0)=>["right"])
    state.offsets[3] = Dict((-1,0)=>["left"])
    state.floors[0x00] = 1
    control = TS.VisualControl()
    field = TS.VisualField(Window(3,2,1,1),0x00,1)
    control.field = field
    same = TS.VisualValue(1,1,UInt64(1),0x02)
    different = TS.VisualValue(1,1,UInt64(1),0x07)
    left = TS.VisualSite(TS.VisualField(Window(0,0,1,1),0x00,1),different,"visible")
    right = TS.VisualSite(TS.VisualField(Window(2,0,1,1),0x00,1),same,"visible")
    control.targets[(0,0)] = left
    control.targets[(2,0)] = right
    observation = picture_entry("fresh",nothing,0,frame).observation
    domain = (ranked=[(action=Dict("id"=>id),) for id in (2,3)],)
    cold = TS.visual_plan(control,state,observation,domain,"fresh")
    @test cold.reason == "experiment_on_contact_relation"
    @test cold.id == 2
    @test cold.contact.conditions.judgment == :unknown
    facts = TS.contact_facts(control,0)
    denied = TS.ContactSample(0,(2,0),same,right,field,(1,0),2,:blocked,
        "before-block","blocked",state.role,"right",facts,"NOT_FINISHED")
    permitted = TS.ContactSample(0,(0,0),same,left,field,(1,0),3,:entered,
        "before-entry","entered",state.role,"left",facts,"NOT_FINISHED")
    append!(control.contact_samples,[denied,permitted])
    command = TS.visual_plan(control,state,observation,domain,"fresh")
    @test command.reason == "learned_visual_contact"
    @test command.id == 3
    @test command.executes_contact
    @test all(ref->ref in command.reads,["entered","blocked"])
    contradiction = TS.ContactSample(0,(0,0),same,left,field,(1,0),3,:blocked,
        "before-counterexample","later-blocked",state.role,"left",facts,"NOT_FINISHED")
    push!(control.contact_samples,contradiction)
    @test isempty(TS.fit_contact_guards(control.contact_samples).rules)
    @test TS.contact_judgment(TS.fit_contact_guards(control.contact_samples),
        TS.contact_signature(same,different)) == :unknown
end

@testset "Learned input binding and exploration" begin
    function image(x,y,palette)
        frame = fill(palette[1],24,24)
        frame[y+1:y+1,x+1:x+4] .= palette[2]
        frame[y+2:y+3,x+1:x+4] .= palette[3]
        return frame
    end
    for (palette, horizontal, vertical) in [((0x06,0x02,0x0f),2,4),((0x08,0x0c,0x04),3,1)]
        p = picture_entry("initial",nothing,0,image(5,4,palette))
        q = picture_entry("horizontal","initial",horizontal,image(9,4,palette))
        r = picture_entry("vertical","horizontal",vertical,image(9,7,palette))
        state = TS.SpatialLearning()
        TS.observe_spatial!(state,p,q,TS.observed_effects(p,q))
        TS.observe_spatial!(state,q,r,TS.observed_effects(q,r))
        @test length(state.role) == 12
        @test first(TS.measured_offset(state,horizontal)) == (4,0)
        @test first(TS.measured_offset(state,vertical)) == (0,3)
        @test TS.locate_role(last(r.observation.frames),state.role) == (9,7)
        ranked = [(action=Dict("id"=>id),) for id in (horizontal,vertical)]
        proposal = TS.spatial_experiment(state,r.observation,(;ranked))
        @test proposal.destination != (9,7)
        @test "horizontal" in proposal.reads
    end
end

@testset "Observed motifs and temporal evidence" begin
    pixels = fill(0x0f,20,32)
    support = [(0,0),(1,0),(2,0),(0,1),(2,2)]
    for (x,y,s) in [(2,3,2),(23,12,1)]
        pixels[y:y+3s+1,x:x+3s+1] .= 0x02
        for (u,v) in support
            pixels[y+v*s+1:y+(v+1)*s,x+u*s+1:x+(u+1)*s] .= 0x0d
        end
    end
    motifs = TS.visual_motifs(pixels,10)
    pair = [m for m in motifs if m.field.background == 0x02 && m.value.width == m.value.height == 3]
    @test sort!([m.field.scale for m in pair]) == [1,2]
    @test allequal(m.value for m in pair)
    @test TS.motif_contrast_boundary(pixels,first(pair).field,3)
    clipped = fill(first(pair).field.background,size(pixels))
    bounds = first(pair).field.box
    ys = bounds.y+1:bounds.y+bounds.height
    xs = bounds.x+1:bounds.x+bounds.width
    clipped[ys,xs] = pixels[ys,xs]
    @test !TS.motif_contrast_boundary(clipped,first(pair).field,3)

    original = first(pair).value
    op = (true,true,false)
    after = TS.visual_transform(original,op)
    other = TS.VisualValue(3,3,UInt64(227),0x0d)
    updates = Dict((0x01,)=>[TS.VisualTransition(original,after,"first"),
        TS.VisualTransition(other,TS.visual_transform(other,op),"second")])
    fresh = TS.VisualValue(3,3,UInt64(373),0x0d)
    hypothesis = TS.visual_prediction(updates,(0x01,),fresh)
    @test hypothesis.value == TS.visual_transform(fresh,op)
    @test Set(hypothesis.reads) == Set(["first","second"])
    @test isnothing(TS.visual_prediction(updates,(0x00,),fresh))

    period = [(2,3),(6,3),(6,6),(2,6)]
    samples = Dict(i=>TS.LandmarkObservation(period[mod1(i+1,4)],"frame-$i") for i in 0:9 if i != 3)
    @test TS.infer_landmark_period(samples,(4,3)).positions == period
    samples[6] = TS.LandmarkObservation((10,10),"contradictory")
    @test isnothing(TS.infer_landmark_period(samples,(4,3)))
end
