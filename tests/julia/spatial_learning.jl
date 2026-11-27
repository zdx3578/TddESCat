using TddESCat
using Test

const TS = TddESCat

function picture_entry(ref, parent, action, frame;coordinates=Dict{String,Int}(),state="NOT_FINISHED")
    observation = TS.PublicObservation("abstract-trial","test-session",[frame],state,
        0,2,merge(Dict("id"=>action),coordinates),[1,2,3,4,6],false)
    return (event=Dict("event_id"=>ref,"before_ref"=>parent),observation=observation)
end

@testset "A survey keeps the route and its ordered evidence" begin
    frame = fill(0x00,64,64)
    frame[1,1:2] .= 0x04
    spatial = TS.SpatialLearning()
    spatial.role = [(0,0,0x04),(1,0,0x04)]
    spatial.role_reads = ["role"]
    spatial.floors[0x00] = 1
    for (id,offset) in enumerate(((1,0),(0,1),(-1,0),(0,-1)))
        spatial.offsets[id] = Dict(offset=>["offset-$id"])
    end
    control = TS.VisualControl()
    control.scene.occlusion_ref = "occlusion"
    push!(control.scene.viewpoints,(0,0))
    obs = picture_entry("survey",nothing,0,frame).observation
    decision = (ranked=[(;action=Dict("id"=>id)) for id in 1:4],)
    selected = TS.scene_survey(control,spatial,obs,decision)
    @test selected.role == (0,0)
    @test selected.id == 1 && selected.destination == (1,0)
    @test selected.frontier == (62,63)
    @test selected.reads == ["role","occlusion","offset-1","offset-2"]
end

@testset "Click movement does not establish a controlled spatial role" begin
    function scene(clicked_x, mover_x)
        frame = fill(0x00,24,24)
        frame[11:13,clicked_x+1:clicked_x+5] .= 0x09
        frame[4:5,mover_x+1:mover_x+2] .= 0x08
        return frame
    end
    first = picture_entry("initial",nothing,0,scene(6,3))
    clicked = picture_entry("clicked","initial",6,scene(11,3);coordinates=Dict("x"=>8,"y"=>11))
    moved = picture_entry("moved","clicked",2,scene(11,5))
    state = TS.SpatialLearning()
    click_effects = TS.observed_effects(first,clicked)
    @test any(effect->effect.family == :translation && length(effect.before) == 15,click_effects.effects)
    @test isnothing(TS.observe_spatial!(state,first,clicked,click_effects))
    @test isempty(state.role) && isempty(state.role_reads)
    move = TS.observe_spatial!(state,clicked,moved,TS.observed_effects(clicked,moved))
    @test move.after == (5,3)
    @test state.role_reads == ["clicked","moved"]
    @test length(state.role) == 4 && all(cell->cell[3] == 0x08,state.role)
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

@testset "An unlocalized landing updates experiment selection" begin
    frame = fill(0x00,16,16)
    frame[6:7,5:6] .= 0x04
    prior = picture_entry("probe-start",nothing,0,frame)
    role = only(filter(shape->first(shape)[3]==0x04,TS.public_components(frame)))
    model = TS.SpatialLearning()
    model.role = TS.shape_template(role)
    model.role_reads = ["bound-role"]
    origin = TS.anchor(role)
    domain = (ranked=[(;action=Dict("id"=>id)) for id in (2,3)],)
    @test TS.spatial_experiment(model,prior.observation,domain).id == 2
    changed = copy(frame)
    changed[6:7,5:6] .= 0x07
    reply = picture_entry("unlocalized-landing","probe-start",2,changed)
    @test isnothing(TS.observe_spatial!(model,prior,reply,TS.observed_effects(prior,reply)))
    @test TS.motion_evidence(model,origin,2,frame,0;current=true).status == :untested
    @test TS.spatial_experiment(model,prior.observation,domain).id == 3
    @test isnothing(TS.spatial_unbound(model,origin,[2],prior.observation))

    altered = copy(frame)
    altered[13,13] = 0x09
    fresh = picture_entry("new-context",nothing,0,altered).observation
    @test TS.spatial_experiment(model,fresh,domain).id == 3
    reconsidered = TS.spatial_unbound(model,origin,[2],fresh)
    @test reconsidered.id == 2 && reconsidered.unlocated_before == 1
    base = (;action=Dict("id"=>1),reason="ordinary_public_option")
    experiment = (;action=Dict("id"=>3),independent=true)
    selected = TS.task_arbitration(base,reconsidered,nothing,nothing,experiment;
        program=false,continuing_contact=false,conditional=false,object_probes=false)
    @test selected.choice.source == :experiment && selected.choice.action == experiment.action
end

@testset "A verified rotation keeps the role bound without borrowing motion evidence" begin
    sprite = UInt8[4 4 4; 9 9 9; 9 9 9]
    turned = rotl90(sprite)
    function scene(sprite,x,y;duplicate=false)
        frame = fill(0x01,20,20)
        h,w = size(sprite)
        frame[y+1:y+h,x+1:x+w] .= sprite
        duplicate && (frame[12:11+h,12:11+w] .= sprite)
        return frame
    end
    p = picture_entry("initial",nothing,0,scene(sprite,2,3))
    q = picture_entry("translated","initial",1,scene(sprite,4,3))
    r = picture_entry("turned","translated",2,scene(turned,4,5))
    s = picture_entry("after-turn","turned",3,scene(turned,6,5))
    state = TS.SpatialLearning()
    TS.observe_spatial!(state,p,q,TS.observed_effects(p,q))
    @test isempty(state.orientations)
    scope = deepcopy(state)
    duplicate = picture_entry("ambiguous","translated",2,scene(turned,4,5;duplicate=true))
    @test isnothing(TS.observe_spatial!(scope,q,duplicate,TS.observed_effects(q,duplicate)))
    @test isempty(scope.orientations)
    move = TS.observe_spatial!(state,q,r,TS.observed_effects(q,r))
    @test move.after == (4,5) && move.orientation_before == 1 && move.orientation_after == 2
    @test state.role_reads == ["initial","translated","turned"]
    @test TS.locate_role(last(r.observation.frames),state) == (4,5)
    @test isnothing(TS.locate_role(last(duplicate.observation.frames),state))
    @test first(TS.measured_offset(state,2)) == (0,2)
    rotated_at_prior = scene(turned,4,3)
    @test TS.motion_evidence(state,(4,3),2,last(q.observation.frames),1;current=true).status == :witnessed
    @test TS.motion_evidence(state,(4,3),2,rotated_at_prior,1;current=true).status == :untested
    @test TS.motion_evidence(state,(4,3),2,rotated_at_prior,1;current=false).status == :conflict
    ranked = [(action=Dict("id"=>id),) for id in 1:3]
    next = TS.spatial_experiment(state,r.observation,(;ranked))
    @test next.id == 3 && next.role == (4,5) && "turned" in next.reads
    continued = TS.observe_spatial!(state,r,s,TS.observed_effects(r,s))
    @test continued.after == (6,5) && continued.orientation_before == continued.orientation_after == 2
    @test length(state.orientations) == 1

    @testset "A same-position preparation reaches another spatial experiment" begin
        blocked = picture_entry("blocked","translated",2,scene(sprite,4,3))
        turned_in_place = picture_entry("prepared","blocked",3,scene(turned,4,3))
        checked_turn = picture_entry("checked-turn","prepared",3,scene(turned,4,3))
        moved = picture_entry("prepared-effect","checked-turn",2,scene(turned,4,6))
        model = TS.SpatialLearning()
        for (before,after) in ((p,q),(q,blocked),(blocked,turned_in_place),
                (turned_in_place,checked_turn),(checked_turn,moved))
            TS.observe_spatial!(model,before,after,TS.observed_effects(before,after))
        end
        ranked = [(action=Dict("id"=>id),) for id in (2,3)]
        proposal = TS.spatial_experiment(model,q.observation,(;ranked))
        @test proposal.id == 3 && proposal.destination == (4,3) && proposal.frontier == (4,9)
        @test proposal.pose == (before=1,after=2)
        @test all(in(proposal.reads),["prepared","prepared-effect"])
        baseline = (;action=Dict("id"=>2),reason="ordinary_public_option")
        experiment = (;action=Dict("id"=>2),independent=true)
        selection = TS.task_arbitration(baseline,proposal,nothing,nothing,experiment;
            program=false,continuing_contact=false,conditional=false,object_probes=false)
        @test selection.choice.source == :spatial && selection.choice.action == Dict("id"=>3)
        continued = TS.spatial_experiment(model,turned_in_place.observation,(;ranked))
        @test continued.id == 2 && continued.destination == (4,6)

        failed = picture_entry("terminal","blocked",3,scene(turned,4,3);state="GAME_OVER")
        movement = TS.observe_spatial!(model,blocked,failed,TS.observed_effects(blocked,failed))
        @test !movement.continuable && movement.orientation_after == 2
        @test isnothing(TS.spatial_experiment(model,q.observation,(;ranked)))
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
