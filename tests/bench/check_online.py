"""Exercise discovery and consumption through the configured public entry point."""

import json
import sys
from dataclasses import replace
from pathlib import Path

from tddesc_env.bench import reference
from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_env.bench.grade import finite_engine_check
from tddesc_tools.contracts import Contracts
from tddesc_tools.isolation import environment_server, isolation_probe
from tddesc_tools.public_run import public_settings, solver_command, supervise
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json


def online_config(
    path,
    root,
    url,
    scene,
    *,
    budget=7,
    batch=3,
    prior=None,
    collection=False,
    planning=False,
    goal=None,
    adapt=False,
    association=False,
    sequences=False,
    background_search=False,
    policy_file=None,
    learning_memory_bytes=None,
    connect_timeout=2.0,
    request_timeout=5.0,
):
    prior_setting = "" if prior is None else f'prior_evidence = "{prior}"'
    execution = (
        'memory_enforcement = "cooperative"'
        if collection
        else 'memory_enforcement = "cgroup_v2"'
    )
    frozen = "false" if prior is None or adapt else "true"
    policy_file = root / "config/stitch.toml" if policy_file is None else policy_file
    memory = (
        ""
        if learning_memory_bytes is None
        else (f"learning_memory_bytes = {learning_memory_bytes}\n")
    )
    plan = "\n[planning]\n" if planning else ""
    if goal is not None:
        role_color, marker_color, *cues = goal
        cue = f"cue_color = {cues[0]}\n" if cues else ""
        gap = f"marker_gap = {cues[1]}\n" if len(cues) > 1 else ""
        plan = f"""\n[planning]
[planning.goal]
role_color = {role_color}
marker_color = {marker_color}
{cue}
{gap}
"""
    path.write_text(
        f'''schema_version = 2
run_name = "supervised"
run_root = "."
[environment]
base_url = "{url}"
competition_mode = false
game_selection = "explicit"
game_id = "{scene.public_id}"
connect_timeout_seconds = {connect_timeout}
request_timeout_seconds = {request_timeout}
[learning]
engine = "{root / "target/release/tddesc-stitch"}"
policy_file = "{policy_file}"
batch_confirmed_events = {batch}
association = {str(association).lower()}
sequences = {str(sequences).lower()}
background_search = {str(background_search).lower()}
{prior_setting}
[search]
context_radii = [1, 2, 4]
allow_full_frame_context = true
history_lengths = [0, 1, 2, 4]
max_action_coordinates = 512
[execution]
max_public_commands = {json.dumps(budget)}
one_inflight_per_guid = true
post_retry = false
redirect = false
frozen_evaluation = {frozen}
{execution}
{memory}
{plan}
''',
        encoding="utf-8",
    )


def load(folder, name):
    return json.loads((folder / name).read_bytes())


def verify_episode(root, episode, scene, channels):
    result = load(episode, "public-run.json")
    assert result["learned"]["publications"] and result["learned"]["models"] > 0
    supervisor = load(episode, "supervision.json")
    assert supervisor["state"] == "FINISHED" and supervisor["jobs"]
    assert "Maximum resident set size" in (episode / "solver-usage.txt").read_text()
    contracts = Contracts(root / "protocol/v1")
    state = scene.start_state
    for path in sorted((episode / "events").glob("*.json")):
        event = json.loads(path.read_bytes())
        contracts.validate("event", event)
        action = event["action"]
        arg = (6, action["x"], action["y"]) if action["id"] == 6 else action["id"]
        state = reference.transition(scene, state, arg)
        receipt = load(episode, "blobs/" + event["response_blob"])
        assert receipt["frame"] == [reference.render(scene, state)]
    successful = []
    for path in sorted((episode / "checks").glob("*.json")):
        checked = json.loads(path.read_bytes())
        if checked["expected"] and set(checked["assessments"].values()) == {
            "supported"
        }:
            successful.append(checked)
    assert successful and any(
        len(check["expected"]) == channels for check in successful
    ), successful
    assert all(check["definition_refs"] for check in successful)
    assert all(check["round_trip_seconds"] > 0 for check in successful)
    publication = load(
        episode, "publication/" + result["learned"]["publications"][0] + ".json"
    )
    cost = publication["cost"]
    assert int(cost["final_total"]) < int(cost["pre_rewrite_input"])
    return {
        "pub_id": result["learned"]["publications"][0],
        "proven": len(successful),
        "first_channels": successful[0]["expected"],
        "cost": cost,
    }


def main(task_path, run):
    root = Path.cwd()
    runtime = runtime_paths(root)
    task = read_task(task_path)
    plan = read_plan(task["judge_config"])
    by_name = {item.variant: item for item in scenes(plan, plan["training_seeds"][0])}
    # Bound the training experiment to one currently public direction.
    chosen = [
        replace(by_name[variant], moves=((1, 1, 0),))
        for variant in ("open-wide", "push-open")
    ]
    private = run / "private"
    games = private / "games"
    materialize(games, chosen)
    for scene in chosen:
        assert finite_engine_check(scene)["transitions"] > 0

    with environment_server(
        root,
        runtime,
        task["environment_config"],
        games,
        private / "server",
        run / "grade/environment.log",
    ) as (url, server_pid):
        for scene, channels in zip(chosen, [1, 2], strict=True):
            episode = run / "public" / scene.case
            episode.mkdir()
            config = episode / "agent.toml"
            online_config(config, root, url, scene)
            import tomllib

            paths = public_settings(root, config, tomllib.loads(config.read_text()))
            probe = isolation_probe(
                root,
                url,
                games / scene.public_id / "scene.json",
                private,
                server_pid,
                launch=lambda command: solver_command(
                    root, runtime, config, episode, paths, command=command
                ),
            )
            write_json(episode / "solver-isolation.json", probe)
            code = supervise(root, config, episode, expected_paths=paths)
            assert code == 0, (episode / "solver.log").read_text()
            verified = verify_episode(root, episode, scene, channels)
            write_json(episode / "verified.json", verified)
            append_assertion(
                run, scene.case, True, [f"public/{scene.case}/verified.json"]
            )


if __name__ == "__main__":
    main(*(Path(arg) for arg in sys.argv[1:]))
