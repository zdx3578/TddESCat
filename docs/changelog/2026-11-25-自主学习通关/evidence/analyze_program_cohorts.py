#!/usr/bin/env python3
"""只读重算当前程序分组候选和已提交快照；不启动游戏或搜索。

用法：
  python analyze_program_cohorts.py /path/to/public /path/to/result.json

按 1c921de7 的 ProgramSemantics.jl::program_step_key/next_program_corpus
重算哈希和同一段内的非重叠成员筛选。149 等数仅指该筛选器产生的候选族，
不代表完整 E-Stitch 抽象空间。审计输出写到显式目标，不改输入证据。
"""
from __future__ import annotations
import argparse
from collections import Counter
from hashlib import sha256
import json
from pathlib import Path

def load(p):
    return json.loads(p.read_bytes())

def digest(v):
    # ConceptIdentity.jl canonical_write: sorted object keys, compact arrays,
    # supported values in this evidence are strings/bools/integers/null.
    return sha256(json.dumps(v,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()

def step_hash(step):
    return digest([step["action"]["id"], [
        [e["family"], [] if e["family"]=="selection" else e["values"]]
        for e in step["effects"]]])

def cohort_hash(scope, lo, hi):
    return digest([[step_hash(s) for s in scope["steps"][lo:hi+1]],
                   scope["shared"][lo:hi]])

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("public",type=Path)
    ap.add_argument("output",type=Path)
    args=ap.parse_args()
    root=args.public.resolve()
    full=load(root/"learning/sequence-corpus.json")
    cohorts={}
    for index,scope in enumerate(full["scopes"],1):
        for lo in range(len(scope["steps"])):
            for hi in range(lo+1,len(scope["steps"])):
                key=cohort_hash(scope,lo,hi)
                members=cohorts.setdefault(key,[])
                # Julia uses inclusive 1-based start/stop.
                if not members or members[-1]["scope"]!=index or members[-1]["stop"]<lo+1:
                    members.append({"scope":index,"start":lo+1,"stop":hi+1,
                                    "events":scope["events"][lo:hi+1]})
    eligible={k:v for k,v in cohorts.items() if len(v)>1}
    jobs=[]
    by_cohort={}
    for folder in sorted((root/"learning").glob("job-*")):
        if not (folder/"sequence-corpus.json").is_file():
            continue
        corpus=load(folder/"sequence-corpus.json")
        sub=load(folder/"program-submission.json")
        assessment=load(folder/"assessment.json")
        calculated_snapshot=digest([corpus["programs"],corpus["slots"],corpus["scopes"]])
        assert calculated_snapshot==sub["key"]==assessment["key"], folder.name
        scopes=corpus["scopes"]
        keys=[cohort_hash(s,0,len(s["steps"])-1) for s in scopes]
        assert len(set(keys))==1, folder.name
        key=keys[0]
        assert key==corpus["cohort"]==assessment["cohort"], folder.name
        assert key in eligible, folder.name
        row={"job":folder.name,"cohort":key,"snapshot":calculated_snapshot,
             "length":len(scopes[0]["steps"]),"occurrences":len(scopes),
             "search_complete":assessment["search_complete"],
             "result":assessment["result"],
             "has_programs":bool(assessment.get("programs",[])),
             "worker_code":assessment["status"]["code"]}
        jobs.append(row)
        by_cohort.setdefault(key,[]).append(row)
    submitted=set(by_cohort)
    learned={r["cohort"] for r in jobs if r["has_programs"]}
    untouched=set(eligible)-submitted
    result={
        "review_source_commit":"1c921de7ab8458a378a487a66145528e272d1ff8",
        "run_manifest":load(root/"manifest.json"),
        "input_corpus_sha256":sha256((root/"learning/sequence-corpus.json").read_bytes()).hexdigest(),
        "summary":{
            "compiled_segments":len(full["scopes"]),
            "compiled_unique_actions":full["confirmed_program_actions"],
            "all_interval_pattern_types":len(cohorts),
            "eligible_repeated_cohorts":len(eligible),
            "submitted_cohorts":len(submitted),
            "submitted_snapshots":len({r["snapshot"] for r in jobs}),
            "submitted_jobs":len(jobs),
            "learned_cohorts":len(learned),
            "submitted_unlearned_cohorts":len(submitted-learned),
            "eligible_unsubmitted_cohorts":len(untouched),
            "unsubmitted_by_length":dict(sorted(Counter(len(eligible[k][0]["events"]) for k in untouched).items())),
            "submitted_jobs_by_length":dict(sorted(Counter(r["length"] for r in jobs).items())),
            "all_submitted_cohort_and_snapshot_hashes_match":True,
            "partial_publication_cohorts":[r["cohort"] for r in jobs if r["has_programs"] and not r["search_complete"]]
        },
        "jobs":jobs,
        "eligible_cohorts":[{"cohort":k,"length":len(v[0]["events"]),
             "members":v,"submitted_jobs":[r["job"] for r in by_cohort.get(k,[])],
             "status":"learned" if k in learned else "submitted_unlearned" if k in submitted else "unsubmitted"}
             for k,v in sorted(eligible.items())],
        "scope_limit":"候选域仅为当前精确步骤效果键与共享端口分组，不是所有参数化共同结构或全部程序空间。"
    }
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps(result["summary"],ensure_ascii=False,indent=2))

if __name__=="__main__":
    main()

