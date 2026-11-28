using Test, TddESCat
const TC=TddESCat

@testset "A rebound omission reads its local scope and keeps the response confounded" begin
    function scene(ref,prior,frame,action;available=[1,2,3,4,5,6],state="NOT_FINISHED",level=0)
        observation=TC.PublicObservation("rebind","session",[frame],state,level,1,action,available,false)
        return (;event=Dict("event_id"=>ref,"before_ref"=>prior),observation)
    end
    function seed(id; paired=false)
        agenda=TC.RelationAgenda()
        f=zeros(UInt8,18,18)
        f[3:4,3:4].=2; f[8:9,12:13].=3; f[13:14,3:4].=5
        act(n)=Dict("id"=>n)
        root=scene("r",nothing,f,act(0))
        function step(before,ref,next,action)
            after=scene(ref,before.event["event_id"],next,action)
            TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),nothing,NamedTuple[],nothing)
            return after
        end
        previous=step(root,"prefix",copy(f),act(5))
        g=copy(f);g[3:4,3:4].=6
        prepared=step(previous,"writer",g,act(1))
        h=copy(g);h[13:14,3:4].=8
        source=step(prepared,"baseline",h,id==6 ? TC.click_action((11,7)) : act(id))
        if paired
            j=copy(h);j[8:9,12:13].=7
            source=step(source,"second-effect",j,act(4))
        end
        m=copy(f);m[17,16:17].=11
        reset=step(source,"restore",m,act(3))
        live=step(reset,"history",copy(m),act(5))
        return (;agenda,root,previous,prepared,source,reset,live)
    end
    function choose(agenda,e)
        obs=e.observation
        TC.rebound_omission_experiment(agenda,obs,(;groups=TC.public_components(last(obs.frames))),TC.relation_context(obs))
    end
    for id in (2,6)
        data=seed(id)
        agenda,live=data.agenda,data.live
        trial=choose(agenda,live)
        @test !isnothing(trial) && trial.action==data.source.observation.action
        @test choose(agenda,live)==trial
        context=TC.relation_context(live.observation)
        no_groups=(;ranked=[])
        @test TC.rebound_omission_experiment(agenda,live.observation,no_groups,context)==trial
        @test TC.rebound_omission_experiment(agenda,live.observation,merge(no_groups,(groups=nothing,)),context)==trial
        ranked=[(action=TC.concrete_action((i,-1,-1)),rank=(i,0)) for i in (1,2,3,4,5)]
        push!(ranked,(action=TC.click_action((11,7)),rank=(6,0)))
        view=(;ranked,groups=TC.public_components(last(live.observation.frames)))
        exhausted=(;scope="model",state=1,edges=Dict(TC.history_action(c.action)=>1 for c in ranked))
        @test TC.relation_experiment(agenda,live.observation,view,nothing,context;history_model=exhausted).intent==:test_rebound_omission
        # Only witnessed spatial uses or genuinely discriminating proposals can
        # outrank the comparison. A location-free or unbound probe cannot.
        base=(;action=ranked[1].action,rank=ranked[1].rank,reason="coverage")
        arbitrate(spatial,experiment) = TC.task_arbitration(base,spatial,nothing,trial,experiment;
            program=false,continuing_contact=false,conditional=false,object_probes=false).choice
        ordinary_probe=(;id=4,reason="unbound",reads=["some-role"])
        @test arbitrate(ordinary_probe,nothing).source==:relation
        possible=[(;same=[:extent],different=Symbol[]),(;same=Symbol[],different=[:extent])]
        genuine=(;judgment=:unknown,rules=possible,sample_events=["other"],reads=["other"])
        targeted=merge(ordinary_probe,(;contact=(;site="bound-object",conditions=genuine)))
        @test arbitrate(targeted,nothing).source==:spatial
        @test arbitrate(nothing,(;action=Dict("id"=>4),independent=true)).source==:experiment
        blocked(p)=isnothing(p) || p.action!=trial.action
        @test trial.obligation.paired_scope==:confounded_rebinding && !trial.obligation.isolated
        @test trial.obligation.uncontrolled.pixel_spans==[(16,15,16,0,11)]
        @test trial.obligation.source_event=="prefix" && "writer" in trial.reads
        ctx=TC.relation_context(live.observation)
        changed(copy_frame;domain=live.observation.available_actions)=scene("new","history",copy_frame,Dict("id"=>5);available=domain)
        m=last(live.observation.frames)
        @test isnothing(choose(agenda,changed(m;domain=[1,2,3,5,6])))
        adjacent=copy(m);adjacent[2,3]=9
        @test isnothing(choose(agenda,changed(adjacent)))
        if id==6
            collision=copy(m);collision[8:9,8:9].=3
            @test blocked(choose(agenda,changed(collision)))
            changed_role=copy(m);changed_role[8:9,12:13].=9
            @test blocked(choose(agenda,changed(changed_role)))
        end
        wrong=deepcopy(agenda); wrong.previous-=1
        @test isnothing(choose(wrong,live))
        failed=deepcopy(agenda)
        failed.failures[(ctx,TC.previous_key(failed,failed.previous),TC.action_key(trial.action))]=failed.previous
        @test blocked(choose(failed,live))
        other=deepcopy(agenda); TC.begin_relation_attempt!(other,nothing)
        @test isnothing(choose(other,live))
        @test isempty(other.uses.rebound)
        # A real terminal event stays in the public corpus. A preceding local
        # colour change by itself is insufficient to bind a policy preparation.
        terminal=deepcopy(agenda)
        displays=copy(m);displays[17,16:17].=12
        trigger=scene("display-conditional","history",displays,Dict("id"=>5))
        TC.observe_relations!(terminal,live,trigger,TC.observed_effects(live,trigger),nothing,NamedTuple[],nothing)
        probe=choose(terminal,trigger)
        @test !isnothing(probe) && probe.action==trial.action
        end_binding=TC.bind_relation_reads(terminal,probe,trigger.observation,probe.action)
        ending=scene("advanced","display-conditional",copy(displays),probe.action;level=1)
        result=TC.observe_relations!(terminal,trigger,ending,TC.observed_effects(trigger,ending),nothing,NamedTuple[],end_binding)
        @test result.public_outcome.result==:advancement && isnothing(result.public_outcome.relationship)
        entries=[data.root,data.previous,data.prepared,data.source,data.reset,live,trigger,ending]
        corpus=TC.witnessed_relation_steps(terminal,entries)
        preceding=length(terminal.samples)-1
        @test any(producer->preceding in producer.support,values(terminal.producers))
        @test !haskey(corpus.links,(preceding,length(terminal.samples)))

        permitted=deepcopy(agenda)
        closed=scene("closed","history",copy(m),Dict("id"=>3);available=setdiff(live.observation.available_actions,[id]))
        TC.observe_relations!(permitted,live,closed,TC.observed_effects(live,closed),nothing,NamedTuple[],nothing)
        grant=scene("granted","closed",copy(displays),Dict("id"=>5))
        TC.observe_relations!(permitted,closed,grant,TC.observed_effects(closed,grant),nothing,NamedTuple[],nothing)
        permission_probe=choose(permitted,grant)
        @test !isnothing(permission_probe) && permission_probe.action==trial.action
        task=TC.bind_relation_reads(permitted,permission_probe,grant.observation,permission_probe.action)
        after_grant=scene("confirmed-after-grant","granted",copy(displays),task.action;level=1)
        allowed=TC.observe_relations!(permitted,grant,after_grant,TC.observed_effects(grant,after_grant),nothing,NamedTuple[],task)
        @test any(r->r.action==id,allowed.public_outcome.requirements)
        cursor=TC.witnessed_relation_steps(permitted,[entries[1:6];closed;grant;after_grant])
        @test haskey(cursor.links,(length(permitted.samples)-1,length(permitted.samples)))
        bound=TC.bind_relation_reads(agenda,trial,live.observation,trial.action)
        @test only(filter(x->x.usage==:rebound_omission_test,bound.fact_reads)).scope==:confounded_rebinding
        task=TC.relation_task_record(bound)
        simulated=(;before_ref="history",payload=Dict("guard_truth"=>true,"predicted_values"=>Dict("unrelated"=>1)))
        prediction=TC.relation_prediction((;before_ref="history"),bound,simulated,task)
        @test prediction.payload["guard_truth"]=="unknown" && isempty(prediction.payload["predicted_values"])
        counter=scene("actual","history",copy(m),trial.action)
        result=TC.observe_relations!(agenda,live,counter,TC.observed_effects(live,counter),nothing,NamedTuple[],bound)
        @test result.feedback.omission.scope==:confounded_rebinding && result.feedback.result==:observed
        @test all(f->f.usage!=:omission_contrast,result.fact_flow.inputs)
        @test length(agenda.samples) in agenda.uses.rebound_receipts
        @test isempty(TC.comparable_visits(agenda,ctx,TC.action_key(trial.action),agenda.samples[trial.obligation.writer]))
        delay=deepcopy(agenda)
        other_prefix=scene("other-history","actual",copy(m),Dict("id"=>4))
        TC.observe_relations!(delay,counter,other_prefix,TC.observed_effects(counter,other_prefix),nothing,NamedTuple[],nothing)
        effect=copy(m);effect[13:14,3:4].=9
        delayed=scene("later-effect","other-history",effect,trial.action)
        TC.observe_relations!(delay,other_prefix,delayed,TC.observed_effects(other_prefix,delayed),nothing,NamedTuple[],nothing)
        @test !any(x->first(x)==length(delay.samples), get(delay.delayed,ctx,[]))
        ordinary=deepcopy(agenda)
        new_write=copy(m);new_write[3:4,3:4].=6
        prep=scene("prepare-again","actual",new_write,Dict("id"=>1))
        TC.observe_relations!(ordinary,counter,prep,TC.observed_effects(counter,prep),nothing,NamedTuple[],nothing)
        advanced=scene("ordinary-result","prepare-again",copy(m),trial.action;level=1)
        result=TC.observe_relations!(ordinary,prep,advanced,TC.observed_effects(prep,advanced),nothing,NamedTuple[],nothing)
        @test result.public_outcome.result==:advancement
        @test all(f->f.usage!=:omission_contrast || f.comparison!=length(agenda.samples),result.fact_flow.inputs)
        @test all(w->length(agenda.samples) ∉ w.comparisons,ordinary.outcome_relations)
        # The old external condition was tested. A new observed condition
        # remains a separate information experiment on the same local binding.
        repeat=scene("same","actual",copy(m),Dict("id"=>5))
        TC.observe_relations!(agenda,counter,repeat,TC.observed_effects(counter,repeat),nothing,NamedTuple[],nothing)
        @test blocked(choose(agenda,repeat))
        externally_changed=copy(m);externally_changed[17,18]=11
        again=scene("again","same",externally_changed,Dict("id"=>5))
        TC.observe_relations!(agenda,repeat,again,TC.observed_effects(repeat,again),nothing,NamedTuple[],nothing)
        reopened=choose(agenda,again)
        @test !isnothing(reopened) && reopened.action==trial.action && reopened.rebound_check!=trial.rebound_check
    end
    # The first writer leaves one preparation available for two different
    # target actions. Confirming one exact control only frees its own record.
    data=seed(2;paired=true)
    agenda=data.agenda
    function observe(before,ref,frame,id)
        action=Dict("id"=>id)
        after=scene(ref,before.event["event_id"],frame,action)
        TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),nothing,NamedTuple[],nothing)
        return after
    end
    f=last(data.previous.observation.frames)
    context=TC.relation_context(data.previous.observation)
    pending=agenda.uses.omissions[context]
    a,b=(2,-1,-1),(4,-1,-1)
    first_trial,second_trial=pending[a],pending[b]
    bucket=only(bucket for (bucket,roles) in agenda.uses.rebound if any(
        rs->any(r->r.trial===first_trial,rs) && any(r->r.trial===second_trial,rs),values(roles)))
    roles=agenda.uses.rebound[bucket]
    anchor=only(k for (k,rs) in roles if any(r->r.trial===first_trial,rs))
    @test any(r->r.trial===second_trial,roles[anchor])
    original=observe(data.live,"original",copy(f),3)
    prefix=observe(original,"original-prefix",copy(f),5)
    first_control=observe(prefix,"first-control",copy(f),2)
    @test !haskey(pending,a) && pending[b]===second_trial
    @test all(r->r.trial!==first_trial,roles[anchor]) && any(r->r.trial===second_trial,roles[anchor])
    second_prefix=observe(first_control,"other-prefix",copy(f),5)
    observe(second_prefix,"second-control",copy(f),4)
    @test !haskey(pending,b)
    @test !haskey(roles,anchor) || !any(r->r.trial===second_trial,roles[anchor])
    isempty(roles) && @test !haskey(agenda.uses.rebound,bucket)

end
