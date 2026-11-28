"""Audit bounded omission opportunities from raw public responses and preregistered writer relations."""

import argparse
from collections import Counter
from functools import cache
from hashlib import sha256
import json
from pathlib import Path

from scripts.check_v13_process import public_response, require
from tests.bench.replay_competing_pointer import anchor, components


def digest(value):
    return sha256(json.dumps(value, separators=(",", ":")).encode()).hexdigest()


def template(role):
    color, cells = role
    x0, y0 = anchor(cells)
    return sorted((x - x0, y - y0, color) for x, y in cells)


def click_targets(groups, role, action):
    x, y = anchor(role[1])
    dx, dy = action["x"] - x, action["y"] - y
    pattern = template(role)
    targets = []
    for option in groups:
        if template(option) == pattern:
            u, v = anchor(option[1])
            if (u + dx, v + dy) in option[1]:
                targets.append((u + dx, v + dy))
    return targets


@cache
def read(public, ref):
    event = json.loads((public / "events" / (ref + ".json")).read_bytes())
    require(
        event["event_id"] == ref and event["completion"] == "confirmed",
        "Unconfirmed event",
    )
    return event, public_response(public, event)


@cache
def regions(public, ref):
    return frozenset(components(read(public, ref)[1]["frame"][-1]))


@cache
def changed_roles(public, ref):
    event, _ = read(public, ref)
    first, last = regions(public, event["before_ref"]), regions(public, ref)
    result = {}
    for old in first - last:
        a = anchor(old[1])
        pattern = template(old)
        for new in last - first:
            if old[1] == new[1]:
                family, values = "pigment", [old[0], new[0]]
            elif (
                old[0] == new[0]
                and len(old[1]) == len(new[1])
                and template(new) == pattern
            ):
                b = anchor(new[1])
                family, values = "translation", [b[0] - a[0], b[1] - a[1]]
            else:
                continue
            relation = family + "-" + digest([pattern, values])
            result.setdefault(relation, []).append((old, new))
    return result


def halo(cells, frame):
    h, w = len(frame), len(frame[0])
    return {
        (x + dx, y + dy)
        for x, y in cells
        for dx, dy in ((0, 0), (1, 0), (-1, 0), (0, 1), (0, -1))
        if 0 <= x + dx < w and 0 <= y + dy < h
    }


def changes(before, after):
    return [
        (x, y, a, b)
        for y, (s, t) in enumerate(zip(before, after, strict=True))
        for x, (a, b) in enumerate(zip(s, t, strict=True))
        if a != b
    ]


def archived_contact(public, before, command):
    raw = (public / "decisions" / (command + ".json")).read_bytes()
    decision = json.loads(raw)
    require(
        decision["before_ref"] == before,
        "Spatial alternative belongs to another prestate",
    )
    contact = decision.get("spatial_experiment", {}).get("contact")
    if not contact:
        return None
    conditions = contact["conditions"]
    context, target = contact["context"], contact["site"]["value"]
    extent = (context["width"], context["height"]) == (
        target["width"],
        target["height"],
    )
    comparisons = (
        ("extent", extent),
        ("support", extent and context["mask"] == target["mask"]),
        ("pigment", context["pigment"] == target["pigment"]),
        ("cardinality", context["mask"].bit_count() == target["mask"].bit_count()),
    )
    values = dict(comparisons)
    require(
        sum(1 << i for i, (_, truth) in enumerate(comparisons) if truth)
        == conditions["signature"],
        "Logged contact signature differs from the frozen bound values",
    )
    votes = [
        all(values[k] for k in rule["same"])
        and all(not values[k] for k in rule["different"])
        for rule in conditions["rules"]
    ]
    through = read(public, before)[0]["sequence"]
    samples = [read(public, ref)[0] for ref in conditions["sample_events"]]
    require(
        all(s["sequence"] <= through for s in samples), "Guard fit used a future sample"
    )
    return dict(
        decision_sha256=sha256(raw).hexdigest(),
        role=contact["point"],
        signature=conditions["signature"],
        judgment=conditions["judgment"],
        fitted_rules=len(votes),
        admitting=sum(votes),
        excluding=len(votes) - sum(votes),
        training=[
            {"event": s["event_id"], "response_sha256": s["response_blob"]}
            for s in samples
        ],
    )


def inspect(public, window):
    steps = window["steps"]
    first = window["first_event"]
    first_event, _ = read(public, first)
    require(
        first_event["response_blob"] == window["first_sha256"],
        "Initial response differs",
    )
    refs = [first] + [s["event"] for s in steps]
    tasks, known, strict = [], [], []
    tally = Counter()
    for index, step in enumerate(steps):
        here = refs[index]
        event, obs = read(public, here)
        frame = obs["frame"][-1]
        groups = regions(public, here)
        tentative = []
        for task in tasks:
            tally["pairs"] += 1
            src = task["source"]
            source_ev, source = read(public, src)
            if (
                source["guid"] != obs["guid"]
                or obs["state"] != "NOT_FINISHED"
                or obs["levels_completed"] != source["levels_completed"]
                or sorted(source["available_actions"])
                != sorted(obs["available_actions"])
            ):
                continue
            reference = source["frame"][-1]
            if len(frame) != len(reference) or len(frame[0]) != len(reference[0]):
                continue
            action = task["action"]
            if action["id"] not in obs["available_actions"]:
                continue
            protected = set()
            if action["id"] == 6:
                target = task["target"]
                bindings = click_targets(groups, target, action)
                if len(bindings) != 1 or bindings[0] != (action["x"], action["y"]):
                    continue
                protected |= halo(target[1], frame)
            if not all(old in groups for old, new in task["effects"]):
                continue
            tally["source_roles_present"] += 1
            for old, new in task["effects"]:
                protected |= halo(old[1] | new[1], frame)
            delta = changes(reference, frame)
            if not delta or any((x, y) in protected for x, y, a, b in delta):
                continue
            source_at = refs.index(src)
            # At a truncated first receipt the archived inbound action is outside this learner's history.
            if source_at == 0 or index == 0 or event["action"] != source_ev["action"]:
                known.append((task["issued"], here, False))
                continue
            if any(
                read(public, refs[j])[1]["state"] == "GAME_OVER"
                and read(public, refs[j])[0]["action"] == action
                and read(public, refs[j - 1])[0]["action"] == event["action"]
                and read(public, refs[j - 1])[1]["frame"][-1] == frame
                for j in range(1, index + 1)
            ):
                continue
            known.append((task["issued"], here, True))
            tentative.append(
                dict(
                    game=window["game"],
                    source=src,
                    source_sha256=source_ev["response_blob"],
                    issued=task["issued"],
                    issued_sha256=read(public, task["issued"])[0]["response_blob"],
                    before=here,
                    before_sha256=event["response_blob"],
                    offer=action,
                    domain=sorted(obs["available_actions"]),
                    matched_action_history=[event["action"]],
                    source_visible_history=source_at,
                    live_visible_history=index,
                    protected_cells=len(protected),
                    external_pixels=len(delta),
                    external_delta_sha256=digest(delta),
                    external_bounds_xyxy=[min(c[k] for c in delta) for k in (0, 1)]
                    + [max(c[k] for c in delta) for k in (0, 1)],
                    shifted_colors=[
                        [*pair, n]
                        for pair, n in Counter(
                            (a, b) for _, _, a, b in delta
                        ).most_common()
                    ],
                    writer_events=task["writer_events"],
                )
            )
        # Only now read the real outgoing action and response.
        outgoing, response = read(public, step["event"])
        require(
            outgoing["before_ref"] == here
            and outgoing["response_blob"] == step["response_sha256"],
            "Broken chronological receipt",
        )
        for match in tentative:
            match.update(
                archived_action=outgoing["action"],
                archived_event=step["event"],
                archived_response_sha256=outgoing["response_blob"],
                archived_contact=archived_contact(
                    public, here, outgoing["command_ref"]
                ),
            )
            strict.append(match)
        for plan in step["proposed"]:
            source = plan["observed_before"]
            require(
                source in refs[: index + 1] and plan["prepared_before"] == here,
                "Invalid proposal chronology",
            )
            roles = []
            writers = []
            for f in plan["candidates"]:
                origin = refs[f["writer"]]
                require(f["writer"] <= index and f["writer"] > 0, "Invalid writer")
                matches = changed_roles(public, origin).get(f["relation"], [])
                require(
                    len(matches) == 1,
                    f"Cannot independently identify {origin}/{f['relation']}: {len(matches)}",
                )
                roles.append(matches[0])
                writers.append(
                    dict(
                        event=origin,
                        port=f["output_port"],
                        relation=f["relation"],
                        response_sha256=read(public, origin)[0]["response_blob"],
                    )
                )
            target = None
            if plan["action"]["id"] == 6:
                point = plan["action"]["x"], plan["action"]["y"]
                target = next(role for role in groups if point in role[1])
            tasks.append(
                dict(
                    source=source,
                    issued=step["event"],
                    action=plan["action"],
                    effects=roles,
                    target=target,
                    writer_events=writers,
                )
            )
    tally["reconstructed_writer_references"] = sum(
        len(t["writer_events"]) for t in tasks
    )
    return tally, known, strict, len(tasks), sum(t["action"]["id"] == 6 for t in tasks)


def ambiguity_controls():
    # Same zero-based pixels as the independent Julia fixture's restored scene.
    source = [[0] * 18 for _ in range(18)]
    for x, y, c in ((2, 2, 2), (11, 7, 3), (2, 12, 5)):
        for dx in (0, 1):
            for dy in (0, 1):
                source[y + dy][x + dx] = c
    role = next(r for r in components(source) if (11, 7) in r[1])
    point = {"id": 6, "x": 11, "y": 7}
    variants = {}
    for name in ("unique", "ambiguous", "recolored_target"):
        variant = [line.copy() for line in source]
        variant[16][15:17] = [11, 11]
        if name == "ambiguous":
            for x, y in role[1]:
                variant[y][x - 4] = role[0]
        elif name == "recolored_target":
            for x, y in role[1]:
                variant[y][x] = 9
        bindings = sorted(click_targets(components(variant), role, point))
        expected = {
            "unique": [(11, 7)],
            "ambiguous": [(7, 7), (11, 7)],
            "recolored_target": [],
        }[name]
        require(bindings == expected, "Incorrect independent coordinate matching")
        variants[name] = dict(
            frame_sha256=digest(variant), bindings=bindings, unique=len(bindings) == 1
        )
    return variants


def compare_controller(report, run):
    controller = json.loads(run.read_bytes())
    require(
        controller["complete"] and len(controller["windows"]) == report["windows"],
        "Incomplete controller replay",
    )
    actual = {
        (w["game"], r["before"]): r
        for w in controller["windows"]
        for r in w["emissions"]
    }
    require(
        len(actual) == sum(len(w["emissions"]) for w in controller["windows"]),
        "Repeated controller emission at one prestate",
    )
    controls = []
    for witness in report["strict"]:
        live = actual.pop((witness["game"], witness["before"]), None)
        if live is None:
            continue
        require(
            live["source"] == witness["source"]
            and live["action"] == witness["offer"]
            and live["archived"]["action"] == witness["archived_action"],
            "Different historical bindings",
        )
        expanded = sorted(
            (
                (x, y, a, b)
                for y, start, stop, a, b in live["spans"]
                for x in range(start, stop + 1)
            ),
            key=lambda c: (c[1], c[0]),
        )
        require(
            digest(expanded) == witness["external_delta_sha256"],
            "Wrong external pixel difference",
        )
        controls.append(
            dict(
                before=witness["before"],
                intent=live["proposed"],
                winner=live["dispatched_intent"],
                chosen=live["choice"]["action"],
                chosen_source=live["choice"]["source"],
                chosen_reason=live["choice"]["reason"],
                archived_action=witness["archived_action"],
                counterfactual_difference=live["choice"]["action"]
                != witness["archived_action"],
            )
        )
    require(
        not actual,
        "Controller offered a binding outside the independently identified scope",
    )
    return dict(
        offers=controls,
        controller_sha256=sha256(run.read_bytes()).hexdigest(),
        new_dispatches=0,
    )


def audit(runs, windows):
    source = json.loads(windows.read_bytes())
    tally = Counter()
    known = []
    strict = []
    count = clicks = 0
    for window in source["windows"]:
        folders = [
            p
            for p in runs.glob("*/" + window["game"] + "/public")
            if (p / "events" / (window["first_event"] + ".json")).exists()
        ]
        require(len(folders) == 1, "Ambiguous archive selector")
        t, k, s, n, c = inspect(folders[0], window)
        tally.update(t)
        known.extend(k)
        strict.extend(s)
        count += n
        clicks += c
    return dict(
        window_report_sha256=sha256(windows.read_bytes()).hexdigest(),
        windows=len(source["windows"]),
        truncated_prefixes=sum(
            w["window_predecessor_unknown"] for w in source["windows"]
        ),
        observations=sum(len(w["steps"]) for w in source["windows"]),
        proposals=count,
        click_proposals=clicks,
        screening=dict(tally),
        with_restored_roles_and_external_changes=len(known),
        strict_history_opportunities=len(strict),
        strict=strict,
        difference_digest_encoding="SHA256 of row-major [x,y,old,new] entries encoded as compact JSON",
        ambiguous_click_controls=ambiguity_controls(),
        scope="Only the archived advancement windows were replayed. Hypothetical offers have no new outcome. Coordinate ambiguity uses separate fixture frames.",
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("windows", type=Path)
    parser.add_argument("--controller", type=Path)
    parser.add_argument("--previous-controller", type=Path)
    args = parser.parse_args()
    report = audit(args.archive, args.windows)
    root = Path(__file__).resolve().parents[2]
    files = (
        "julia/TddESCat/src/RelationUse.jl",
        "julia/TddESCat/src/RelationTasks.jl",
        "julia/TddESCat/src/PublicFrontier.jl",
        "tests/julia/replay_rebound_omissions.jl",
        "tests/bench/replay_omission_rebinding.py",
    )
    report["source_sha256"] = {
        name: sha256((root / name).read_bytes()).hexdigest() for name in files
    }
    if args.previous_controller:
        report["previous_arbitration"] = compare_controller(
            report, args.previous_controller
        )
    if args.controller:
        report["production_replay"] = compare_controller(report, args.controller)
    print(json.dumps(report, ensure_ascii=False, indent=2))
