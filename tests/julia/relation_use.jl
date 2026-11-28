using Test, TddESCat
const TC = TddESCat

function receipt(ref, prev, frames, action, available; state="NOT_FINISHED",level=0)
    obs = TC.PublicObservation("public-relations","public-scope",frames,state,level,1,action,available,false)
    return (;event=Dict("event_id"=>ref,"before_ref"=>prev),observation=obs)
end

function observe(agenda,before,after;proposal=nothing)
    TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),nothing,NamedTuple[],proposal)
end

@testset "A confirmed fact survives an unrelated write, expires on an intermediate frame, and links its real reader" begin
    agenda = TC.RelationAgenda()
    f = fill(0x00,16,16)
    f[3:4,3:4] .= 0x02
    f[10:11,10:11] .= 0x05
    act(i) = Dict("id"=>i)
    a = receipt("r",nothing,[f],act(0),[1,2])
    g=copy(f); g[3:4,3:4] .= 0x03
    b=receipt("b","r",[g],act(1),[1,2,3])
    first=observe(agenda,a,b)
    @test Set(getproperty.(first.fact_flow.established,:kind)) == Set([:role_support,:available_action])
    h=copy(g); h[10:11,10:11] .= 0x06
    c=receipt("c","b",[h],act(2),[1,2,3])
    @test isempty(observe(agenda,b,c).fact_flow.invalidated)
    role=only(first.producer.relations)
    support,fact=only(filter(pair->last(pair).writer==1,agenda.uses.roles))
    @test fact.relation==role
    held = (;writer="b",port=fact.output_port,support=TC.semantic_hash(support))
    for intent in (:continue_outcome_preparation,:continue_outcome_relation,:execute_relation_policy)
        plan = (;action=act(2),intent,tests=NamedTuple[],reads=String[],obligation=(;role_reads=[held]))
        use = only(TC.bind_relation_reads(agenda,plan,c.observation,act(2)).fact_reads)
        @test use.writer_event=="b" && use.usage==(intent==:execute_relation_policy ? :policy_preparation_read : :outcome_preparation_read)
        stale = merge(plan,(;obligation=(;role_reads=[merge(held,(;support="absent"))])))
        @test !hasproperty(TC.bind_relation_reads(agenda,stale,c.observation,act(2)),:fact_reads)
    end
    tests=[(;key="probe",fragments=[(;family=:pigment,basis=support)])]
    proposal=(action=act(3),intent=:test_concrete_effect,tests,reads=String[],obligation=nothing)
    bound=TC.bind_relation_reads(agenda,proposal,c.observation,act(3))
    @test Set(getproperty.(bound.fact_reads,:usage))==Set([:task_read,:dispatch_legality])
    @test "b" in bound.reads && "c" in bound.reads
    i=copy(h); i[3:4,3:4] .= 0x04
    d=receipt("d","c",[i],act(3),[1,2,3])
    result=observe(agenda,c,d)
    edge=only(filter(x->x.usage==:observed_input,TC.relation_inputs(agenda,3)))
    @test edge.writer==1 && edge.input_port==edge.output_port==1 && edge.through==2
    @test any(x->x.kind==:role_support && x.status==:destroyed,result.fact_flow.invalidated)
    e=receipt("e","d",[h,i],act(2),[1,2,3])
    changed=observe(agenda,d,e)
    @test any(x->x.writer_event=="d" && x.status==:unknown,changed.fact_flow.invalidated)
    @test !any(fact->fact.writer==3,values(agenda.uses.roles))
    done=receipt("done","e",[i],act(3),[1,2,3];state="WIN",level=1)
    finished=observe(agenda,e,done)
    @test finished.public_outcome.preparation_status==:witnessed
    @test only(finished.public_outcome.requirements).event=="b"
    @test isempty(agenda.uses.roles) && isempty(agenda.uses.permissions)
end

@testset "First-level omission tests retain the known role and discriminate a concrete response" begin
    agenda = TC.RelationAgenda()
    initial=fill(0x00,18,18)
    initial[3:4,3:4].=0x02
    initial[12:13,12:13].=0x05
    a=receipt("initial",nothing,[initial],Dict("id"=>0),[1,2,3])
    prepared=copy(initial); prepared[3:4,3:4].=0x03
    b=receipt("prepared","initial",[prepared],Dict("id"=>1),[1,2,3])
    observe(agenda,a,b)
    response=copy(prepared); response[12:13,12:13].=0x06
    c=receipt("response","prepared",[response],Dict("id"=>2),[1,2,3])
    observe(agenda,b,c)
    TC.begin_relation_attempt!(agenda,nothing)
    r=receipt("reopen",nothing,[initial],Dict("id"=>0),[1,2,3])
    function choose(obs)
        view=TC.public_action_candidates(obs,512;object_probes=true)
        ranked=[(action=Dict("id"=>i),rank=(i,0)) for i in (1,2,3)]
        TC.relation_experiment(agenda,obs,(;ranked,view.groups),nothing,TC.relation_context(obs))
    end
    trial=choose(r.observation)
    @test trial.intent==:test_preparation_omission && trial.action==Dict("id"=>2)
    @test Set(trial.reads)==Set(["initial","prepared","response"])
    selected = TC.bind_relation_reads(agenda,trial,r.observation,trial.action)
    basis = only(selected.fact_reads)
    @test basis.usage == :omission_test && basis.scope == :historical_contrast && basis.through == 1
    o=receipt("omitted","reopen",[initial],trial.action,[1,2,3])
    measured = observe(agenda,r,o;proposal=selected)
    @test measured.feedback.omission.status==:changed_to_no_effect && basis in measured.fact_flow.inputs
    again=receipt("again","omitted",[prepared],Dict("id"=>1),[1,2,3])
    observe(agenda,o,again)
    response2=receipt("again-response","again",[response],Dict("id"=>2),[1,2,3])
    learned=observe(agenda,again,response2)
    contrast=only(filter(x->x.usage==:omission_contrast,learned.fact_flow.inputs))
    @test contrast.writer_event=="again" && contrast.comparison==3
    @test all(in(contrast.reads),["omitted","again"])
    @test !learned.reached.advanced && learned.reached.state=="NOT_FINISHED"
end

@testset "Terminal feedback distinguishes conflicting omissions from unused writers" begin
    agenda = TC.RelationAgenda()
    initial = fill(0x00,12,12)
    initial[3:4,3:4] .= 0x02
    prepared = copy(initial)
    prepared[3:4,3:4] .= 0x03
    ids = [1,2,3]
    function start(ref)
        TC.begin_relation_attempt!(agenda,nothing)
        return receipt(ref,nothing,[initial],Dict("id"=>0),ids)
    end
    a = start("reset-one")
    n = receipt("no-change","reset-one",[initial],Dict("id"=>2),ids)
    observe(agenda,a,n)
    b = start("reset-two")
    win = receipt("win-without-prep","reset-two",[initial],Dict("id"=>2),ids;state="WIN",level=1)
    @test observe(agenda,b,win).public_outcome.preparation_status == :missing_producer
    c = start("reset-three")
    w = receipt("writer","reset-three",[prepared],Dict("id"=>1),ids)
    observe(agenda,c,w)
    also = receipt("win-with-prep","writer",[prepared],Dict("id"=>2),ids;state="WIN",level=1)
    conflicting = observe(agenda,w,also)
    @test conflicting.fact_flow.ambiguous_omission && isempty(conflicting.fact_flow.inputs)
    @test conflicting.public_outcome.preparation_status == :condition_unknown
    @test isnothing(conflicting.public_outcome.relationship)
    d = start("reset-four")
    other = receipt("other-writer","reset-four",[prepared],Dict("id"=>1),ids)
    observe(agenda,d,other)
    unused = receipt("unused","other-writer",[prepared],Dict("id"=>3),ids;state="WIN",level=1)
    @test observe(agenda,other,unused).public_outcome.preparation_status == :no_observed_consumer
end

@testset "A confirmed task can consume a producer and establish its effect in a losing receipt" begin
    agenda = TC.RelationAgenda()
    f = fill(0x00,12,12)
    f[3:4,3:4] .= 0x02
    g = copy(f)
    g[3:4,3:4] .= 0x03
    h = copy(f)
    h[3:4,3:4] .= 0x04
    ids = [1,2]
    action = Dict("id"=>2)
    a = receipt("a",nothing,[f],Dict("id"=>0),ids)
    b = receipt("b","a",[g],Dict("id"=>1),ids)
    c = receipt("c","b",[h],action,ids)
    observe(agenda,a,b)
    observe(agenda,b,c)
    TC.begin_relation_attempt!(agenda,nothing)
    reset = receipt("reset",nothing,[f],Dict("id"=>0),ids)
    writer = receipt("writer","reset",[g],Dict("id"=>1),ids)
    observe(agenda,reset,writer)
    obs = writer.observation
    groups = TC.public_components(g)
    tests = TC.prepare_relation_tests(agenda,TC.relation_context(obs),obs,groups,action)
    @test !isempty(tests)
    proposal = (;action,intent=:apply_relation,tests,reads=String[],obligation=nothing)
    selected = TC.bind_relation_reads(agenda,proposal,obs,action)
    declared = TC.relation_task_record(selected).fact_reads
    @test any(edge->edge.writer_event=="writer" && edge.usage==:task_read,declared)
    terminal = receipt("loss","writer",[h],action,ids;state="GAME_OVER")
    final = observe(agenda,writer,terminal;proposal=selected)
    @test final.public_outcome.result == :failure
    @test final.fact_flow.confirmed_task.result == :established
    @test all(edge->edge in final.fact_flow.inputs,declared)
    @test !any(edge->edge.usage==:observed_input,final.fact_flow.inputs)
end

@testset "A later success without preparation withdraws the previously active outcome explanation" begin
    agenda = TC.RelationAgenda()
    f = fill(0x00,12,12)
    f[3:4,3:4] .= 0x02
    g = copy(f)
    g[3:4,3:4] .= 0x03
    ids = [1,2]
    action = Dict("id"=>2)
    a = receipt("start",nothing,[f],Dict("id"=>0),ids)
    negative = receipt("absent","start",[f],action,ids)
    observe(agenda,a,negative)
    writer = receipt("fact","absent",[g],Dict("id"=>1),ids)
    observe(agenda,negative,writer)
    first_win = receipt("first-win","fact",[g],action,ids;state="WIN",level=1)
    @test observe(agenda,writer,first_win).public_outcome.relationship.comparison == "absent"
    @test length(agenda.outcome_relations) == 1
    TC.begin_relation_attempt!(agenda,nothing)
    initial = receipt("reset",nothing,[f],Dict("id"=>0),ids)
    win = receipt("second-win","reset",[f],action,ids;state="WIN",level=1)
    update = observe(agenda,initial,win).public_outcome
    @test only(update.withdrawn_preparations).counterexample == "second-win"
    @test isempty(agenda.outcome_relations) && first(agenda.outcomes).relationship.status == :hypothesis
end

@testset "Partial local writes motivate a reachable click with explicit uncontrolled observations" begin
    agenda = TC.RelationAgenda()
    f = fill(0x00,20,20)
    f[3:4,3:4] .= 0x02
    f[7:8,3:4] .= 0x04
    f[11:12,8:9] .= 0x08
    f[4:5,15:16] .= 0x09
    g = copy(f)
    g[3:4,3:4] .= 0x03
    g[7:8,3:4] .= 0x05
    g[11,10] = 0x08    # An extension of an existing contour lacks a discrete effect writer.
    ids = [1,6]
    supplied = [1,5,6]
    click = TC.click_action((14,3))
    a = receipt("initial",nothing,[f],Dict("id"=>0),ids)
    b = receipt("prepared","initial",[g],Dict("id"=>1),supplied)
    actual = TC.observed_effects(a,b)
    @test (9,10) in actual.residual
    @test count(e->e.family==:pigment,actual.effects)==2
    observe(agenda,a,b)
    won = receipt("won","prepared",[g],click,supplied;state="WIN",level=1)
    observe(agenda,b,won)
    TC.begin_relation_attempt!(agenda,nothing)
    reset = receipt("again",nothing,[f],Dict("id"=>0),ids)
    obs = reset.observation
    groups = TC.public_components(f)
    decision = (ranked=[(action=Dict("id"=>1),rank=(1,0))],groups=groups)
    trial = TC.omitted_preparation_experiment(agenda,obs,decision,TC.relation_context(obs))
    @test trial.action == click && !trial.obligation.isolated
    @test length(trial.obligation.candidates)==2
    nuisance = trial.obligation.uncontrolled
    @test nuisance.available_added==[5] && isempty(nuisance.available_removed)
    @test (10,9,9,0,8) in nuisance.pixel_spans
    selected = TC.bind_relation_reads(agenda,trial,obs,click)
    @test length(selected.fact_reads)==2 && all(e->e.usage==:omission_test,selected.fact_reads)
    n = receipt("omitted","again",[f],click,ids)
    feedback = observe(agenda,reset,n;proposal=selected).feedback
    @test feedback.omission.status==:changed_to_no_effect && !feedback.omission.isolated
    b2 = receipt("prepared-again","omitted",[g],Dict("id"=>1),supplied)
    observe(agenda,n,b2)
    w2 = receipt("won-again","prepared-again",[g],click,supplied;state="WIN",level=1)
    second = observe(agenda,b2,w2)
    @test second.public_outcome.preparation_status==:condition_unknown
    @test isnothing(second.public_outcome.relationship)
    @test only(second.fact_flow.confounded_omissions).event=="omitted"
    @test !any(e->e.usage==:omission_contrast,second.fact_flow.inputs)
end

@testset "Independent single-role omissions support two prerequisites and retract on a contrary outcome" begin
    agenda = TC.RelationAgenda()
    f = fill(0x00,14,14)
    f[3:4,3:4] .= 0x02
    f[8:9,8:9] .= 0x04
    p = copy(f); p[3:4,3:4] .= 0x03
    q = copy(f); q[8:9,8:9] .= 0x05
    pq = copy(p); pq[8:9,8:9] .= 0x05
    ids = [1,2,3]
    function reset(ref,frame)
        TC.begin_relation_attempt!(agenda,nothing)
        return receipt(ref,nothing,[frame],Dict("id"=>0),ids)
    end
    for (name,frame) in (("only-P",p),("only-Q",q))
        start = reset(name,frame)
        n = receipt(name * "-miss",name,[frame],Dict("id"=>3),ids)
        observe(agenda,start,n)
    end
    a = reset("empty",f)
    wp = receipt("writer-P","empty",[p],Dict("id"=>1),ids)
    wq = receipt("writer-Q","writer-P",[pq],Dict("id"=>2),ids)
    observe(agenda,a,wp)
    observe(agenda,wp,wq)
    pos = receipt("both-won","writer-Q",[pq],Dict("id"=>3),ids;state="WIN",level=1)
    outcome = observe(agenda,wq,pos)
    @test Set(e.writer_event for e in outcome.fact_flow.inputs if e.usage==:omission_contrast) == Set(["writer-P","writer-Q"])
    proof = outcome.public_outcome.relationship
    @test Set(proof.comparisons)==Set(["only-P-miss","only-Q-miss"])
    @test [e.event for e in proof.chain]==["writer-P","writer-Q"]
    start = reset("P-alone-again",p)
    contrary = receipt("P-alone-wins","P-alone-again",[p],Dict("id"=>3),ids;state="WIN",level=1)
    withdrawal = only(observe(agenda,start,contrary).public_outcome.withdrawn_preparations)
    @test withdrawal.comparison=="only-P-miss" && withdrawal.preparation=="writer-Q"
    @test isempty(agenda.outcome_relations)
end

@testset "A visible pigment change can motivate an experiment with unresolved distant correspondences" begin
    agenda = TC.RelationAgenda()
    f = fill(0x00,16,16)
    f[3:4,3:4] .= 0x02
    f[10,3] = f[10,7] = 0x07
    g = copy(f)
    g[3:4,3:4] .= 0x03
    g[10,3] = g[10,7] = 0x00
    g[11,3] = g[11,7] = 0x07
    ids = [1,2]
    start = receipt("start",nothing,[f],Dict("id"=>0),ids)
    prepared = receipt("unmodeled","start",[g],Dict("id"=>1),ids)
    effects = TC.observed_effects(start,prepared)
    @test "competing_support_correspondences" in effects.alternatives && !TC.endpoint_effects_observed(effects)
    transition = observe(agenda,start,prepared)
    raw = only(transition.fact_flow.established)
    @test raw.kind==:role_support && isnothing(raw.producer) && isempty(agenda.producers)
    won = receipt("target","unmodeled",[g],Dict("id"=>2),ids;state="WIN",level=1)
    outcome = observe(agenda,prepared,won)
    trial = only(outcome.fact_flow.proposed_omissions)
    @test trial.uncontrolled_pixels==4 && isnothing(only(trial.candidates).producer)
    @test isnothing(outcome.public_outcome.relationship)
end
