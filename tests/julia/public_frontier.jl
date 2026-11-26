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
        scene = TC.relation_context(current.observation)
        ranked = [(action=Dict("id"=>id),) for id in current.observation.available_actions]
        TC.frontier_options!(search,scene,ranked,nothing)
        ref = "action-" * string(length(agenda.samples)+1)
        next = recorded(ref,current.event["event_id"],after,action,available;state)
        TC.observe_relations!(agenda,current,next,TC.observed_effects(current,next),
            nothing,NamedTuple[],nothing)
        TC.frontier_observe!(search,agenda)
        current = next
    end
    observe!(right,[2,3],1)
    observe!(left,[1],2)
    left_context = first(agenda.samples).context
    initial = TC.frontier_path(search,agenda,(left_context,()))
    @test initial.route == [1]
    @test length(last(initial.target)) == 1
    observe!(right,[2,3],1)
    observe!(left,[1],2)
    decision = (ranked=[(action=Dict("id"=>1),)],)
    plan = TC.frontier_choice(search,agenda,current.observation,decision,nothing,Dict("id"=>1))
    @test plan.intent == :explore_observed_frontier_path
    @test plan.obligation.future_experiment == Dict("id"=>3)
    @test plan.obligation.path == ["action-3"]
    @test isnothing(search.route)
    observe!(right,[2,3],1)
    @test TC.confirm_frontier_route!(search,agenda,plan) == (status=:confirmed,step=1,next=2)
    decision = (ranked=[(action=Dict("id"=>id),) for id in [2,3]],)
    next = TC.frontier_choice(search,agenda,current.observation,decision,nothing,Dict("id"=>3))
    @test next.action == Dict("id"=>3)
    @test next.intent == :distinguish_public_frontier
    @test next.obligation.source == "reachable_frontier_obligation"
    @test search.route.cursor == 2
    observe!(left,[1],2)
    @test TC.confirm_frontier_route!(search,agenda,nothing).status == :released
    @test isnothing(search.route)
    alternative = copy(left)
    alternative[1,1] = 0x07
    observe!(alternative,[2,3],1;state="GAME_OVER")
    initial = TC.frontier_state(agenda,TC.relation_context(recorded("bound",nothing,left,2,[1]).observation),2)
    @test TC.frontier_path(search,agenda,initial) === nothing
end

@testset "A contradicted public successor triggers a witnessed history split" begin
    agenda, search = TC.RelationAgenda(), TC.PublicFrontier()
    origin = fill(0x00,4,4)
    shared = copy(origin)
    shared[1,1] = 0x03
    target = copy(shared)
    refined = nothing
    context = ""
    for (trial,preparation) in enumerate((1,4))
        trial > 1 && TC.begin_relation_attempt!(agenda,nothing)
        previous = recorded("reset-$trial",nothing,origin,0,[1,4])
        rendering = copy(target)
        rendering[2,2] = UInt8(trial)
        for (position,(id,frame,available)) in enumerate(
                ((preparation,origin,[5]),(5,shared,[7]),(7,rendering,[7])))
            state = trial == 1 && position == 3 ? "GAME_OVER" : "NOT_FINISHED"
            after = recorded("trial-$trial-$position",previous.event["event_id"],frame,id,available;state)
            position == 3 && (context = TC.relation_context(previous.observation))
            TC.observe_relations!(agenda,previous,after,TC.observed_effects(previous,after),
                nothing,NamedTuple[],nothing)
            refined = TC.frontier_observe!(search,agenda)
            previous = after
        end
    end
    @test refined.width == 2 && refined.before_width == 1
    @test refined.evidence == ["trial-1-3","trial-2-3"]
    @test refined.history_reads == [["trial-1-1","trial-1-2"],["trial-2-1","trial-2-2"]]
    left = TC.frontier_state(agenda,context,2)
    right = TC.frontier_state(agenda,context,5)
    @test left != right
    histories = [search.outcomes[node][(7,-1,-1)] for node in (left,right)]
    @test histories == [[3],[6]]
    successors = [TC.frontier_successor(agenda,group) for group in histories]
    @test isnothing(successors[1]) && !isnothing(successors[2])
    action = (7,-1,-1)
    @test TC.observed_failure(agenda,context,action,2)
    @test !TC.observed_failure(agenda,context,action,5)
    rule = first(values(agenda.producers)).rule
    producer = TC.RelationProducer(rule,["confirmed"],[6],Int[])
    @test TC.verified_instance(agenda,producer,context,action,5,0) == :bound
    @test TC.verified_instance(agenda,producer,context,action,2,0) == :unverified
    push!(producer.refuted,3)
    @test TC.verified_instance(agenda,producer,context,action,2,0) == :counterexample
    history = TC.response_history_task(agenda,0)
    @test length(history.episodes) == 2
    @test only(unique(episode.origin for episode in history.episodes)) == first(agenda.samples).context
    @test [[step.event for step in episode.steps] for episode in history.episodes] ==
        [["trial-1-1","trial-1-2","trial-1-3"],["trial-2-1","trial-2-2","trial-2-3"]]
end

@testset "Failure revision can add a legal action absent from ranked rows" begin
    agenda, search = TC.RelationAgenda(), TC.PublicFrontier()
    board = zeros(UInt8,64,64)
    start = recorded("reset",nothing,board,0,[6])
    action = TC.click_action((10,10))
    observation = TC.PublicObservation("frontier-fixture","fixture-run",[board],"GAME_OVER",0,1,action,[6],false)
    failed = (event=Dict("event_id"=>"failure","before_ref"=>"reset"),observation)
    context = TC.relation_context(start.observation)
    TC.frontier_options!(search,context,[(;action)],nothing)
    TC.observe_relations!(agenda,start,failed,TC.observed_effects(start,failed),nothing,NamedTuple[],nothing)
    TC.frontier_observe!(search,agenda)
    restart = TC.failure_retry!(agenda;frontier=search)
    TC.begin_relation_attempt!(agenda,restart;observation=start.observation)
    decision = (ranked=[(;action,rank=(0,0),reason="already_tried")],groups=TC.public_components(board))
    first_probe = TC.click_action((16,16))
    alternative = TC.relation_experiment(agenda,start.observation,decision,(action=first_probe,),context;frontier=search)
    @test alternative.action == first_probe
    next = TC.relation_experiment(agenda,start.observation,decision,nothing,context;frontier=search)
    @test next.intent == :revise_failed_trace && next.action != action && next.action["id"] == 6
    @test next.reads == ["failure"]
end

@testset "An exhausted representative opens a legal coordinate experiment" begin
    agenda, search = TC.RelationAgenda(), TC.PublicFrontier()
    board = zeros(UInt8,64,64)
    before = recorded("reset",nothing,board,0,[6])
    action = TC.click_action((10,10))
    for i in 1:2
        observation = TC.PublicObservation("frontier-fixture","fixture-run",[board],"NOT_FINISHED",0,1,action,[6],false)
        after = (event=Dict("event_id"=>"click-$i","before_ref"=>before.event["event_id"]),observation)
        TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),nothing,NamedTuple[],nothing)
        TC.frontier_observe!(search,agenda)
        before = after
    end
    proposal = TC.frontier_choice(search,agenda,before.observation,(ranked=[(;action)],),nothing,action)
    @test proposal.action == TC.click_action((0,0))
    @test proposal.obligation.source == "untried_public_configuration"
    @test "click-2" in proposal.reads
end

@testset "Frontier checks the action selected by arbitration" begin
    agenda, search = TC.RelationAgenda(), TC.PublicFrontier()
    board = zeros(UInt8,4,4)
    available = [1,2]
    before = recorded("reset",nothing,board,0,available)
    for i in 1:2
        after = recorded("repeat-$i",before.event["event_id"],board,2,available)
        TC.observe_relations!(agenda,before,after,TC.observed_effects(before,after),nothing,NamedTuple[],nothing)
        TC.frontier_observe!(search,agenda)
        before = after
    end
    obs = before.observation
    context = TC.relation_context(obs)
    item = (action=Dict("id"=>1),reason="uncovered")
    ordinary = (action=Dict("id"=>2),)
    decision = (ranked=[item,ordinary],)
    frontier = (;search,agenda,observation=obs,decision,context)
    @test isnothing(TC.frontier_choice(search,agenda,obs,decision,nothing,item.action))
    decided = TC.task_arbitration(item,nothing,nothing,nothing,ordinary;
        program=false,continuing_contact=false,conditional=false,object_probes=false,frontier)
    @test decided.baseline.action == ordinary.action && decided.baseline.source == :experiment
    @test decided.choice.action == item.action && decided.choice.source == :relation
    @test decided.frontier_task.obligation.baseline == ordinary.action
    @test decided.frontier_task.reads == ["repeat-2","repeat-1"]
    kept = TC.task_arbitration(item,(id=2,reason="continue_contact"),nothing,nothing,ordinary;
        program=false,continuing_contact=true,conditional=false,object_probes=false,frontier)
    @test kept.choice.action == ordinary.action && kept.choice.source == :spatial
    @test isnothing(kept.frontier_task)
end
