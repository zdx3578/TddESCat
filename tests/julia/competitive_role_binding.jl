using Test
using TddESCat
const TC = TddESCat

@testset "Runtime selection of competing role evidence" begin
    base = normpath(joinpath(@__DIR__,"../../config/v13_public25.toml"))
    data = TC.TOML.parsefile(base)
    data["learning"]["policy_file"] = joinpath(dirname(base),data["learning"]["policy_file"])
    mktempdir() do dir
        file = joinpath(dir,"agent.toml")
        write_config() = open(io->TC.TOML.print(io,data),file,"w")
        for backend in ("native","factor")
            data["learning"]["competing_role_backend"] = backend
            write_config()
            @test TC.load_run_config(file).learning["competing_role_backend"] == backend
        end
        delete!(data["compute"],"factor_kernel")
        write_config()
        @test_throws ArgumentError TC.load_run_config(file)
        data["learning"]["competing_role_backend"] = "unknown"
        write_config()
        @test_throws ArgumentError TC.load_run_config(file)
    end
end

function entry(ref,frame;action=Dict("id"=>0),before="")
    observation = TC.PublicObservation("roles","isolated",[frame],"NOT_FINISHED",0,2,action,[2,3,5],false)
    return (;event=Dict("event_id"=>ref,"before_ref"=>before),observation)
end

function ordered_history!(agenda,frame,order,label)
    prior = entry(label * "-reset",frame)
    TC.begin_relation_attempt!(agenda,nothing;observation=prior.observation)
    for (i,id) in enumerate(order)
        following = entry(i == length(order) ? label : label * "-$i",frame;
            action=Dict("id"=>id),before=prior.event["event_id"])
        TC.observe_relations!(agenda,prior,following,TC.observed_effects(prior,following),nothing,NamedTuple[],nothing)
        prior = following
    end
    return prior
end

function add_role!(scene,origin,pigment=4)
    x,y = origin
    scene[y+1:y+2,x+1:x+2] .= pigment
end

@testset "Competing role assignments respect observed entry conditions and unknowns" begin
    action = Dict("id"=>2)
    a = zeros(UInt8,32,32)
    b = copy(a)
    add_role!(a,(2,3))
    add_role!(b,(5,3))
    before = entry("train-before",a)
    after = entry("train-after",b;action,before="train-before")
    effects = TC.observed_effects(before,after)
    @test only(effects.effects).family == :translation
    agenda = TC.RelationAgenda()
    obs = TC.observe_relations!(agenda,before,after,effects,nothing,NamedTuple[],nothing)
    rule = agenda.producers[obs.producer.key].rule
    knowledge = TC.OnlineKnowledge()
    push!(knowledge.rules,rule)
    limits = (context_radii=(1,),allow_full_frame=false,history_lengths=(1,2))
    TC.archive_trial!(knowledge,TC.PublicTrial(TC.motion_example(before,after;history=[0]),action,effects),limits)
    @test only(knowledge.active).condition.support == ["train-after"]
    # Both roles can be reached by the same legal action. Only one has the
    # previously observed destination palette; exchange the remote obstacle.
    binary = abspath(joinpath(@__DIR__,"../../target/release/factor-kernel"))
    config = (compute=Dict("factor_kernel"=>binary),learning=Dict("competing_role_backend"=>"factor"))
    TC.with_compute(config) do backends
        worker = backends["factor_kernel"]
        @test "evaluate_bool_batch" in worker.capabilities["operations"]
        memo = Dict{Tuple,NamedTuple}()
        from,to = (7,8),(21,18)
        for (i,(live,rival)) in enumerate(((from,to),(to,from),((12,12),to),((12,24),to)))
            frame = zeros(UInt8,32,32)
            add_role!(frame,live)
            add_role!(frame,rival)
            frame[rival[2]+1,rival[1]+4] = 11
            initial = ordered_history!(agenda,frame,(3,5),"held-$i")
            scene = initial.observation
            context = TC.relation_context(scene)
            query = (worker=worker,memo,backend=:factor,snapshot="held-$i")
            ranked = TC.ranked_public_actions(knowledge,scene,[0,3,5],Dict(),512;competition=query)
            winner = only(row for row in ranked.ranked if row.action == action)
            @test isnothing(winner.chosen)
            proof = only(winner.role_comparisons)
            @test proof.backend == (i == 1 ? :factor : :factor_cache)
            @test count(c->c.verdict=="proven",proof.candidates) == 1
            local_result = TC.evaluate_joint_rule(rule,frame,ranked.groups,[],action)
            @test local_result.truth == TC.unknown_truth && local_result.reason == "unverified_competing_binding"
            @test only(local_result.fragments).value == live
            view = (models=Dict(TC.relation_condition_key(rule)=>knowledge.active),history=[0,3,5],
                reads=model->model.condition.support,transients=UInt8[],competition=query)
            tests = TC.prepare_relation_tests(agenda,context,scene,ranked.groups,action;condition_view=view)
            contract = only(tests)
            @test contract.expected == TC.plan_channels(local_result.fragments)
            @test contract.scope == (i < 3 ? :unverified : :replicated)
            if i < 3
                witness = (steps=[(1,obs.producer.key)],)
                @test isnothing(TC.outcome_preparation_step(agenda,witness,1,scene,ranked,context,action;
                    meters=(),condition_view=view))
            elseif i == 3
                ordered_history!(agenda,frame,(5,3),"reordered")
                alternate = TC.prepare_relation_tests(agenda,context,scene,ranked.groups,action;
                    condition_view=merge(view,(history=[0,5,3],)))
                @test only(alternate).scope == :unverified
                ordered_history!(agenda,frame,(3,5),"recovered-$i")
                initial = entry("recovered-$i",frame;action=Dict("id"=>5))
            end
            proposal = if i <= 2
                result = TC.relation_experiment(agenda,scene,merge(ranked,(condition_view=view,)),nothing,context)
                @test result.obligation.comparison == :distinguish_moving_roles && result.action == action
                result
            else
                (;action,intent=:apply_relation,tests,reads=String[],obligation=nothing)
            end
            forecast = TC.relation_prediction((before_ref=initial.event["event_id"],),proposal,nothing,
                TC.relation_task_record(proposal))
            @test forecast.payload["guard_truth"] == (i <= 2 ? "unknown" : true)
            actual = copy(frame)
            if i <= 3
                add_role!(actual,live,0)
                add_role!(actual,live .+ (3,0))
            end
            result = entry("feedback-$i",actual;action,before=initial.event["event_id"])
            effects = TC.observed_effects(initial,result)
            checked = TC.observe_relations!(agenda,initial,result,effects,nothing,NamedTuple[],proposal)
            @test only(checked.feedback.tests).status == (i <= 3 ? :established : :refuted)
            trial = TC.PublicTrial(TC.motion_example(initial,result;history=[0,3,5]),action,effects)
            TC.archive_trial!(knowledge,trial,limits)
            updated = only(knowledge.active)
            @test result.event["event_id"] in (i <= 3 ? updated.condition.support : updated.counterexamples)
            if i == 4
                ordered_history!(agenda,frame,(3,5),"withdrawn-$i")
                @test isempty(TC.prepare_relation_tests(agenda,context,scene,ranked.groups,action;condition_view=view))
                changed = copy(frame)
                changed[1,1] = 12
                next = ordered_history!(agenda,changed,(3,5),"unrelated").observation
                pending() = TC.prepare_relation_tests(agenda,TC.relation_context(next),next,
                    TC.public_components(changed),action)
                @test isempty(pending())
                ordered_history!(agenda,changed,(5,3),"distinct-history")
                @test only(pending()).scope == :unverified
            end
        end

        frame = zeros(UInt8,32,32)
        add_role!(frame,from)
        add_role!(frame,to)
        @test TC.evaluate_joint_rule(rule,frame,TC.public_components(frame),[],action).truth == TC.unknown_truth
        # A learned guard on an independently bound remote component can also
        # distinguish the identical roles with identical destination colors.
        offset = (0,5)
        marker(xy,color) = (frame[xy[2]+offset[2]+1,xy[1]+offset[1]+1] = color)
        marker(from,7)
        marker(to,8)
        condition = TC.GuardSearch(TC.MotionPredicate[TC.RelativeComponentColor(offset,[(0,0)],7)],
            ["observed-positive"],["observed-negative"],String[],true,true,2)
        model = TC.ActiveMechanism(rule,condition,["observed-negative"],String[])
        evaluate() = TC.candidate_evaluation(model,frame,TC.public_components(frame),[],action,[0];transients=UInt8[])
        @test evaluate().reason == "unverified_competing_binding"
        @test only(evaluate().fragments).value == from
        marker(to,0) # no role of the declared geometry is observable there
        @test evaluate().truth == TC.unknown_truth
        marker(to,7)
        marker(from,8)
        @test only(evaluate().fragments).value == to
        # Out-of-frame destination does not refute the off-screen hypothesis.
        frame .= 0
        add_role!(frame,from)
        add_role!(frame,(30,18))
        @test TC.evaluate_joint_rule(rule,frame,TC.public_components(frame),[],action).truth == TC.unknown_truth
    end
end
