using Test
using TddESCat
const TC = TddESCat

@testset "Realized role contrasts transfer a boundary condition across witnessed appearances" begin
    action = Dict("id"=>2)
    function transition(ref,live,rival,c;reverse_left=false,reverse_top=false,move=true)
        function paint!(frame,p,color)
            x,y = p
            frame[y+1:y+2,x+1:x+2] .= color
        end
        frame = zeros(UInt8,32,32)
        for (xy,selected) in ((live,true),(rival,false))
            isnothing(xy) && continue
            x,y = xy
            frame[y,x+1] = xor(selected,reverse_top) ? 8 : 9
            frame[y+1,x] = xor(selected,reverse_left) ? 10 : 11
            paint!(frame,xy,c)
        end
        after = copy(frame)
        if move
            paint!(after,live,0)
            paint!(after,live .+ (3,0),c)
        end
        function entry(id,pixels,a,b)
            obs = TC.PublicObservation("fixture","roles",[pixels],"NOT_FINISHED",0,2,a,[2,4],false)
            (;observation=obs,event=Dict("event_id"=>id,"before_ref"=>b))
        end
        prev = entry(ref * "-pre",frame,Dict("id"=>4),"")
        next = entry(ref,after,action,prev.event["event_id"])
        effects = TC.observed_effects(prev,next)
        trial = TC.PublicTrial(TC.motion_example(prev,next;history=[4]),action,effects)
        return (;prev,next,effects,trial,frame)
    end
    seed = transition("source",(3,3),nothing,4)
    rule = TC.observed_joint_model(seed.effects,seed.frame,last(seed.next.observation.frames))
    rows = [seed.trial]
    limits = (context_radii=(1,2),allow_full_frame=false,history_lengths=(1,))
    first_example = transition("a",(5,6),(17,18),4)
    second_example = transition("b",(16,18),(5,6),7)
    push!(rows,first_example.trial)
    @test isnothing(TC.fit_role_boundary(rule,rows))
    push!(rows,second_example.trial)
    learned = TC.fit_joint_condition(rule,rows,limits)
    boundary = only(learned.condition.atoms)
    @test boundary isa TC.RoleBoundary && boundary.colors == [4,7]
    @test Set(boundary.reads) == Set(["a-pre","a","b-pre","b"])
    @test length(boundary.offsets) == 2
    function forecast(model,frame)
        groups = TC.public_components(frame)
        TC.candidate_evaluation(model,frame,groups,TC.enclosure_pairs(groups),action,[4])
    end
    for c in (4,7)
        held = transition("held",(13,9),(7,19),c)
        choice = forecast(learned,held.frame)
        @test choice.reason == "unverified_competing_binding"
        @test only(choice.fragments).value == (13,9)
        @test only(values(TC.measure_joint((model=rule,choice.fragments),
            last(held.next.observation.frames);effects=held.effects).assessments)) == "supported"
    end
    disagreement = transition("cross",(13,9),(7,19),7;reverse_left=true)
    @test !TC.assessable_binding(forecast(learned,disagreement.frame))
    @test !TC.assessable_binding(forecast(learned,transition("unseen",(13,9),(7,19),13).frame))
    push!(rows,disagreement.trial)
    narrowed = TC.fit_joint_condition(rule,rows,limits)
    @test only(only(narrowed.condition.atoms).offsets) == ((0,-1),8)
    @test only(forecast(narrowed,disagreement.frame).fragments).value == (13,9)
    contradiction = transition("counter",(10,9),(7,19),7;move=false)
    @test isnothing(TC.fit_role_boundary(rule,[rows;contradiction.trial]))

    # The real receipt consumer learns and revises without a preselected test.
    agenda,knowledge = TC.RelationAgenda(),TC.OnlineKnowledge()
    function receive!(item)
        TC.begin_relation_attempt!(agenda,nothing;observation=item.prev.observation)
        push!(knowledge.trials,item.trial)
        seen = TC.observe_relations!(agenda,item.prev,item.next,item.effects,nothing,NamedTuple[],nothing)
        TC.revise_observed_conditions!(knowledge,agenda,nothing,seen,limits)
    end
    receive!(seed)
    receive!(first_example)
    initial = receive!(second_example)
    @test any(r->r.status == :compared_roles,initial)
    narrowed_receipt = receive!(disagreement)
    @test any(r->r.status == :rechecked_roles,narrowed_receipt)
    @test any(m->any(atom->atom isa TC.RoleBoundary && length(atom.offsets)==1,m.condition.atoms),
        values(knowledge.observed_conditions))
    receive!(contradiction)
    @test all(m->all(atom->!(atom isa TC.RoleBoundary),m.condition.atoms),values(knowledge.observed_conditions))
end

@testset "Preceding click location class uses confirmed continuous supports" begin
    action = Dict("id"=>2)
    agenda = TC.RelationAgenda()
    function entry(id,frames,a,b="")
        obs = TC.PublicObservation("fixture","pointer",frames,"NOT_FINISHED",0,2,a,[2,6],false)
        (;observation=obs,event=Dict("event_id"=>id,"before_ref"=>b))
    end
    function draw!(frame,p,c)
        x,y = p
        for dx in 0:2, dy in 0:2
            (dx,dy) == (1,1) || (frame[y+dy+1,x+dx+1] = c)
        end
        frame[y+4,x+1] = c   # open notch beside the tail, closed hole within the ring
    end
    seed = zeros(UInt8,32,32)
    seed[5,4] = seed[5,7] = 13
    draw!(seed,(2,3),4)
    after = copy(seed)
    draw!(after,(2,3),0)
    draw!(after,(5,3),4)
    pre = entry("s0",[seed],Dict("id"=>0))
    post = entry("s1",[after],action,"s0")
    first_seen = TC.observe_relations!(agenda,pre,post,TC.observed_effects(pre,post),nothing,NamedTuple[],nothing)
    key = first_seen.producer.key
    function prepare(id,live,rival,point;replacement=false)
        frame = zeros(UInt8,32,32)
        for (x,y) in (live,rival,live .+ (3,0))
            frame[y+2,x+2] = 13
        end
        draw!(frame,live,4)
        draw!(frame,rival,4)
        frame[rival[2]+1,rival[1]+4] = 11
        pre = entry(id * "-pre",[frame],Dict("id"=>0))
        TC.begin_relation_attempt!(agenda,nothing;observation=pre.observation)
        transient = copy(frame)
        if replacement
            # A different support at the same coordinates invalidates pointer continuity.
            draw!(transient,point,8)
        end
        clicked = entry(id * "-click",replacement ? [transient,frame] : [frame],
            Dict("id"=>6,"x"=>point[1],"y"=>point[2]),id * "-pre")
        TC.observe_relations!(agenda,pre,clicked,TC.observed_effects(pre,clicked),nothing,NamedTuple[],nothing)
        tests = TC.prepare_relation_tests(agenda,TC.relation_context(clicked.observation),clicked.observation,
            TC.public_components(frame),action)
        matches = filter(t->t.key==key,tests)
        known = isempty(matches) ? nothing : only(matches)
        return (;id,clicked,frame,live,known,tests)
    end
    function feedback!(state,moving)
        next_frame = copy(state.frame)
        if moving
            draw!(next_frame,state.live,0)
            draw!(next_frame,state.live .+ (3,0),4)
        end
        post = entry(state.id * "-motion",[next_frame],action,state.clicked.event["event_id"])
        proposal = (;action,intent=:test_concrete_effect,tests=state.tests,reads=String[],obligation=nothing)
        TC.observe_relations!(agenda,state.clicked,post,TC.observed_effects(state.clicked,post),nothing,NamedTuple[],proposal)
    end
    s1 = prepare("p1",(5,5),(19,21),(5,5))
    @test only(feedback!(s1,true).feedback.tests).status == :established
    s2 = prepare("p2",(19,21),(5,5),(19,21))
    @test only(feedback!(s2,true).feedback.tests).status == :established
    n1 = prepare("n1",(11,9),(22,20),(22,20))
    @test only(feedback!(n1,false).feedback.tests).status == :refuted
    # A grounded local contract remains testable when the source has no
    # complete successor-frame program.
    producer = agenda.producers[key]
    r = producer.rule
    producer.rule = TC.JointMechanism(r.id,r.action_id,r.effects,r.references,r.training_event,
        r.anchors,r.spacing,r.entry_colors,r.parent,nothing,r.click)
    target = prepare("held",(9,22),(24,8),(9,22))
    @test target.known.scope == :replicated
    @test target.known.projection_scope == :witnessed_motion_channel
    contrast = only(target.known.conditions).comparison
    @test Set(contrast.supports) == Set(["p1-motion","p2-motion"])
    @test contrast.excludes == ["n1-motion"] && contrast.observed == (;owner=:bound,zone=:support) && contrast.replicated
    proposal = (;action,intent=:test_concrete_effect,tests=target.tests,reads=String[],obligation=nothing)
    predict = TC.relation_prediction((before_ref=target.clicked.event["event_id"],),proposal,nothing,
        TC.relation_task_record(proposal))
    @test predict.payload["guard_truth"] === true
    opposite = prepare("opposite",(12,23),(21,7),(21,7))
    @test isnothing(opposite.known)
    replaced = prepare("replaced",(13,23),(22,7),(13,23);replacement=true)
    @test isempty(replaced.known.conditions) && replaced.known.scope == :unverified
    hole = prepare("hole1",(5,19),(23,4),(6,20))
    first_contrast = only(hole.known.conditions).comparison
    @test hole.known.scope == :unverified && first_contrast.agreement == :split
    @test first_contrast.observed == (;owner=:bound,zone=:hole)
    @test Set(h.accepts for h in first_contrast.hypotheses)==Set([true,false])
    @test only(values(hole.known.expected)) == (3,0)
    @test hole.known.projection_scope == :candidate_motion_channel
    obs = hole.clicked.observation
    decision = (;ranked=[(;action,rank=(1,0))],groups=TC.public_components(hole.frame))
    hypothesis = TC.relation_experiment(agenda,obs,decision,nothing,TC.relation_context(obs))
    @test hypothesis.intent == :test_concrete_effect && hypothesis.action == action
    prior_forecast = TC.relation_prediction((before_ref=hole.clicked.event["event_id"],),hypothesis,nothing,
        TC.relation_task_record(hypothesis))
    @test prior_forecast.payload["guard_truth"] == "unknown" && isempty(prior_forecast.payload["predicted_values"])
    @test only(feedback!(hole,true).feedback.tests).status == :established
    gap = prepare("gap",(12,14),(20,5),(14,17))
    gc = only(gap.known.conditions).comparison
    @test gc.agreement == :split && gc.observed == (;owner=:bound,zone=:box_gap)
    @test only(feedback!(gap,false).feedback.tests).status == :refuted
    same_gap = prepare("same-gap",(12,14),(20,5),(14,17))
    @test isnothing(same_gap.known)
    gap_obs = same_gap.clicked.observation
    gap_decision = (;ranked=[(;action,rank=(1,0))],groups=TC.public_components(same_gap.frame))
    retry = TC.relation_experiment(agenda,gap_obs,gap_decision,nothing,TC.relation_context(gap_obs))
    @test isnothing(retry) || all(t->t.key != key,retry.tests)
    second_hole = prepare("hole2",(17,20),(4,4),(18,21))
    @test second_hole.known.scope == :unverified
    @test only(feedback!(second_hole,true).feedback.tests).status == :established
    later = prepare("later-hole",(4,21),(25,11),(5,22))
    verified = only(later.known.conditions).comparison
    @test later.known.scope == :replicated && verified.replicated
    @test only(verified.hypotheses).zones == [:support,:hole]
    @test all(in(verified.supports),["hole1-motion","hole2-motion"]) && "gap-motion" in verified.excludes
    feedback!(prepare("counter",(14,23),(21,7),(14,23)),false)
    withdrawn = prepare("withdrawn",(15,23),(22,7),(15,23))
    @test isempty(withdrawn.known.conditions) && withdrawn.known.scope == :unverified
end

@testset "Equivalent colored role contracts retain evidence and all feedback" begin
    p = (family=:translation,port=[(1,2,UInt8(4))])
    a = (producer="a",scope=:bound,roles=[p],expected=Dict("translation-1-2"=>(0,1)))
    b = merge(a,(producer="b",scope=:replicated))
    trial(list;proof=nothing) = TC.relation_prediction((before_ref="before",),(action=Dict("id"=>2),),nothing,
        (contracts=list,intent=:test_concrete_effect,reads=["source-a","source-b"]);role_proof=proof).payload
    for contracts in ([a,b],[a,merge(b,(scope=:unverified,))])
        forecast = trial(contracts)
        @test forecast["guard_truth"] === true && forecast["predicted_values"]["relation-translation-1-2"] == (0,1)
        @test forecast["event_reads"] == ["before","source-a","source-b"]
    end
    @test trial([merge(a,(scope=:unverified,)),merge(b,(scope=:unverified,))])["guard_truth"] == "unknown"
    @test trial([a,merge(b,(roles=[merge(p,(port=[(1,2,UInt8(8))],))],))])["guard_truth"] == "unknown"
    @test trial([a,merge(b,(expected=Dict("translation-1-2"=>(1,0)),))])["guard_truth"] == "unknown"
    @test trial([a,merge(b,(scope=:unverified,expected=Dict("translation-1-2"=>(1,0))))])["guard_truth"] == "unknown"
    unknown = (execution="completed",answer="unknown",value=nothing)
    @test trial([a,b];proof=unknown)["guard_truth"] == "unknown"
end
