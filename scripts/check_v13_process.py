"""Read confirmed Public25 transactions and check the formal completion gate."""

import argparse
from collections import Counter
from hashlib import sha256
import json
from pathlib import Path
import tomllib

from scripts.evaluate_public25 import ROOT
from tddesc_tools.run import read_task
from tests.bench.check_real_public import public_scorecard_win
from tests.bench.public_coverage import PublicCoverage, parameter_key


def load(path):
    return json.loads(path.read_bytes())


def require(condition, detail):
    if not condition:
        raise ValueError(detail)


def public_response(public, event):
    digest = event["response_blob"]
    raw = (public / "blobs" / digest).read_bytes()
    require(
        sha256(raw).hexdigest() == digest, f"Corrupted response for {event['event_id']}"
    )
    return json.loads(raw)


def replay_matches(public, receipts):
    path = public / "replay.json"
    if not path.is_file() or not receipts:
        return False
    replay = load(path)
    rows = [
        (row["event_id"], row["response_blob"], row["frame_count"])
        for row in replay["applied_events"]
    ]
    return rows == receipts and replay["through_event"] == receipts[-1][0]


def audit_case(public, game, report):
    coverage = PublicCoverage()
    counts = Counter()
    receipts = []
    guids = set()
    previous = None
    cold_start = False
    peak = 0
    # Command ordinals order receipts across every public RESET.
    paths = sorted(
        (public / "events").glob("*.json"),
        key=lambda p: int(p.stem.rsplit("-c", 1)[-1]),
    )
    for path in paths:
        event = load(path)
        ref = event["event_id"]
        parent = previous[0]["event_id"] if previous else None
        require(
            event["completion"] == "confirmed" and event["before_ref"] == parent,
            f"Broken confirmation chain at {ref}",
        )
        response = public_response(public, event)
        action = parameter_key(event["action"])
        require(
            response["game_id"] == game
            and parameter_key(response["action_input"]) == action,
            f"Public game or action differs at {ref}",
        )
        frames = response["frame"]
        shapes = [[len(frame), len(frame[0])] for frame in frames]
        require(
            event["frame_count"] == len(frames) and event["frame_shapes"] == shapes,
            f"Frame coverage differs at {ref}",
        )
        if not previous:
            require(action == (0,), f"{game} has no opening RESET")
            cold_start = response["levels_completed"] == 0
        counts["frames"] += len(frames)
        receipts.append((ref, event["response_blob"], len(frames)))
        peak = max(peak, response["levels_completed"])
        guids.add(response["guid"])
        coverage.observe(event, response)
        if action[0]:
            require(
                action[0] in previous[1]["available_actions"],
                f"Unavailable action at {ref}",
            )
            counts["actions"] += 1
            command = event["command_ref"] + ".json"
            decision_path = public / "decisions" / command
            check_path = public / "checks" / command
            if decision_path.is_file() and check_path.is_file():
                decision, check = load(decision_path), load(check_path)
                require(
                    decision["action"] == check["action"] == event["action"]
                    and decision["before_ref"] == parent
                    and check["event_ref"] == ref,
                    f"Decision or feedback differs at {ref}",
                )
                coverage.confirm(previous, event, response, decision, check)
                counts["decisions_checked"] += 1
            else:
                counts["pending_checks"] += 1
        else:
            counts["resets"] += 1
        previous = event, response

    terminal = previous[1] if previous else {}
    replay_verified = replay_matches(public, receipts)
    card_win, card = (
        public_scorecard_win(public, game, terminal)
        if terminal.get("state") == "WIN"
        else (False, None)
    )
    verified_win = (
        cold_start
        and len(guids) == 1
        and counts["actions"] > 0
        and not (public / "prior-events.json").exists()
        and terminal.get("state") == "WIN"
        and terminal["levels_completed"] == terminal["win_levels"] > 0
        and replay_verified
        and card_win
        and report.get("verdict") == "WIN"
        and report.get("verified") is True
        and report.get("worker_exit") == report.get("replay_exit") == 0
        and report.get("scorecard_sha256") == card
    )
    require(
        report.get("verdict") != "WIN" or verified_win, f"Unsupported WIN for {game}"
    )
    return {
        "game_id": game,
        "states": dict(counts),
        "peak_levels": peak,
        "latest_event": previous[0]["event_id"] if previous else None,
        "public_state": terminal.get("state"),
        "win_levels": terminal.get("win_levels"),
        "worker_verdict": report.get("verdict", "PENDING"),
        "replay_verified": replay_verified,
        "scorecard_win": card_win,
        "verified_win": verified_win,
        "causal_coverage": coverage.report(),
    }


def check_profile(path, game):
    profile = tomllib.loads(path.read_text(encoding="utf-8"))
    require(
        profile["environment"]["game_id"] == game
        and profile["execution"]["max_public_commands"] == "unlimited"
        and not profile["execution"].get("frozen_evaluation", False)
        and profile["planning"]["autonomous"] is True
        and "goal" not in profile["planning"]
        and "prior_evidence" not in profile["learning"],
        f"Public25 profile differs for {game}",
    )


def audit_campaign(directory, expected_revision):
    manifest = load(directory / "manifest.json")
    report = load(directory / "public25.json")
    catalog = read_task(ROOT / "config/acceptance/arc_public25.toml")["game_ids"]
    require(
        manifest["game_ids"] == catalog, "Public25 catalog differs from the fixed suite"
    )
    require(manifest["command_budget"] == "unlimited", "Public25 action budget differs")
    require(manifest["commit"] == expected_revision, "Public25 source revision differs")
    require(
        [row["game_id"] for row in report["games"]] == catalog,
        "Public25 report game IDs differ from its manifest",
    )
    results = []
    for game, verdict in zip(catalog, report["games"], strict=True):
        case = directory / game
        attempt = verdict.get("selected_attempt")
        require(attempt in (None, "transport-retry"), f"Unsupported attempt for {game}")
        if attempt:
            case = case / attempt
        check_profile(case / "agent.toml", game)
        actual_profile = case / "public/agent.toml"
        if actual_profile.is_file() or verdict.get("verdict") == "WIN":
            check_profile(actual_profile, game)
        results.append(audit_case(case / "public", game, verdict))
    wins = sum(case["verified_win"] for case in results)
    complete = wins == len(catalog) and report["status"] == "PASS"
    return {
        "revision": expected_revision,
        "solver_source_sha256": manifest["solver_source_sha256"],
        "P44": "PASS"
        if complete
        else "PENDING"
        if report["status"] == "IN_PROGRESS"
        else "FAIL",
        "verified_wins": wins,
        "games_started": sum(case["states"].get("actions", 0) > 0 for case in results),
        "confirmed_actions": sum(case["states"].get("actions", 0) for case in results),
        "confirmed_resets": sum(case["states"].get("resets", 0) for case in results),
        "games": results,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("campaign", type=Path)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    report = audit_campaign(args.campaign, args.revision)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return int(report["P44"] != "PASS")


if __name__ == "__main__":
    raise SystemExit(main())
