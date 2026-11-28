# Run with the fixed Public25 directory and the committed prefix manifest.
# Optional mode: joins, sequential, or whole_prefix. The default compares isolated role queries.
# Predictions are computed before reading the held-out outcome.
using TddESCat
const TC = TddESCat

function read_entry(store,ref)
    event = TC.read_json(TC.store_path(store,"events",ref * ".json"))
    command = TC.read_json(TC.store_path(store,"commands",event["command_ref"] * ".json"))
    observation = TC.checked_receipt(store,command)
    @assert TC.event_record(command,observation) == event
    return (;event,observation)
end

function examples_from(root,selection)
    examples = NamedTuple[]
    for row in selection
        store = TC.RunStore(joinpath(root,row["game"],"public"))
        source = read_entry(store,row["source"])
        antecedent = read_entry(store,source.event["before_ref"])
        before = read_entry(store,row["before"])
        @assert antecedent.event["sequence"] < source.event["sequence"] <= before.event["sequence"]
        effects = TC.observed_effects(antecedent,source)
        @assert TC.endpoint_effects_observed(effects)
        rule = TC.observed_joint_model(effects,last(antecedent.observation.frames),last(source.observation.frames))
        frame = last(before.observation.frames)
        groups = TC.public_components(frame)
        action = source.observation.action
        enclosure = TC.enclosure_pairs(groups)
        push!(examples,(;row,store,before,rule,frame,groups,action,enclosure))
    end
    return examples
end

function evaluate(example,worker,memo)
    query = (;worker,memo,backend=:factor,snapshot=example.before.event["event_id"])
    index = TC.EffectRoleIndex(query)
    result = TC.evaluate_joint_rule(example.rule,example.frame,example.groups,
        example.enclosure,example.action;role_index=index)
    return (;result,reads=index.comparisons)
end

factor_command() = Cmd([abspath(joinpath(@__DIR__,"../../target/release/factor-kernel"))])

function whole_prefix_cost(root,selection)
    function run(factor)
        worker = factor ? TC.ComputeWorker(factor_command()) : nothing
        try
            memo = Dict{Tuple,NamedTuple}()
            return map(examples_from(root,selection)) do example
                hypothesis = evaluate(example,worker,memo).result
                after = read_entry(example.store,example.row["after"])
                @assert after.event["before_ref"] == example.before.event["event_id"] && after.observation.action == example.action
                effects = TC.observed_effects(example.before,after)
                feedback = TC.assessable_binding(hypothesis) ? TC.measure_joint(
                    (model=example.rule,hypothesis.fragments),last(after.observation.frames);effects) : nothing
                return (;hypothesis,feedback)
            end
        finally
            isnothing(worker) || close(worker)
        end
    end
    reference = run(false)
    @assert run(true) == reference
    return map(1:4) do i
        function measure(factor)
            result = @timed run(factor)
            @assert result.value == reference
            return (;result.time,result.bytes)
        end
        order = isodd(i) ? (false,true) : (true,false)
        times = Dict(factor=>measure(factor) for factor in order)
        (;native=times[false],factor=times[true],order)
    end
end

function replay(root,selection)
    examples = examples_from(root,selection)
    worker = TC.ComputeWorker(factor_command())
    try
        function trial(worker,memo)
            measured = @timed [evaluate(e,worker,memo) for e in examples]
            return (;measured.time,measured.bytes,values=measured.value)
        end
        # Warm Julia dispatch separately; cold below refers to empty proof cache.
        trial(nothing,Dict())
        trial(worker,Dict())
        runs = NamedTuple[]
        details = NamedTuple[]
        for attempt in 1:3
            memo = Dict()
            native = trial(nothing,Dict())
            start = worker.request_id
            cold = trial(worker,memo)
            cold_requests = worker.request_id-start
            start = worker.request_id
            warm = trial(worker,memo)
            push!(runs,(;native=(;native.time,native.bytes),cold=(;cold.time,cold.bytes,requests=cold_requests),
                warm=(;warm.time,warm.bytes,requests=worker.request_id-start)))
            for (i,example) in enumerate(examples)
                direct,exact,repeated = (v.values[i] for v in (native,cold,warm))
                @assert direct.result == exact.result == repeated.result
                attempt == 1 || continue
                after = read_entry(example.store,example.row["after"])
                @assert after.event["before_ref"] == example.before.event["event_id"]
                @assert after.observation.action == example.action
                effects = TC.observed_effects(example.before,after)
                feedback = if TC.assessable_binding(exact.result)
                    TC.measure_joint((model=example.rule,exact.result.fragments),last(after.observation.frames);effects)
                end
                push!(details,(;game=example.row["game"],source=example.rule.training_event,
                    before=example.before.event["event_id"],event=after.event["event_id"],
                    response_blob=after.event["response_blob"],reason=exact.result.reason,
                    expected=TC.assessable_binding(exact.result) ? TC.plan_channels(exact.result.fragments) : nothing,
                    exact.reads,feedback))
            end
        end
        return (;runs,events=details)
    finally
        close(worker)
    end
end

function compare_joins(root,selection)
    examples = examples_from(root,selection)
    function trial(join)
        work = NamedTuple[]
        measured = @timed map(examples) do e
            movers = findall(effect->effect.family == :translation,e.rule.effects)
            @assert length(movers) >= 2
            function query(left,right)
                push!(work,(;left=length(left),right=length(right)))
                return join(left,right)
            end
            TC.motion_role_bindings(e.rule,movers,e.groups,e.enclosure,TC.EffectRoleIndex();join_pairs=query)
        end
        return (;measured.time,measured.bytes,values=measured.value,work)
    end
    native = trial(TC.indexed_join_pairs)
    first_galley = trial(TC.galley_join_pairs)
    @assert native.values == first_galley.values
    runs = map(1:3) do _
        direct = trial(TC.indexed_join_pairs)
        galley = trial(TC.galley_join_pairs)
        @assert direct.values == galley.values == native.values
        (;indexed=(;direct.time,direct.bytes),galley=(;galley.time,galley.bytes))
    end
    return (;runs,queries=native.work,first_galley=(;first_galley.time,first_galley.bytes),
        examples=[(;e.row,bindings=length(bound)) for (e,bound) in zip(examples,native.values)])
end

# At each preregistered query the historical action is fixed. Replay the full
# public prefix in order, retaining earlier tests and their condition revisions.
function sequential_replay(root,selection)
    output = NamedTuple[]
    for game in unique(row["game"] for row in selection)
        selected = Dict(row["after"]=>row for row in selection if row["game"] == game)
        sources = Set(row["source"] for row in values(selected))
        store = TC.RunStore(joinpath(root,game,"public"))
        agenda,knowledge = TC.RelationAgenda(),TC.OnlineKnowledge()
        limits = (context_radii=(1,2),history_lengths=(1,2),allow_full_frame=true)
        source_keys = Dict{String,String}()
        history,confirmed = Int[],String[]
        previous = nothing
        pending = Set(keys(selected))
        for line in eachline(TC.store_path(store,"events.jsonl"))
            ref = TC.parse_json(line)["event_id"]
            event = TC.read_json(TC.store_path(store,"events",ref * ".json"))
            @assert isnothing(previous) || event["sequence"] > previous.event["sequence"]
            action = event["action"] # the previously dispatched request
            id = action["id"]
            if id == 0
                current = read_entry(store,ref)
                TC.begin_relation_attempt!(agenda,nothing;observation=current.observation)
                empty!(history)
            else
                @assert previous.event["event_id"] == event["before_ref"]
                obs = previous.observation
                before_ref = previous.event["event_id"]
                rec = (;before_ref,confirmed_refs=confirmed)
                context = TC.relation_context(obs)
                groups = TC.public_components(last(obs.frames))
                row = get(selected,ref,nothing)
                proposal = nothing
                tests = NamedTuple[]
                if !isnothing(row)
                    @assert row["before"] == before_ref && haskey(source_keys,row["source"])
                    condition_view = TC.relation_condition_view(knowledge,rec,history,obs)
                    tests = TC.prepare_relation_tests(agenda,context,obs,groups,action;condition_view)
                    if !isempty(tests)
                        proposal = (;action,intent=:test_concrete_effect,tests,reads=String[],obligation=nothing)
                    end
                end
                prediction = isnothing(proposal) ? nothing :
                    TC.relation_prediction(rec,proposal,nothing,TC.relation_task_record(proposal))
                current = read_entry(store,ref)
                effects = TC.observed_effects(previous,current)
                push!(knowledge.trials,TC.PublicTrial(TC.motion_example(previous,current;history),action,effects))
                observed = TC.observe_relations!(agenda,previous,current,effects,nothing,NamedTuple[],proposal;groups)
                TC.finish_relation_dispatch!(agenda,proposal;feedback=observed.feedback)
                revisions = TC.revise_observed_conditions!(knowledge,agenda,proposal,observed,limits)
                if ref in sources
                    @assert !isnothing(observed.producer)
                    source_keys[ref] = observed.producer.key
                end
                if !isnothing(row)
                    source = source_keys[row["source"]]
                    at = findfirst(t->t.key == source,tests)
                    admitted = !isnothing(prediction) && prediction.payload["guard_truth"] === true
                    push!(output,(;game,event=ref,before=before_ref,source=row["source"],alternatives=length(tests),
                        source_scope=isnothing(at) ? :unavailable : tests[at].scope,
                        source_status=isnothing(at) ? :untested : observed.feedback.tests[at].status,
                        admitted,admitted_source=admitted && !isnothing(at),
                        revisions=[(;r.status,r.producer,r.event) for r in revisions]))
                end
            end
            push!(confirmed,ref)
            push!(history,id)
            previous = current
            delete!(pending,ref)
            isempty(pending) && break
        end
        @assert isempty(pending)
    end
    return output
end

if abspath(PROGRAM_FILE) == @__FILE__
    rows = TC.read_json(ARGS[2])
    if length(ARGS) >= 3 && ARGS[3] == "whole_prefix"
        println(TC.JSON.json(whole_prefix_cost(ARGS[1],rows isa AbstractDict ? rows["roles"] : rows)))
    elseif length(ARGS) >= 3 && ARGS[3] == "sequential"
        println(TC.JSON.json(sequential_replay(ARGS[1],rows isa AbstractDict ? rows["roles"] : rows)))
    elseif length(ARGS) >= 3 && ARGS[3] == "joins"
        println(TC.JSON.json(compare_joins(ARGS[1],rows isa AbstractDict ? rows["joins"] : rows)))
    else
        println(TC.JSON.json(replay(ARGS[1],rows isa AbstractDict ? rows["roles"] : rows)))
    end
end
