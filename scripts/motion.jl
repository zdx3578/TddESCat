using TddESCat
import JSON

const TC = TddESCat
const ROOT = normpath(joinpath(@__DIR__, ".."))

function checked(result)
    result["completion"] == "confirmed" || error("Public transaction did not confirm")
    return result
end

function current_event(rec)
    body = TC.read_json(TC.store_path(rec.store, "events", rec.before_ref * ".json"))
    return (event=body, observation=rec.observation)
end

function public_episode(f, cfg, directory, game; prior=[])
    return with_run(directory) do store
        rec = Recorder(store, cfg)
        TC.before_session!(rec, prior)
        game in list_games(rec.client) || error("Requested game is outside the public list")
        checked(open_scorecard!(rec))
        checked(reset!(rec, game))
        result = f(rec, current_event(rec))
        rec.frozen || checked(close_scorecard!(rec))
        recover_run(store)
        return result
    end
end

function training_pairs(training)
    episode_dirs = filter(name -> occursin(r"^episode-[0-9]{3}\z", name), readdir(training))
    return map(episode_dirs) do name
        with_run(recover_run, joinpath(training, name))
    end
end

function training_corpus(training)
    episodes = training_pairs(training)
    all(entries -> length(entries) == 2, episodes) || error("Training transitions differ from the frozen scope")
    pairs = [(first(entries), last(entries)) for entries in episodes]
    groups = [b.event["intervention_group"] for (_, b) in pairs]
    allunique(groups) || error("Training includes repeated interventions from one session")
    refs = [[p.event["event_id"], p.event["response_blob"], q.event["event_id"], q.event["response_blob"]] for (p,q) in pairs]
    snapshot = "snapshot-" * TC.content_hash(JSON.json(refs))
    return (; pairs, snapshot, corpus=TC.motion_corpus(pairs))
end

function collect_training(cfg, run, request)
    dir = joinpath(run, "training")
    games = request["training_games"]
    1 <= length(games) <= 64 || error("Invalid bounded training episode count")
    for (index, game) in enumerate(games)
        episode = joinpath(dir, "episode-" * lpad(index, 3, '0'))
        public_episode(cfg, episode, game) do rec, _
            action = first(sort(filter(!=(6), rec.observation.available_actions)))
            checked(submit_action!(rec, action))
        end
    end
    evidence = training_corpus(dir)
    corpus = evidence.corpus
    snapshot = evidence.snapshot
    TC.atomic_json(joinpath(run, "source-bindings.json"), corpus.bindings)
    freeze_stitch_job(joinpath(run, "learn-input"), "frame-motion", snapshot, LibrarySnapshot(),
        corpus.signature, corpus.programs, corpus.origins, corpus.slots;
        repo_root=ROOT, config_path=joinpath(ROOT, "config", "stitch.toml"))
    return (training_events=length(corpus.programs), snapshot)
end

function publish_training(run)
    training = training_corpus(joinpath(run, "training"))
    checkpoint = read_stitch_rounds(joinpath(run, "learn-input"), joinpath(run, "learn-output"))
    for (name, recomputed) in (("programs", training.corpus.programs), ("origins", training.corpus.origins),
             ("signature", training.corpus.signature))
        TC.stitch_input(joinpath(run, "learn-input"), checkpoint.manifest, name) == recomputed ||
            error("Frozen corpus differs from the public events")
    end
    checkpoint.manifest["slot_context"] == training.corpus.slots || error("Frozen slot declaration differs")
    publication = TC.publish_stitch!(joinpath(run, "publication"), checkpoint; current_evidence=training.snapshot)
    return (; publication, training.snapshot)
end

function controller_from_public(run, cfg)
    training = training_corpus(joinpath(run, "training"))
    restored = TC.read_published_stitch(joinpath(run, "publication"))
    result = restored.bundle
    result["evidence_snapshot_id"] == training.snapshot &&
        result["source_programs"] == training.corpus.programs &&
        result["origins"] == training.corpus.origins || error("Published sources differ from replay")
    _, definitions = TC.registry_from(result["signature"], restored.snapshot.entries)
    entries = training.corpus.proposals
    samples = TC.MotionExample[item.sample for item in entries]
    templates = unique([TC.shape_template(sample.candidate.before) for sample in entries])
    actions = unique(sample.action for sample in samples)
    template, action = only(templates), only(actions)
    selected = []
    for stable in result["new_definition_ids"]
        discovered = TC.motion_parameters(stable, definitions, result["calls"], samples)
        discovered.complete || error("Parameter enumeration failed to finish")
        isempty(discovered.terms) && continue
        values = unique(parameter.value for parameter in discovered.terms)
        if length(values) == 1
            delta = only(values)
            sources = sort!(unique([id for term in discovered.terms for id in term.reads]))
            parameter = TC.MotionParameter(delta, sources, first(discovered.terms).syntax)
            push!(selected, (id=stable, parameter=parameter))
        end
    end
    unique_effect = only(selected)
    limits = TC.motion_guard_limits(cfg)
    model = TC.fit_motion_claim(unique_effect.id, action, template, unique_effect.parameter, samples; limits...)
    TC.atomic_json(joinpath(run, "initial-mechanism.json"), TC.claim_record(model))
    return (controller=TC.MotionController(model, samples; guard_limits=limits),
        prior=[entry.event for pair in training.pairs for entry in pair], publication=restored.publication)
end

function control(cfg, run, request)
    learned = controller_from_public(run, cfg)
    control = learned.controller
    control_directory = joinpath(run, "control")
    disambiguation = public_episode(cfg, control_directory, request["control_game"]; prior=learned.prior) do rec, entry
        history = [0]
        attempts = Dict{Int,Int}()
        reports = []
        while rec.sent_count < rec.limit
            outcome = TC.motion_step!(control, rec, entry, history, attempts)
            isnothing(outcome.next) && break
            push!(reports, outcome.result)
            entry = outcome.next
        end
        reports
    end
    checks = []
    evaluation_policy = TC.freeze_motion(control)
    frozen = TC.content_hash(JSON.json(TC.claim_record(evaluation_policy.claim)))
    past = [learned.prior; [entry.event for entry in with_run(recover_run, control_directory)]]
    for (index, game) in enumerate(request["evaluation_games"])
        measured = public_episode(cfg, joinpath(run, "evaluation-" * lpad(index, 2, '0')), game; prior=past) do rec, entry
            judgment = TC.cached_judgment(evaluation_policy, evaluation_policy.claim.action,
                last(rec.observation.frames), rec.before_ref, [0])
            if judgment.predicate == TC.proven
                chosen = TC.motion_step!(evaluation_policy, rec, entry, [0], Dict{Int,Int}())
                return chosen.result
            end
            return Dict("status"=>"unknown", "guard"=>TC.truth_wire(judgment.predicate), "reason"=>judgment.reason,
                "event_ref"=>rec.before_ref, "model_version"=>evaluation_policy.claim.version,
                "definition_ref"=>evaluation_policy.claim.definition)
        end
        push!(checks, measured)
    end
    final_digest = TC.content_hash(JSON.json(TC.claim_record(evaluation_policy.claim)))
    final_digest == frozen || error("Frozen evaluation changed the mechanism")
    output = Dict("control"=>disambiguation, "evaluation"=>checks, "final_claim"=>TC.claim_record(control.claim),
        "evaluation_model_before"=>frozen, "evaluation_model_after"=>final_digest, "publication"=>learned.publication)
    TC.atomic_json(joinpath(run, "motion-summary.json"), output)
    return output
end

function main(args)
    length(args) == 4 && first(args) in ("--collect", "--publish", "--control") ||
        error("usage: motion.jl --collect|--publish|--control agent.toml public-dir request.json")
    cfg = load_run_config(args[2])
    run = abspath(args[3])
    request = TC.read_json(args[4])
    result = if first(args) == "--collect"
        collect_training(cfg, run, request)
    elseif first(args) == "--publish"
        publish_training(run)
    else
        control(cfg, run, request)
    end
    println(JSON.json(result))
end

main(ARGS)
