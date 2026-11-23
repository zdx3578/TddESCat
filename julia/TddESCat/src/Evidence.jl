mutable struct Recorder
    store::RunStore
    client::PublicClient
    next_sequence::Int
    sent_count::Int
    limit::Int
    card_id::Union{Nothing,String}
    observation::Union{Nothing,PublicObservation}
    before_ref::Union{Nothing,String}
    frozen::Bool
    mutex::ReentrantLock
    sequence_by_event::Dict{String,Int}
end

function Recorder(store::RunStore, config::RunConfig)
    isempty(records(store, "commands")) || throw(ArgumentError("Existing run requires offline recovery"))
    return Recorder(store, open_client(config), 1, 0, config.execution["max_public_commands"],
        nothing, nothing, nothing, false, ReentrantLock(), Dict{String,Int}())
end

function before_session!(rec, confirmed)
    rec.next_sequence == 1 && isempty(rec.sequence_by_event) || error("Earlier evidence must precede this session")
    isempty(confirmed) && return
    refs = Dict{String,Any}[]
    for event in confirmed
        event["completion"] == "confirmed" || error("Earlier evidence must be confirmed")
        push!(refs, Dict("event_id"=>event["event_id"], "response_blob"=>event["response_blob"],
            "request_sha256"=>event["request_sha256"]))
    end
    sort!(refs; by=entry->entry["event_id"])
    rec.sequence_by_event = prior_sequence_index(refs)
    atomic_json(store_path(rec.store, "prior-events.json"), refs)
end

function prior_sequence_index(entries)
    result = Dict{String,Int}()
    for entry in entries
        reference = entry["event_id"]
        valid_id(reference) && !haskey(result, reference) || error("Invalid earlier event identity")
        all(key -> occursin(r"^[a-f0-9]{64}\z", entry[key]), ("response_blob", "request_sha256")) ||
            error("Invalid earlier event digest")
        result[reference] = 0
    end
    return result
end

function available_prediction_reads(reads, before_ref, sequence_by_event, cutoff)
    reads isa AbstractVector && all(valid_id, reads) && allunique(reads) &&
        !isnothing(before_ref) && before_ref in reads ||
        throw(ArgumentError("Learned prediction lacks a valid action-before read set"))
    check_available(reads, sequence_by_event, cutoff).available ||
        throw(ArgumentError("Prediction reads unavailable or future evidence"))
end

command_id(seq) = "c" * lpad(seq, 9, '0')
is_action_command(command) = command["kind"] in ("reset", "action")

function action_from_request(command)
    path = command["path"]
    action = Dict("id" => (path == RESET_ROUTE ? 0 : parse(Int, last(path, 1))))
    if action["id"] == 6
        body = JSON.parse(command["request_body"])
        for key in ("x", "y")
            expect(coord(get(body, key, nothing)), "invalid_stored_coordinates")
            action[key] = body[key]
        end
    end
    return action
end

function exploration_prediction(store, id, seq, action)
    prediction = Dict(
        "schema_version" => 1, "model_version" => nothing, "binding" => [],
        "action" => action, "guard_truth" => "unknown", "query_scope" => [],
        "predicted_values" => Dict(), "enumeration_complete" => false,
        "assumptions" => ["explicit exploration"],
        "created_before_command" => Dict("command_id" => id, "sequence" => seq))
    atomic_json(store_path(store, "predictions", id * ".json"), prediction)
    return id
end

function prepare_command(rec, kind, path, body; game_id=nothing, guid=nothing, action=nothing, prediction=nothing)
    seq = rec.next_sequence
    id = command_id(seq)
    raw = JSON.json(body)
    command = Dict{String,Any}(
        "schema_version" => 1, "command_id" => id, "sequence" => seq, "kind" => kind,
        "path" => path, "request_body" => raw, "request_sha256" => content_hash(codeunits(raw)),
        "expected_game_id" => game_id, "expected_guid" => guid, "before_ref" => rec.before_ref,
        "prediction_ref" => nothing, "completion" => "prepared")
    if !isnothing(action)
        if isnothing(prediction)
            command["prediction_ref"] = exploration_prediction(rec.store, id, seq, action)
        else
            prediction.before_ref == rec.before_ref && prediction.payload["action"] == action ||
                throw(ArgumentError("Prediction is stale or belongs to a different action"))
            available_prediction_reads(get(prediction.payload, "event_reads", nothing),
                rec.before_ref, rec.sequence_by_event, seq)
            record = merge(prediction.payload,
                Dict("schema_version"=>1, "created_before_command"=>Dict("command_id"=>id, "sequence"=>seq)))
            atomic_json(store_path(rec.store, "predictions", id * ".json"), record)
            command["prediction_ref"] = id
        end
    end
    save_command(rec.store, command)
    rec.next_sequence += 1
    return command
end

function event_record(command, obs)
    event_id = "e-" * first(content_hash(codeunits(obs.guid)), 16) * "-" * command["command_id"]
    return Dict(
        "schema_version" => 1, "event_id" => event_id, "sequence" => command["sequence"],
        "before_ref" => command["before_ref"], "command_ref" => command["command_id"],
        "action" => obs.action, "request_sha256" => command["request_sha256"],
        "response_blob" => command["response_blob"], "completion" => "confirmed",
        "frame_count" => length(obs.frames), "frame_shapes" => [collect(size(frame)) for frame in obs.frames],
        "prediction_ref" => command["prediction_ref"], "intervention_group" => obs.guid,
        "version_refs" => Dict("game" => obs.game_id, "response_parser" => "arc-public-v1",
            "interpretation" => nothing, "signature" => nothing, "library" => nothing,
            "mechanism" => nothing, "context" => nothing))
end

function decode_receipt(command, bytes)
    if is_action_command(command)
        return validate_response(bytes, command["expected_game_id"], command["expected_guid"],
            action_from_request(command))
    end
    data = response_json(bytes)
    expect(data isa Dict, "invalid_scorecard_response")
    if command["kind"] == "open_scorecard"
        expect(nonempty_string(get(data, "card_id", nothing)), "missing_card_id")
        return data["card_id"]
    end
    return nothing
end

function finalize_receipt(store, command, value)
    event = value isa PublicObservation ? commit_event(store, event_record(command, value)) : nothing
    if !isnothing(event)
        command["event_id"] = event["event_id"]
    end
    command["completion"] = "confirmed"
    save_command(store, command)
    return event
end

function transact!(rec::Recorder, command; rejection=nothing, hook=(_...) -> nothing)
    store = rec.store
    if !isnothing(rejection)
        command["completion"] = "explicit_rejection"
        command["reason"] = rejection
        save_command(store, command)
        return command
    end
    command["completion"] = "sent"
    save_command(store, command)
    is_action_command(command) && (rec.sent_count += 1)
    hook(:sent, command)
    try
        response = public_request(rec.client, "POST", command["path"], command["request_body"])
        command["http_status"] = Int(response.status)
        command["response_blob"] = write_blob(store, response.body)
        save_command(store, command)
        hook(:receipt, command)
        value = checked_receipt(store, command)
        event = finalize_receipt(store, command, value)
        hook(:confirmed, command)
        if value isa PublicObservation
            rec.observation = value
            rec.before_ref = event["event_id"]
            rec.sequence_by_event[rec.before_ref] = event["sequence"]
        elseif command["kind"] == "open_scorecard"
            rec.card_id = value
        elseif command["kind"] == "close_scorecard"
            rec.card_id = nothing
        end
    catch error
        error isa InterruptException && rethrow()
        rec.frozen = true
        if command["completion"] == "confirmed"
            rethrow()
        end
        command["completion"] = "outcome_unknown"
        command["reason"] = error isa ProtocolError ? error.reason : "transport_or_storage"
        save_command(store, command)
    end
    return command
end

function open_scorecard!(rec::Recorder; hook=(_...) -> nothing)
    lock(rec.mutex) do
        body = Dict{String,Any}()
        rec.client.environment["competition_mode"] && (body["competition_mode"] = true)
        rejection = rec.frozen ? "session_quarantined" : rec.next_sequence > 1 ? "card_already_attempted" : nothing
        return transact!(rec, prepare_command(rec, "open_scorecard", SCORECARD_OPEN, body); rejection, hook)
    end
end

function reset!(rec::Recorder, game_id; hook=(_...) -> nothing)
    lock(rec.mutex) do
        obs = rec.observation
        guid = isnothing(obs) ? nothing : obs.guid
        body = Dict{String,Any}("game_id" => game_id, "card_id" => rec.card_id)
        isnothing(guid) || (body["guid"] = guid)
        reason = if rec.frozen
            "session_quarantined"
        elseif isnothing(rec.card_id)
            "card_required"
        elseif !valid_id(game_id) || (!isnothing(obs) && game_id != obs.game_id)
            "invalid_game_id"
        elseif rec.sent_count >= rec.limit
            "action_budget"
        else
            nothing
        end
        action = isnothing(reason) ? Dict("id" => 0) : nothing
        cmd = prepare_command(rec, "reset", RESET_ROUTE, body;
            game_id=game_id isa String ? game_id : nothing, guid, action)
        return transact!(rec, cmd; rejection=reason, hook)
    end
end

function submit_action!(rec::Recorder, id; x=nothing, y=nothing, prediction=nothing, hook=(_...) -> nothing)
    lock(rec.mutex) do
        obs = rec.observation
        known_id = strict_integer(id) && 1 <= id <= 7
        path = known_id ? "/api/cmd/ACTION$id" : nothing
        game_id = isnothing(obs) ? nothing : obs.game_id
        guid = isnothing(obs) ? nothing : obs.guid
        body = Dict{String,Any}("game_id" => game_id, "guid" => guid)
        if id === 6 || !isnothing(x) || !isnothing(y)
            body["x"], body["y"] = x, y
        end
        known_id || (body["action_id"] = id)
        reason = if rec.frozen
            "session_quarantined"
        elseif !known_id
            "invalid_action"
        elseif isnothing(obs) || isnothing(rec.card_id)
            "observation_required"
        elseif id ∉ obs.available_actions || obs.state in ("WIN", "GAME_OVER")
            "action_unavailable"
        elseif id == 6 ? !(coord(x) && coord(y)) : !(isnothing(x) && isnothing(y))
            "invalid_coordinates"
        elseif rec.sent_count >= rec.limit
            "action_budget"
        else
            nothing
        end
        action = if !isnothing(reason)
            nothing
        elseif id == 6
            Dict("id" => Int(id), "x" => Int(x), "y" => Int(y))
        else
            Dict("id" => Int(id))
        end
        cmd = prepare_command(rec, "action", path, body; game_id, guid, action, prediction)
        return transact!(rec, cmd; rejection=reason, hook)
    end
end

function close_scorecard!(rec::Recorder)
    lock(rec.mutex) do
        body = Dict("card_id" => rec.card_id)
        reason = rec.frozen ? "session_quarantined" : isnothing(rec.card_id) ? "card_required" : nothing
        cmd = prepare_command(rec, "close_scorecard", SCORECARD_CLOSE, body)
        return transact!(rec, cmd; rejection=reason)
    end
end

function check_frozen_prediction(store, command, action, sequence_by_event)
    id = command["command_id"]
    command["prediction_ref"] == id || error("Missing frozen prediction")
    prediction = read_json(store_path(store, "predictions", id * ".json"))
    prediction["action"] == action && prediction["created_before_command"] ==
        Dict("command_id" => id, "sequence" => command["sequence"]) ||
        error("Frozen prediction does not match command")
    if haskey(prediction, "event_reads")
        available_prediction_reads(prediction["event_reads"], command["before_ref"],
            sequence_by_event, command["sequence"])
    end
end

function checked_receipt(store, command)
    bytes = read_blob(store, command["response_blob"])
    200 <= get(command, "http_status", 0) < 300 || throw(ProtocolError("http_status"))
    return decode_receipt(command, bytes)
end

function recover_run(store)
    earlier = store_path(store, "prior-events.json")
    sequence_by_event = isfile(earlier) ? prior_sequence_index(read_json(earlier)) : Dict{String,Int}()
    existing = records(store, "events")
    by_command = Dict(event["command_ref"] => event for event in existing)
    length(by_command) == length(existing) || error("Duplicate event for a command")
    replayable = NamedTuple[]
    previous = nothing
    commands = sort!(records(store, "commands"); by=command -> command["sequence"])
    for (seq, command) in enumerate(commands)
        command["sequence"] == seq && command["command_id"] == command_id(seq) ||
            error("Nonsequential command log")
        content_hash(codeunits(command["request_body"])) == command["request_sha256"] ||
            error("Request body digest mismatch")
        id = command["command_id"]
        event = pop!(by_command, id, nothing)
        result = command["completion"]
        if !isnothing(event) || result == "confirmed"
            result in ("sent", "confirmed") || error("Event links to unsuccessful command")
            value = checked_receipt(store, command)
            if value isa PublicObservation
                check_frozen_prediction(store, command, value.action, sequence_by_event)
                expected = event_record(command, value)
                event == expected || error("Stored event does not match its request and response")
                event["before_ref"] == previous || error("Event chain mismatch")
                if result == "confirmed"
                    get(command, "event_id", nothing) == event["event_id"] || error("Event reference mismatch")
                else
                    finalize_receipt(store, command, value)
                end
                push!(replayable, (event=event, observation=value))
                previous = event["event_id"]
                sequence_by_event[previous] = event["sequence"]
            else
                isnothing(event) || error("Scorecard request has an event")
                result == "sent" && finalize_receipt(store, command, value)
            end
        elseif result == "sent"
            value, failure = try
                haskey(command, "response_blob") || throw(ProtocolError("no_durable_receipt"))
                checked_receipt(store, command), nothing
            catch error
                error isa InterruptException && rethrow()
                nothing, error isa ProtocolError ? error.reason : "receipt_unreadable"
            end
            if !isnothing(failure)
                command["completion"] = "outcome_unknown"
                command["reason"] = failure
                save_command(store, command)
            else
                if value isa PublicObservation
                    check_frozen_prediction(store, command, value.action, sequence_by_event)
                    command["before_ref"] == previous || error("Recovered event chain mismatch")
                end
                event = finalize_receipt(store, command, value)
                if !isnothing(event)
                    push!(replayable, (event=event, observation=value))
                    previous = event["event_id"]
                    sequence_by_event[previous] = event["sequence"]
                end
            end
        elseif result == "prepared"
            command["completion"] = "explicit_rejection"
            command["reason"] = "prepared_before_restart"
            save_command(store, command)
        elseif result == "outcome_unknown"
            # Unknown outcomes with a receipt remain auditable without interpreting
            # an error body as a confirmed game transition.
            haskey(command, "response_blob") && read_blob(store, command["response_blob"])
        elseif result != "explicit_rejection"
            error("Invalid command completion")
        end
    end
    isempty(by_command) || error("Event references missing command")
    index = join((JSON.json(Dict("event_id" => e.event["event_id"],
        "event_file" => "events/" * e.event["event_id"] * ".json")) * "\n" for e in replayable))
    atomic_write(store_path(store, "events.jsonl"), index)
    return replayable
end

function frame_difference(before, after)
    if size(before) != size(after)
        return Dict("before_shape" => collect(size(before)), "after_shape" => collect(size(after)))
    end
    return [(x=x - 1, y=y - 1, before=Int(before[y, x]), after=Int(after[y, x]))
        for y in axes(before, 1) for x in axes(before, 2) if before[y, x] != after[y, x]]
end

function replay_run!(store)
    events = recover_run(store)
    path = store_path(store, "replay.json")
    report = isfile(path) ? read_json(path) : Dict{String,Any}("schema_version" => 1,
        "applied_events" => Any[], "through_event" => nothing)
    applied = report["applied_events"]
    count = length(applied)
    count <= length(events) || error("Replay cursor exceeds event log")
    for i in eachindex(applied)
        applied[i]["event_id"] == events[i].event["event_id"] &&
            applied[i]["response_blob"] == events[i].event["response_blob"] ||
            error("Replay cursor history mismatch")
    end
    cursor = isempty(applied) ? nothing : last(applied)["event_id"]
    report["through_event"] == cursor || error("Replay cursor mismatch")
    previous = count == 0 ? nothing : last(events[count].observation.frames)
    for entry in @view events[count + 1:end]
        event, observation = entry.event, entry.observation
        transitions = Any[]
        for frame in observation.frames
            if !isnothing(previous)
                push!(transitions, frame_difference(previous, frame))
            end
            previous = frame
        end
        push!(applied, Dict("event_id" => event["event_id"], "response_blob" => event["response_blob"],
            "frame_count" => length(observation.frames), "transitions" => transitions))
        report["through_event"] = event["event_id"]
    end
    number_applied = length(applied) - count
    (number_applied > 0 || !isfile(path)) && atomic_json(path, report)
    return (applied=number_applied, total=length(applied), through_event=report["through_event"])
end
