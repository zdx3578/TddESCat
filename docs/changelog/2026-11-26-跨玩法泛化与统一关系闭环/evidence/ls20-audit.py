"""Read-only Python re-audit of a public ARC3 capture, without Julia or game execution."""
import argparse
import ast
import importlib.util
import json
import sys
import tomllib
import types
from collections import Counter
from hashlib import sha256
from pathlib import Path

sys.dont_write_bytecode = True


def read(path):
    return json.loads(path.read_bytes())


def count(values):
    return dict(Counter(values))


def main(args):
    repo, capture, output = args.repo.resolve(), args.evidence.resolve(), args.output.resolve()
    public = capture / "public"
    if output == capture or capture in output.parents or output in (args.config.resolve(), Path(__file__).resolve()):
        raise ValueError("Output must be outside the immutable evidence and must not replace a source/config file")
    if output.exists():
        raise ValueError("Output file must not already exist")
    config = read(args.config)
    for relative, expected in config["source_sha256"].items():
        if sha256((repo / relative).read_bytes()).hexdigest() != expected:
            raise ValueError("Pinned audit source differs: " + relative)
    for name, directory in [("tests", repo / "tests"), ("tests.bench", repo / "tests/bench")]:
        module = types.ModuleType(name)
        module.__path__ = [str(directory)]
        sys.modules[name] = module
    for name in ["autonomous_audit", "measurement_audit", "projection_audit", "program_audit", "policy_audit"]:
        full = "tests.bench." + name
        spec = importlib.util.spec_from_file_location(full, repo / "tests/bench" / (name + ".py"))
        module = importlib.util.module_from_spec(spec)
        sys.modules[full] = module
        spec.loader.exec_module(module)
    aa = sys.modules["tests.bench.autonomous_audit"]
    ma = sys.modules["tests.bench.measurement_audit"]
    pa = sys.modules["tests.bench.program_audit"]
    policy = sys.modules["tests.bench.policy_audit"]
    tree = ast.parse((repo / "tests/bench/check_real_public.py").read_text())
    function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "autonomous_report")
    def assigning(node, name):
        return isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets)
    start = next(i for i, n in enumerate(function.body) if assigning(n, "runtime"))
    end = next(i for i, n in enumerate(function.body) if assigning(n, "ledger"))
    # Execute only the Python audit body. The discarded preamble starts Julia and writes a log.
    function.body = function.body[:start] + function.body[end:]
    namespace = dict(vars(aa), json=json, tomllib=tomllib, Path=Path, PolicyAudit=policy.PolicyAudit)
    stored = read(public / "autonomous-verification.json")
    namespace["replay"] = types.SimpleNamespace(returncode=stored["replay_exit"])
    exec(compile(ast.fix_missing_locations(ast.Module(body=[function], type_ignores=[])), "pinned-python-auditor-no-julia", "exec"), namespace)
    index = read(public / "artifact-index.json")["files"]
    seen, index_errors = set(), []
    for item in index:
        path = capture / item["path"]
        if item["path"] in seen or not path.resolve().is_relative_to(capture):
            raise ValueError("Invalid duplicate or escaping indexed path")
        seen.add(item["path"])
        raw = path.read_bytes()
        if len(raw) != item["bytes"] or sha256(raw).hexdigest() != item["sha256"]:
            index_errors.append(item["path"])
    records = ma.receipts(public)
    report = namespace["autonomous_report"](repo, capture)
    program = pa.audit_live_goal_programs(public)
    events = list(records.values())
    actions, decisions, checks = [], [], []
    for descriptor, response in events:
        if response["action_input"]["id"] == 0:
            continue
        command = descriptor["command_ref"]
        actions.append((descriptor,response))
        decisions.append(read(public / "decisions" / (command + ".json")))
        checks.append(read(public / "checks" / (command + ".json")))
    tasks = report["relation_tasks"]
    uses = report["learned_policy_uses"]
    steps = [s for call in program["uses"] for s in call["steps"]]
    learned_task = any(
        done["outcome"] == "established" and any(
            early["level"] == done["level"] and early["model"] == done["model"]
            and early["producer"]["target"] == done["producer"]["target"]
            and early["outcome"] == "continue" and any(v == "missing" for _,v in early["requirements"])
            for early in tasks[:i])
        for i,done in enumerate(tasks)) and not report["audit_errors"]
    gates = {
        "autonomous_public_win": stored["solver_exit"] == 0 and report["passed"],
        "autonomous_learned_task": learned_task,
        "autonomous_goal_program": bool(program["uses"]) and bool(program["ordinary_choice_changed"]) and bool(program["cross_level"]) and not program["errors"],
        "autonomous_learned_policy": any(row["status"] == "stopped" for row in uses) and not report["audit_errors"],
    }
    policy_activations = []
    for file in sorted((public / "learning").glob("job-*/policy-publication.json")):
        activation = read(file)
        corpus = read(file.parent / "policy-corpus.json")
        for row in activation["policies"]:
            policy_activations.append({
                "job":file.parent.name,"definition":row["definition"],"publication":row["publication"],
                "available_after":row["available_after"],"model":row["model"],"body":row["body"],
                "training_events":row["training"],"episode_lengths":[len(e["actions"]) for e in corpus["episodes"]],
                "source_program_count":len(corpus["programs"]),
            })
    refs = [c for c in checks if c["definition_refs"]]
    supported = [c for c in refs if c["assessments"] and set(c["assessments"].values()) == {"supported"}]
    program_decisions = [d for d in decisions if d.get("program")]
    policy_decisions = [d for d in decisions if d.get("learned_policy")]
    task_decisions = [d for d in decisions if d.get("relation_task")]
    cohort_path = public / "learning/program-cohorts.json"
    cohort = read(cohort_path) if cohort_path.exists() else None
    def command_for(d):
        return d.get("command_ref",d.get("decision_id",d.get("before")))
    result = {
        "source_commit":config["source_commit"], "source_sha256":config["source_sha256"],
        "review_scope":{
            "executed":["indexed file size and SHA-256 verification","public receipt SHA-256 verification","pinned current Python autonomous audit including task and policy audit","pinned current Python program audit including projection prefix reconstruction","raw source and control records counted"],
            "not_executed":["game","Julia replay","Julia definition expansion proof","Rust search","fresh isolation probe","public24 raw trajectory audit"],
            "replay_exit_and_isolation_are_saved_author_results":True,
            "full_baseline_is_recorded_not_a_separate_Julia_rerun":True,
        },
        "manifest":read(public / "manifest.json"),
        "indexed_files":len(index),"index_errors":index_errors,
        "events":len(events),"actions":len(actions),"resets":len(events)-len(actions),
        "frames":sum(len(r["frame"]) for _,r in events),
        "action_ids":count(str(r["action_input"]["id"]) for _,r in actions),
        "final":{k:events[-1][1][k] for k in ("game_id","guid","state","levels_completed","win_levels")},
        "single_session":report["single_session"],"cold_start":report["cold_start"],
        "scorecard_win":report["scorecard_win"],
        "replay_ledger_all_events_in_order":[r["event_id"] for r in read(public / "replay.json")["applied_events"]] == list(records),
        "stored_replay_exit":stored["replay_exit"],
        "recomputed_gates":gates,"audit_errors":report["audit_errors"],"program_errors":program["errors"],
        "stored_report_different_keys":[k for k,v in report.items() if stored.get(k)!=v],
        "stored_program_different_keys":[k for k,v in program.items() if stored["program_control"].get(k)!=v],
        "program_calls":len(program["uses"]),"program_steps":len(steps),
        "program_ordinary_choice_changed":sum(s["selected"]!=s["ordinary"] for s in steps),
        "program_baseline_choice_changed":sum(s["selected"]!=s["baseline"] for s in steps),
        "program_cross_level":program["cross_level"],"program_relation_uses":program["relation_uses"],
        "program_dispositions":count(r["status"] for r in program["dispositions"]),
        "program_goal_contracts":count(d["program"]["goal"]["contract"] for d in program_decisions),
        "program_dependency_depths":count(str(c["program"]["depth"]) for c in checks if c.get("program")),
        "task_records":len(tasks),"task_levels":count(str(t["level"]) for t in tasks),
        "task_outcomes":count(t["outcome"] for t in tasks),
        "task_relations":count(t["relation"] for t in tasks),
        "task_rule_models":list({t["model"]:t["producer"]["advancement"] for t in tasks}.items()),
        "task_distinct_level_target_models":len({(t["level"],tuple(t["producer"]["target"]),t["model"]) for t in tasks}),
        "task_first":tasks[0] if tasks else None,
        "task_established":[t for t in tasks if t["outcome"]=="established"],
        "policy_records":len(uses),"policy_levels":count(str(t["level"]) for t in uses),
        "policy_relations":count(t["relation"] for t in uses),"policy_statuses":count(t["status"] for t in uses),
        "policy_target_cardinalities":count(str(len(t["targets"])) for t in uses),
        "policy_unique_definitions":sorted({t["definition"] for t in uses}),
        "policy_first":uses[0] if uses else None,"policy_last":uses[-1] if uses else None,
        "policy_activations":policy_activations,
        "decision_reasons":count(d["reason"] for d in decisions),
        "decisions_with_spatial":sum(bool(d.get("spatial_experiment")) for d in decisions),
        "policy_decisions_with_spatial":sum(bool(d.get("spatial_experiment")) for d in policy_decisions),
        "task_decisions_with_spatial":sum(bool(d.get("spatial_experiment")) for d in task_decisions),
        "policy_decisions_with_program":sum(bool(d.get("program")) for d in policy_decisions),
        "task_decisions_with_program":sum(bool(d.get("program")) for d in task_decisions),
        "policy_actions_different_from_recorded_spatial":sum(d["action"]["id"] != d["spatial_experiment"]["id"] for d in policy_decisions if d.get("spatial_experiment")),
        "task_actions_different_from_recorded_spatial":sum(d["action"]["id"] != d["spatial_experiment"]["id"] for d in task_decisions if d.get("spatial_experiment")),
        "definition_reference_actions":len(refs),"all_local_queries_supported":len(supported),
        "all_local_supported_with_residual":sum(bool(c["evidence"]["residual"]) for c in supported),
        "coverage_qualifications":count(c["coverage"]["qualification"] for c in checks),
        "cohort_statuses":count(g["status"] for g in cohort["groups"]) if cohort else None,
    }
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n")
    failed = index_errors or report["audit_errors"] or program["errors"] or not all(gates.values()) or result["stored_report_different_keys"] or result["stored_program_different_keys"]
    print(json.dumps({k:v for k,v in result.items() if k not in ("manifest","source_sha256","task_first","task_established","policy_activations","program_relation_uses")},ensure_ascii=False,indent=2))
    return int(bool(failed))


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ("repo","evidence","config","output"):
        parser.add_argument("--"+name,type=Path,required=True)
    try:
        raise SystemExit(main(parser.parse_args()))
    except (OSError,ValueError,KeyError,TypeError,AssertionError) as error:
        print(str(error),file=sys.stderr)
        raise SystemExit(2)
