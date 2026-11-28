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
    # Reproduce the entire original public prefix before contradicting the edge.
    TC.begin_relation_attempt!(agenda,nothing)
    current = recorded("reset-counterexample",nothing,left,0,[1])
    observe!(right,[2,3],1)
    observe!(left,[1],2)
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

@testset "A witnessed survey step can reach an unexplored viewpoint" begin
    agenda, search = TC.RelationAgenda(), TC.PublicFrontier()
    board, shifted = zeros(UInt8,8,8), zeros(UInt8,8,8)
    board[3:4,2:3] .= 0x04
    shifted[3:4,4:5] .= 0x04
    available = [1,2]
    origin = recorded("initial-view",nothing,board,0,available)
    witnessed = recorded("path-witness",origin.event["event_id"],shifted,1,available)
    TC.observe_relations!(agenda,origin,witnessed,TC.observed_effects(origin,witnessed),
        nothing,NamedTuple[],nothing)
    TC.frontier_observe!(search,agenda)
    TC.begin_relation_attempt!(agenda,nothing;observation=origin.observation)
    obs = origin.observation
    context = TC.relation_context(obs)
    options = [(action=Dict("id"=>id),reason="ordinary") for id in available]
    decision = (;ranked=options)
    # A previously visited immediate successor still leads to another viewpoint.
    successor = TC.frontier_state(agenda,TC.relation_context(witnessed.observation),1)
    search.outcomes[successor] = Dict()
    frontier = (;search,agenda,observation=obs,decision,context)
    survey = (viewpoint=(5,2),step=(3,2),witnessed_first=true)
    task = (id=1,reason="inspect_unseen_neighborhood",survey)
    choose(proposal) = TC.task_arbitration(options[2],proposal,nothing,nothing,nothing;
        program=false,continuing_contact=false,conditional=false,object_probes=false,frontier)
    @test choose((id=1,reason=task.reason)).choice.action == Dict("id"=>2)
    @test choose(task).choice.source == :spatial
    @test choose(task).choice.action == Dict("id"=>1)
    @test isnothing(choose(task).frontier_task)
    agenda.failures[(context,(0,-1,-1),(1,-1,-1))] = 1
    @test choose(task).choice.action == Dict("id"=>2)
end

@testset "A recovery task and a program can propose the same primitive" begin
    action = Dict("id"=>2)
    item = (;action,reason="revalidated_learned_program")
    recovery = (;action,intent=:recover_confirmed_progress)
    competing = TC.task_arbitration(item,nothing,nothing,recovery,nothing;
        program=true,continuing_contact=false,conditional=false,object_probes=false)
    @test competing.choice.action == action
    @test competing.choice.source == :relation
    @test any(candidate->candidate.source == :program && candidate.action == action,competing.candidates)
    ordinary = TC.task_arbitration(item,nothing,nothing,(;action,intent=:test_delayed_effect),nothing;
        program=true,continuing_contact=false,conditional=false,object_probes=false)
    @test ordinary.choice.source == :program && ordinary.choice.action == action
end

@testset "Reach a witnessed comparison before spending another unbound coverage action" begin
    agenda, search = TC.RelationAgenda(), TC.PublicFrontier()
    options = [1,2,3,4]
    origin = zeros(UInt8,18,18)
    origin[3:4,3:4] .= 0x02
    origin[12:13,12:13] .= 0x05
    side = copy(origin); side[8:9,8:9] .= 0x09
    prepared = copy(origin); prepared[3:4,3:4] .= 0x03
    result = copy(prepared); result[12:13,12:13] .= 0x06
    current = recorded("first-reset",nothing,side,0,options)
    ranked = [(action=Dict("id"=>i),rank=(0,i)) for i in options]
    function observe(frame,action,ref;proposal=nothing)
        before = current
        TC.frontier_options!(search,TC.relation_context(before.observation),ranked,nothing)
        current = recorded(ref,before.event["event_id"],frame,action,options)
        out = TC.observe_relations!(agenda,before,current,TC.observed_effects(before,current),nothing,NamedTuple[],proposal)
        TC.frontier_observe!(search,agenda)
        return out
    end
    observe(origin,3,"reach-comparison")
    observe(prepared,1,"build")
    observe(result,2,"consume")
    TC.begin_relation_attempt!(agenda,nothing)
    current = recorded("new-reset",nothing,side,0,options)
    decision() = (;ranked,groups=TC.public_components(last(current.observation.frames)))
    preferred = Dict("id"=>4)
    view = (;search,agenda,observation=current.observation,decision=decision(),context=TC.relation_context(current.observation))
    selected = TC.task_arbitration((;action=preferred,reason="coverage"),nothing,nothing,nothing,nothing;
        program=false,continuing_contact=false,conditional=false,object_probes=false,frontier=view)
    route = selected.frontier_task
    @test selected.choice.action == Dict("id"=>3)
    @test route.intent == :explore_observed_frontier_path
    @test route.obligation.purpose == :test_preparation_omission
    @test route.obligation.consumer == "consume"
    @test all(in(route.reads),["reach-comparison","build","consume"])
    @test isnothing(search.route)
    contrast = (;intent=:test_concrete_effect,action=preferred,obligation=(comparison=:distinguish_concrete_effects,),
        tests=[(expected=Dict("motion"=>1),),(expected=Dict("motion"=>-1),)])
    urgent = TC.task_arbitration((;action=preferred,reason="coverage"),nothing,nothing,contrast,nothing;
        program=false,continuing_contact=false,conditional=false,object_probes=false,frontier=view)
    @test urgent.choice.action == preferred && isnothing(urgent.frontier_task)
    restart_agenda, restart_search = deepcopy(agenda), deepcopy(search)
    loss = recorded("loss","new-reset",side,4,options;state="GAME_OVER")
    TC.observe_relations!(restart_agenda,current,loss,TC.observed_effects(current,loss),nothing,NamedTuple[],nothing)
    TC.frontier_observe!(restart_search,restart_agenda)
    retry = TC.failure_retry!(restart_agenda;frontier=restart_search)
    @test !isnothing(retry)
    TC.begin_relation_attempt!(restart_agenda,retry;observation=current.observation)
    revision = TC.relation_experiment(restart_agenda,current.observation,decision(),nothing,view.context;
        frontier=restart_search)
    @test revision.intent == :explore_observed_frontier_path && revision.action == Dict("id"=>3)
    @test "loss" in revision.reads && "consume" in revision.reads
    recovering_view = merge(view,(;agenda=restart_agenda,search=restart_search))
    recovery = TC.task_arbitration((;action=preferred,reason="coverage"),nothing,nothing,revision,nothing;
        program=false,continuing_contact=false,conditional=false,object_probes=false,frontier=recovering_view)
    @test recovery.choice.action == revision.action && isnothing(recovery.frontier_task)
    @test TC.relation_task_record(revision).revises_failure == "loss"
    arrived = recorded("after-reopen","new-reset",origin,3,options)
    step = TC.observe_relations!(restart_agenda,current,arrived,TC.observed_effects(current,arrived),nothing,NamedTuple[],revision)
    TC.finish_relation_dispatch!(restart_agenda,revision;feedback=step.feedback)
    TC.frontier_observe!(restart_search,restart_agenda)
    @test TC.confirm_frontier_route!(restart_search,restart_agenda,revision).status == :confirmed
    @test restart_agenda.restart.event == "loss"
    arrived_view = (;ranked,groups=TC.public_components(origin))
    last_trial = TC.relation_experiment(restart_agenda,arrived.observation,arrived_view,nothing,
        TC.relation_context(arrived.observation);frontier=restart_search)
    @test last_trial.intent == :test_preparation_omission && last_trial.revises_failure == "loss"
    @test all(in(last_trial.reads),["loss","reach-comparison","consume"])
    # Removing the underlying experiment invalidates a previously quoted route.
    other = deepcopy(agenda)
    empty!(other.uses.omissions)
    @test isnothing(TC.frontier_route_step(search,other,current.observation,decision(),
        TC.frontier_state(other,view.context,other.previous),route.route,preferred,String[]))
    observe(origin,3,"return-to-comparison";proposal=route)
    @test TC.confirm_frontier_route!(search,agenda,route).status == :confirmed
    trial = TC.frontier_choice(search,agenda,current.observation,decision(),nothing,preferred)
    @test trial.intent == :test_preparation_omission && trial.action == Dict("id"=>2)
    trial = TC.bind_relation_reads(agenda,trial,current.observation,trial.action)
    @test any(edge->edge.usage==:omission_test && edge.writer_event=="build",trial.fact_reads)
    response = observe(origin,2,"omitted";proposal=trial)
    @test response.feedback.omission.status == :changed_to_no_effect
    @test isempty(get(agenda.uses.omissions,route.obligation.target,Dict()))
end

@testset "A reachable older comparison keeps its turn across newly discovered short routes" begin
    agenda,search = TC.RelationAgenda(),TC.PublicFrontier()
    available = collect(1:4)
    function scene(mark)
        frame = zeros(UInt8,18,18)
        frame[3:4,3:4] .= 0x02
        frame[12:13,12:13] .= 0x05
        frame[8:9,8:9] .= mark
        return frame
    end
    current = recorded("first",nothing,scene(8),0,available)
    function dispatch(frame,id)
        before = current
        current = recorded("turn-$(length(agenda.samples)+1)",before.event["event_id"],frame,id,available)
        TC.observe_relations!(agenda,before,current,TC.observed_effects(before,current),nothing,NamedTuple[],nothing)
        TC.frontier_observe!(search,agenda)
    end
    function reopen(frame,id)
        TC.begin_relation_attempt!(agenda,nothing)
        current = recorded("reset-$id",nothing,frame,0,available)
    end
    for mark in (8,7)
        reopen(scene(mark),mark)
        prepared = scene(mark); prepared[3:4,3:4] .= 0x03
        response = copy(prepared); response[12:13,12:13] .= 0x06
        dispatch(prepared,1)
        dispatch(response,2)
    end
    reopen(scene(0),1)
    dispatch(scene(9),3)
    dispatch(scene(8),4)
    reopen(scene(0),2)
    dispatch(scene(7),2)
    reopen(scene(0),3)
    node = TC.frontier_state(agenda,TC.relation_context(current.observation),agenda.previous)
    older = TC.frontier_path(search,agenda,node;seek_omission=true)
    @test older.route == [5,6] && older.omission.consumer == 2
    delete!(agenda.uses.omissions[first(older.target)],older.experiment)
    newer = TC.frontier_path(search,agenda,node;seek_omission=true)
    @test newer.route == [7] && newer.omission.consumer == 4
end
