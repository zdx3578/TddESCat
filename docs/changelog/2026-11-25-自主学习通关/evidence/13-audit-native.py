"""Read-only independent re-audit of supplied evidence; never launches Julia or game."""
import ast
import argparse
import importlib.util
import json
import sys
import tomllib
import types
from collections import Counter
from hashlib import sha256
from pathlib import Path

sys.dont_write_bytecode = True

PARSER = argparse.ArgumentParser(description=__doc__)
PARSER.add_argument("--repo", required=True, type=Path, help="Read-only source checkout at the audited commit")
PARSER.add_argument("--optimized", required=True, type=Path, help="Extracted optimized-r04 evidence directory")
PARSER.add_argument("--official", required=True, type=Path, help="Extracted official-r02 evidence directory")
PARSER.add_argument("--output", required=True, type=Path, help="Separate output directory, outside both evidence inputs")
ARGS = PARSER.parse_args()
HERE = ARGS.repo.resolve()
OUT = ARGS.output.resolve()
RUNS = {"optimized_r04": ARGS.optimized.resolve(), "official_r02": ARGS.official.resolve()}
for root in RUNS.values():
    if OUT == root or root in OUT.parents:
        PARSER.error("The output directory must be outside both evidence input directories.")
OUT.mkdir(parents=True, exist_ok=True)
SOURCE_COMMIT = "19e9cf31de1e555da7f93928c8151780c77054c2"
SOURCE_HASHES = {
    "autonomous_audit.py": "4232c08f351f70d0a1cfc1ce392447545da06f72a7e5f0bdf0407b975844757a",
    "measurement_audit.py": "9c3caaa33fa5f80ea526e7959811c728fe7c5a358bdf85824af36f6d4413c98e",
    "program_audit.py": "95d11bda2f45f5492f7a9bb93f20ebbed6493b766913346d9fd389cf8d958eb3",
    "check_real_public.py": "3537de39db08260636d9e4b8c9b446ffc9a2cfab4245288c5cf7e196385a65d1",
}
for name, expected in SOURCE_HASHES.items():
    actual = sha256((HERE / "tests/bench" / name).read_bytes()).hexdigest()
    if actual != expected:
        PARSER.error("The audited source digest does not match the pinned commit: " + name)


def dump(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")


def read(path):
    return json.loads(path.read_bytes())


for name, directory in [("tests", HERE / "tests"), ("tests.bench", HERE / "tests/bench")]:
    mod = types.ModuleType(name)
    mod.__path__ = [str(directory)]
    sys.modules[name] = mod
for name in ["autonomous_audit", "measurement_audit", "program_audit"]:
    full = "tests.bench." + name
    spec = importlib.util.spec_from_file_location(full, HERE / "tests/bench" / (name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[full] = mod
    spec.loader.exec_module(mod)

aa = sys.modules["tests.bench.autonomous_audit"]
ma = sys.modules["tests.bench.measurement_audit"]
pa = sys.modules["tests.bench.program_audit"]

# Use the current committed Python auditor without executing its Julia replay
# preamble. Replay return code remains the author's stored result, marked below.
tree = ast.parse((HERE / "tests/bench/check_real_public.py").read_text())
fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "autonomous_report")
def assigning(statement, name):
    return isinstance(statement, ast.Assign) and any(isinstance(target, ast.Name) and target.id == name for target in statement.targets)
start = next(i for i, n in enumerate(fn.body) if assigning(n, "runtime"))
end = next(i for i, n in enumerate(fn.body) if assigning(n, "ledger"))
fn.body = fn.body[:start] + fn.body[end:]
namespace = dict(vars(aa), json=json, tomllib=tomllib, Path=Path)
namespace["replay"] = types.SimpleNamespace(returncode=0)
exec(compile(ast.fix_missing_locations(ast.Module(body=[fn], type_ignores=[])), "python-auditor-no-julia", "exec"), namespace)


def audit_run(label):
    root = RUNS[label]
    public = root / "public"
    index = read(public / "artifact-index.json")["files"]
    failures = []
    indexed = set()
    for entry in index:
        p = root / entry["path"]
        indexed.add(entry["path"])
        if not p.is_file():
            failures.append([entry["path"], "missing"])
            continue
        raw = p.read_bytes()
        if len(raw) != entry["bytes"] or sha256(raw).hexdigest() != entry["sha256"]:
            failures.append([entry["path"], "size_or_hash_mismatch"])
    extras = sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file() and str(p.relative_to(root)) not in indexed)
    records = ma.receipts(public)
    events = list(records.values())
    ledger = read(public / "replay.json")
    replay_ledger_matches = [r["event_id"] for r in ledger["applied_events"]] == list(records)
    stored = read(public / "autonomous-verification.json")
    namespace["replay"].returncode = stored["replay_exit"]
    report = namespace["autonomous_report"](HERE, root)
    program = pa.audit_live_goal_programs(public)
    dump(OUT / (label + "-autonomous-recomputed.json"), report)
    dump(OUT / (label + "-program-recomputed.json"), program)
    differences = [key for key, val in report.items() if stored.get(key) != val]
    stored_program = stored["program_control"]
    program_differences = [key for key, val in program.items() if stored_program.get(key) != val]
    checks = []
    decisions = []
    projection_rows = []
    full_baseline_different = []
    source_categories = Counter()
    for event, response in events:
        if not response["action_input"]["id"]:
            continue
        command = event["command_ref"]
        check = read(public / "checks" / (command + ".json"))
        decision = read(public / "decisions" / (command + ".json"))
        checks.append(check)
        decisions.append(decision)
        p = decision.get("program")
        spatial = decision.get("spatial_experiment")
        if p:
            source_categories["program"] += 1
            if decision["action"] != p["baseline_action"]:
                full_baseline_different.append(command)
        elif spatial:
            source_categories["direct_spatial"] += 1
            if decision["action"]["id"] != spatial["id"]:
                full_baseline_different.append(command)
        else:
            source_categories["without_spatial_or_program"] += 1
        if decision.get("projection"):
            claim = decision["projection"]
            feedback = check.get("projection", {})
            projection_rows.append({
                "command": command, "reason": decision["reason"],
                "status": claim.get("status"), "contract": claim.get("contract"),
                "rule_training_event": claim.get("rule_training_event"),
                "condition_reads": claim.get("condition_reads"),
                "matching": feedback.get("matching"),
                "outcome": feedback.get("outcome"),
                "local_supported": feedback.get("local_supported"),
                "inside_writes": len(feedback.get("inside_writes", [])),
                "outside_writes": len(feedback.get("outside_writes", [])),
                "public_changes": feedback.get("public_changes"),
                "program_feedback": (check.get("program") or {}).get("feedback"),
            })
    cohort = read(public / "learning/program-cohorts.json")
    cohort_counts = Counter(g["status"] for g in cohort["groups"])
    actions = Counter(str(r["action_input"]["id"]) for _, r in events)
    completed_steps = [s for u in program["uses"] for s in u["steps"]]
    projection = {
        "all_claims": len(projection_rows),
        "statuses": dict(Counter(x["status"] for x in projection_rows)),
        "outcomes": dict(Counter(str(x["outcome"]) for x in projection_rows)),
        "timeline_c107_to_c111": [x for x in projection_rows if "c000000107" <= x["command"] <= "c000000111"],
    }
    dump(OUT / (label + "-projection-records.json"), projection_rows)
    program_checks = [c for c in checks if c.get("program")]
    all_local_supported = [c for c in checks if c["definition_refs"] and set(c["assessments"].values()) == {"supported"}]
    summary = {
        "index_entries": len(index), "index_unique_paths": len(indexed),
        "index_bytes": sum(x["bytes"] for x in index), "index_errors": failures,
        "unindexed_files": extras,
        "manifest": read(public / "manifest.json"),
        "events": len(events), "actions_by_id": dict(actions),
        "replay_ledger_matches_all_events_in_order": replay_ledger_matches,
        "actions": sum(v for k,v in actions.items() if k != "0"),
        "resets": actions["0"], "actual_frames": sum(len(r["frame"]) for _,r in events),
        "descriptor_frames": sum(e["frame_count"] for e,_ in events),
        "guids": sorted({r["guid"] for _, r in events}),
        "final": {k: events[-1][1][k] for k in ["game_id","guid","state","levels_completed","win_levels"]},
        "python_autonomous_audit_passed": report["passed"],
        "python_autonomous_audit_errors": report["audit_errors"],
        "stored_autonomous_report_differences": differences,
        "julia_replay_executed_by_reviewer": False,
        "stored_replay_exit": stored["replay_exit"],
        "program_audit_errors": program["errors"],
        "stored_program_report_differences": program_differences,
        "completed_programs": len(program["uses"]), "completed_program_steps": len(completed_steps),
        "completed_program_ordinary_different": sum(s["selected"] != s["ordinary"] for s in completed_steps),
        "completed_program_baseline_different": sum(s["selected"] != s["baseline"] for s in completed_steps),
        "program_dispositions": dict(Counter(d["status"] for d in program["dispositions"])),
        "relation_program_uses": len(program["relation_uses"]),
        "program_cross_level": program["cross_level"],
        "program_contracts": dict(Counter(c["program"]["goal"]["contract"] for c in program_checks)),
        "program_step_lengths": dict(Counter(str(c["program"]["length"]) for c in program_checks)),
        "program_step_dependency_depths": dict(Counter(str(c["program"]["depth"]) for c in program_checks)),
        "decision_sources": dict(source_categories),
        "full_baseline_different_commands": full_baseline_different,
        "decision_reason_counts": dict(Counter(d["reason"] for d in decisions)),
        "check_with_definition_refs": sum(bool(c["definition_refs"]) for c in checks),
        "supported_structural_consumption": len(report["structural_consumption"]),
        "all_local_supported_with_nonempty_residual": sum(bool(c["evidence"]["residual"]) for c in all_local_supported),
        "all_local_supported_dependency_depths": dict(Counter(str(c.get("consumed_definition_depth")) for c in all_local_supported)),
        "coverage_qualifications": dict(Counter(c["coverage"]["qualification"] for c in checks)),
        "nonempty_checks_assessment_counts": dict(Counter(str(sorted(set(c["assessments"].values()))) for c in checks)),
        "consumed_definition_depths": dict(Counter(str(c.get("consumed_definition_depth")) for c in checks if c["definition_refs"])),
        "cohort_groups": len(cohort["groups"]), "cohort_statuses": dict(cohort_counts),
        "cohort_reported_counts": {k:v for k,v in cohort.items() if k != "groups"},
        "projection": projection,
        "projection_status_matching_counts": [dict(status=status, matching=matching, local_supported=local_supported, count=count)
            for (status, matching, local_supported), count in Counter((r["status"],r["matching"],r["local_supported"]) for r in projection_rows).items()],
        "base_projection_mismatching_commands": [r["command"] for r in projection_rows if r["status"] == "witnessed_base" and not r["matching"]],
    }
    dump(OUT / (label + "-summary.json"), summary)
    print(label, json.dumps({k:v for k,v in summary.items() if k not in ("unindexed_files", "manifest", "projection")}, ensure_ascii=False), flush=True)
    return summary, events


def compare(a, b):
    assert len(a) == len(b)
    ignored_response_keys = {"guid"}
    diffs = []
    for pos, ((ea, ra), (eb, rb)) in enumerate(zip(a, b, strict=True), 1):
        fields = {k for k in set(ra) | set(rb) if k not in ignored_response_keys and ra.get(k) != rb.get(k)}
        if fields:
            diffs.append({"position": pos,"command_a":ea["command_ref"],"command_b":eb["command_ref"],"fields":sorted(fields)})
    return {"events_compared":len(a),"all_response_fields_except_guid_compared":True,"differences":diffs,
            "frames_compared":sum(len(r["frame"]) for _,r in a),"guids_equal":a[0][1]["guid"]==b[0][1]["guid"]}


summaries = {}
event_sets = {}
for label in ["optimized_r04", "official_r02"]:
    summaries[label], event_sets[label] = audit_run(label)
comparison = compare(event_sets["optimized_r04"], event_sets["official_r02"])
dump(OUT / "cross-run-comparison.json", comparison)
print("comparison", json.dumps(comparison), flush=True)

compact = {
    "schema": 1,
    "source_commit": SOURCE_COMMIT,
    "source_sha256": {"tests/bench/" + k:v for k,v in SOURCE_HASHES.items()},
    "audit_scope": {
        "executed": ["all artifact-index sizes and hashes", "all public receipt hashes", "current autonomous_report Python audit body", "current audit_live_goal_programs", "all response field comparison except guid", "raw decision/check/cohort counting"],
        "not_executed": ["game", "Julia replay", "Julia proof expansion", "Rust search", "independent condition-fitting replay", "fresh OS isolation probe", "original worktree reconstruction"],
        "replay_exit_is_stored_author_result": True,
        "run_source_worktree_identity_to_source_commit_proved": False,
        "local_assessments_supported_does_not_mean_whole_frame_supported": True,
    },
    "runs": {},
    "comparison": comparison,
}
for label, summary in summaries.items():
    compact["runs"][label] = {k:v for k,v in summary.items() if k not in ("unindexed_files", "projection")}
    compact["runs"][label]["unindexed_files_count"] = len(summary["unindexed_files"])
    compact["runs"][label]["projection_claims"] = summary["projection"]["all_claims"]
    compact["runs"][label]["projection_timeline_c107_to_c111"] = summary["projection"]["timeline_c107_to_c111"]
dump(OUT / "compact-audit.json", compact)
