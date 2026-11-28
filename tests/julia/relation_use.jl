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
