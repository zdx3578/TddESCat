"""Read-only finite projection-prefix audit, not a proof of the full interpreter.

Recorded quantity inputs and local-support labels are reused. This audit does not
independently reconstruct the object interpreter, mechanism hashes or meters.
"""
import argparse
import hashlib
import json
import pathlib
import sys
import tomllib
from collections import defaultdict


def load(path):
    return json.loads(path.read_bytes())


def digest(frame):
    return hashlib.sha256(bytes(v for row in frame for v in row)).hexdigest()


def value(feature, trial):
    kind, item = feature
    if kind == "pixel":
        x, y = item
        f = trial["before"]
        return f[y][x] if 0 <= y < len(f) and 0 <= x < len(f[y]) else None
    if kind == "history":
        return tuple(trial["history"][-item:]) if len(trial["history"]) >= item else None
    return trial["quantities"][item] if item < len(trial["quantities"]) else None


def fit(trials, history_lengths):
    if not trials or all(t["outcome"] == "unchanged" for t in trials):
        return None
    features = {( "pixel", tuple(c[:2])) for t in trials for c in t["correction"]}
    features.update(("history", n) for n in history_lengths)
    features.update(("quantity", n) for n in range(min(len(t["quantities"]) for t in trials)))
    conditions = []
    if len({t["outcome"] for t in trials}) == 1:
        return conditions
    for feature in sorted(features, key=repr):
        values = [value(feature, t) for t in trials]
        if None in values or len(set(values)) < 2:
            continue
        relation = defaultdict(set)
        repeated = defaultdict(set)
        for v, t in zip(values, trials):
            relation[v].add(t["outcome"])
            repeated[v].add(digest(t["before"]))
        if any(len(s) != 1 for s in relation.values()) or max(map(len, repeated.values())) < 2:
            continue
        conditions.append((feature, {k: next(iter(v)) for k, v in relation.items()}, repeated))
    return conditions


def applicability(conditions, trial):
    if conditions is None:
        return "witnessed_base", "unchanged"
    if not conditions:
        return "unproved_projection_scope", None
    outcomes = []
    for feature, relation, repeated in conditions:
        v = value(feature, trial)
        if v is None or v not in relation or len(repeated[v]) < 2:
            return "unproved_projection_scope", None
        outcomes.append(relation[v])
    if len(set(outcomes)) != 1 or outcomes[0] == "unresolved":
        return "unproved_projection_scope", None
    return "conditioned_projection", outcomes[0]


def replay_writes(before, writes):
    frame = [r[:] for r in before]
    touched = set()
    for x, y, old, new in writes:
        if not (0 <= y < len(before) and 0 <= x < len(before[y])):
            raise ValueError("Projection write is outside the public frame")
        if before[y][x] != old or (x, y) in touched:
            raise ValueError("Projection write does not match its public input")
        touched.add((x, y))
        frame[y][x] = new
    return frame


def main(public, config):
    events = {r["event_id"]: load(public / r["event_file"]) for r in map(json.loads, (public / "events.jsonl").read_text().splitlines())}
    responses = {ref: load(public / "blobs" / e["response_blob"]) for ref, e in events.items()}
    scopes = defaultdict(list)
    history = []
    rows = []
    errors = []
    snapshots = {}
    history_lengths = config["history_lengths"]
    diagnostics = config["prefix_diagnostics"]
    snapshot_commands = {d["scope_after"] for d in diagnostics}
    for ref, event in sorted(events.items(), key=lambda pair: pair[1]["sequence"]):
        command = event["command_ref"]
        if event["action"]["id"] == 0:
            history = [0]
            continue
        path = public / "decisions" / (command + ".json")
        d = load(path) if path.is_file() else {}
        claim = d.get("projection")
        if claim is None:
            history.append(event["action"]["id"])
            continue
        feedback = load(public / "checks" / (command + ".json"))["projection"]
        before = responses[event["before_ref"]]["frame"][-1]
        actual = responses[ref]["frame"][-1]
        base = replay_writes(before, claim["base_writes"])
        expected = replay_writes(before, claim["projected_writes"])
        correction = [[x, y, before[y][x], base[y][x], v] for y, r in enumerate(actual) for x, v in enumerate(r) if v != base[y][x]]
        trial = dict(before=before, history=claim["history"], quantities=claim["quantities"], outcome=feedback["outcome"], correction=feedback["correction"], ref=ref, before_ref=event["before_ref"])
        prior = scopes[claim["contract"]]
        conditions = fit(prior, history_lengths)
        status, outcome = applicability(conditions, trial)
        if status == "conditioned_projection":
            adjustment = next(t["correction"] for t in prior if t["outcome"] == outcome)
            corrected = [r[:] for r in base]
            for x, y, old, old_base, new in adjustment:
                if before[y][x] != old or base[y][x] != old_base:
                    status = "projection_condition_binding_unknown"
                    corrected = base
                    break
                corrected[y][x] = new
            if corrected != expected:
                errors.append([command, "conditioned_pixels"])
        elif expected != base:
            errors.append([command, "base_pixels"])
        if status != claim["status"]:
            errors.append([command, "status", status, claim["status"]])
        if history != claim["history"]:
            errors.append([command, "history"])
        if feedback["outcome"] != "unresolved" and correction != feedback["correction"]:
            errors.append([command, "correction"])
        expected_reads = [] if conditions is None else sorted({r for t in prior for r in (t["before_ref"], t["ref"])})
        if expected_reads != claim["condition_reads"]:
            errors.append([command, "reads"])
        row = dict(command=command, contract=claim["contract"], status=status, outcome=feedback["outcome"], matching=feedback["matching"], local_supported=feedback["local_supported"], base_equals_projected=(base == expected), correction_cells=len(correction), prior_trials=len(prior), conditions=[{"feature": f, "input": value(f, trial), "repetitions": len(r.get(value(f, trial), set())), "predicted": m.get(value(f, trial))} for f,m,r in conditions or []])
        for diagnostic in diagnostics:
            if command != diagnostic["evaluate"]:
                continue
            source = diagnostic["scope_after"]
            if source not in snapshots or snapshots[source][0] != claim["contract"]:
                errors.append([command, "diagnostic_scope_unavailable", source])
                continue
            row.setdefault("prior_scope_diagnostics", []).append({
                "scope_after": source,
                "applicability": applicability(snapshots[source][1], trial),
            })
        rows.append(row)
        prior.append(trial)
        if command in snapshot_commands:
            snapshots[command] = (claim["contract"], fit(prior, history_lengths))
        history.append(event["action"]["id"])
    missing = set(config["diagnostic_events"]) - {r["command"] for r in rows}
    errors.extend([command, "diagnostic_event_missing"] for command in sorted(missing))
    return dict(public=str(public), audit_scope=__doc__.strip(), history_lengths=history_lengths, projection_count=len(rows), errors=errors, conditioned_nonempty=sum(r["status"] == "conditioned_projection" and not r["base_equals_projected"] for r in rows), chain=[r for r in rows if r["command"] in config["diagnostic_events"]], rows=rows)


def run_cli():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--public", required=True, type=pathlib.Path, help="Read-only public evidence directory")
    parser.add_argument("--config", required=True, type=pathlib.Path, help="Audit JSON configuration")
    parser.add_argument("--output", required=True, type=pathlib.Path, help="Result JSON outside the evidence package")
    args = parser.parse_args()
    try:
        public = args.public.resolve(strict=True)
        config_path = args.config.resolve(strict=True)
        output = args.output.resolve()
        if not public.is_dir():
            raise ValueError("--public must be a directory")
        if output.is_relative_to(public.parent):
            raise ValueError("--output must be outside the entire evidence package (public.parent)")
        if output in (config_path, pathlib.Path(__file__).resolve()):
            raise ValueError("--output cannot replace the audit configuration or script")
        if output.exists() and (not output.is_file() or output.stat().st_nlink > 1):
            raise ValueError("--output must be an unshared regular file")
        config = load(config_path)
        lengths = config["history_lengths"]
        if config["schema_version"] != 1 or not lengths or any(type(n) is not int or n <= 0 for n in lengths) or len(set(lengths)) != len(lengths):
            raise ValueError("Invalid audit schema or positive history lengths")
        source_path = (public / config["source_agent_config"]).resolve(strict=True)
        if not source_path.is_relative_to(public):
            raise ValueError("Source configuration must be inside the public evidence directory")
        with source_path.open("rb") as source:
            source_lengths = tomllib.load(source)["search"]["history_lengths"]
        if sorted(lengths) != sorted(n for n in source_lengths if n > 0):
            raise ValueError("Audit history lengths differ from the archived agent configuration")
        result = main(public, config)
        result["config_sha256"] = hashlib.sha256(config_path.read_bytes()).hexdigest()
        result["source_history_lengths"] = source_lengths
        output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({k: v for k, v in result.items() if k not in ("rows", "chain")}, ensure_ascii=False, indent=2))
        return 1 if result["errors"] else 0
    except Exception as exc:
        print(f"Projection audit failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(run_cli())
