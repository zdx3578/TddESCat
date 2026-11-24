using TddESCat
import JSON
import TOML

const ROOT = normpath(joinpath(@__DIR__, ".."))

function capture(config, public_dir; supervised=false, collect_only=false)
    enforce = config.execution["memory_enforcement"]
    (enforce == "cgroup_v2") == supervised || error("Solver launch does not match memory enforcement")
    if supervised
        launch = TddESCat.read_json(joinpath(public_dir, "supervision.json"))
        occursin("/" * launch["scope"], read("/proc/self/cgroup", String)) ||
            error("Solver is outside the configured cgroup")
    end
    return with_run(public_dir) do store
        rec = Recorder(store, config)
        prior = TddESCat.prior_trials(config)
        TddESCat.before_session!(rec,prior.events)
        knowledge = TddESCat.OnlineKnowledge()
        prepared = nothing
        frozen = collect_only || get(config.execution,"frozen_evaluation",false)
        if !isnothing(config.learning)
            TddESCat.atomic_json(TddESCat.store_path(store,"learning","session.json"),Dict("frozen"=>frozen))
        end
        if !isempty(prior.trials)
            append!(knowledge.trials,prior.trials)
            prepared = TddESCat.online_learn!(knowledge,config,store,prior.pairs,ROOT)
            frozen && isnothing(prepared) && error("Frozen evaluation has no proved publication")
            get(config.learning,"association",false) && TddESCat.train_prior_relations!(knowledge,config,store,ROOT)
            get(config.learning,"sequences",false) && TddESCat.train_prior_programs!(knowledge,config,store,ROOT)
        end
        games = list_games(rec.client)
        requested = get(config.environment, "game_id", nothing)
        game_id = if isnothing(requested)
            isempty(games) && error("Public game list is empty")
            first(games)
        else
            requested in games || error("Configured game is absent from the public list")
            requested
        end
        learned = nothing
        if open_scorecard!(rec)["completion"] == "confirmed"
            if reset!(rec, game_id)["completion"] == "confirmed"
                if isnothing(config.learning)
                    explore!(rec)
                else
                    if frozen
                        publication = TddESCat.read_published_stitch(TddESCat.store_path(store,"publication"))
                        TddESCat.atomic_json(TddESCat.store_path(store,"learning","evaluation-boundary.json"),
                            Dict("publication"=>isnothing(publication) ? nothing : publication.publication,
                                "knowledge_sha256"=>TddESCat.frozen_knowledge_digest(knowledge)))
                    end
                    event = TddESCat.read_json(TddESCat.store_path(store, "events", rec.before_ref * ".json"))
                    learned = TddESCat.run_online!(rec, (event=event, observation=rec.observation), config, ROOT;
                        knowledge,frozen)
                end
            end
            rec.frozen || close_scorecard!(rec)
        end
        events = recover_run(store)
        sequence = if !frozen && !isnothing(config.learning) && get(config.learning,"sequences",false)
            episodes = [events]
            corpus = TddESCat.compile_sequence_corpus(episodes)
            artifact = TddESCat.store_path(store,"learning","sequence-corpus.json")
            compiled = TddESCat.persist_sequence_corpus(episodes,artifact;corpus)
            searched = rec.frozen ? nothing : TddESCat.train_program_corpus!(knowledge,config,store,ROOT,corpus)
            merge(compiled,(; search=searched))
        end
        output = (recorded=length(events), requested_game_id=game_id, quarantined=rec.frozen, learned,
            prior_publication=prepared, sequence)
        TddESCat.atomic_json(TddESCat.store_path(store, "public-run.json"), output)
        return output
    end
end

function explore!(rec)
    attempts = zeros(Int, 7)
    click_cursor = 0
    while rec.sent_count < rec.limit && !rec.frozen
        obs = rec.observation
        available = obs.available_actions
        if isempty(available) || obs.state in ("WIN", "GAME_OVER")
            break
        end
        id = first(sort(available; by=candidate -> (attempts[candidate], candidate)))
        xy = id == 6 ? (x=mod(click_cursor, 64), y=mod(div(click_cursor, 64), 64)) : (;)
        command = TddESCat.command_id(rec.next_sequence)
        decision = Dict("schema_version" => 1, "command_id" => command,
            "before_ref" => rec.before_ref, "reason" => "least_attempted_public_action",
            "available_actions" => available, "action" => merge((id=id,), xy))
        TddESCat.atomic_json(TddESCat.store_path(rec.store, "decisions", command * ".json"), decision)
        result = submit_action!(rec, id; xy...)
        result["completion"] == "confirmed" || break
        attempts[id] += 1
        id == 6 && (click_cursor += 1)
    end
end

function main(args)
    if length(args) == 3 && first(args) == "--compile-sequences"
        println(JSON.json(TddESCat.compile_evidence_sequences(args[2],args[3])))
        return 0
    end
    if length(args) == 5 && first(args) == "--recover-learning" &&
            args[2] == "--config" && args[4] == "--public-dir"
        config = load_run_config(args[3])
        result = with_run(last(args)) do store
            TddESCat.recover_learning!(store,config,ROOT)
        end
        println(JSON.json(result))
        return isempty(result.pending) ? 0 : 1
    end
    if length(args) == 2 && first(args) == "--replay"
        isdir(last(args)) || throw(ArgumentError("Public run directory does not exist"))
        println(JSON.json(with_run(replay_run!, last(args))))
        return 0
    end
    supervised = !isempty(args) && first(args) == "--supervised"
    supervised && (args = args[2:end])
    if !(length(args) in (2, 4) && first(args) == "--config" &&
            (length(args) == 2 || args[3] == "--public-dir"))
        throw(ArgumentError("usage: run.jl --config <file> [--public-dir <dir>] | --replay <dir>"))
    end
    cfg = load_run_config(args[2])
    if cfg.execution["memory_enforcement"] == "cgroup_v2" && !supervised
        runtime = TOML.parsefile(joinpath(ROOT, "config", "runtime.local.toml"))
        python = runtime["python"]["executable"]
        arguments = ["--config", cfg.path]
        length(args) == 4 && append!(arguments, ["--public-dir", abspath(last(args))])
        return run(ignorestatus(Cmd([python, "-m", "tddesc_tools.public_run", arguments...]))).exitcode
    end
    !isnothing(cfg.learning) && !supervised && error("Learning requires supervised launch")
    public_dir = if length(args) == 4
        abspath(last(args))
    else
        mkpath(cfg.run_root)
        joinpath(mktempdir(cfg.run_root; prefix=cfg.run_name * "-", cleanup=false), "public")
    end
    result = capture(cfg, public_dir; supervised)
    println(JSON.json(result))
    return result.quarantined || result.recorded == 0 ? 1 : 0
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    exit(main(ARGS))
end
