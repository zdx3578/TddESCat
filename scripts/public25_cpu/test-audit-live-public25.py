"""Check the sampler without accessing a live campaign or SDK."""
from pathlib import Path
import importlib.util
import json
import os
import tempfile

here = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("monitor", here / "audit-live-public25.py")
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)
runtime = Path(os.environ.get("TDDESC_TEST_RUNTIME", here.parents[1] / ".runtime")).resolve()
offline = runtime / "retired-public-runs-20261128/TddESCat-v13-eval-composed/runs/v13-public25-composed"
sdk = runtime / "v13-entrypoint-diagnostics/supervised-sdk/public"
won, small, never = "ls20-9607627b", "u754-000002f2", "idle-00000000"
archived = next(r for r in monitor.read(offline / "public25.json")["games"] if r["game_id"] == won)
scope = monitor.read(sdk / "supervision.json")["scope"]

def write(p, d):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(d))


# Confirm the field numbering against the real host; comm layout in the fixtures
# also covers a space and a literal right parenthesis.
me = monitor.thread_sample(Path("/proc/self/task") / str(os.getpid()))
assert me["flags"] and me["mask"] and me["tid"] == os.getpid()
def kernel_stat(task, comm="julia ) user", flags=0):
    task.joinpath("stat").write_text(f"{task.name} ({comm}) S 1 2 3 4 5 {flags} 7 8 9 10 2 3 0 0\n")


with tempfile.TemporaryDirectory() as tmp:
    root, proc = Path(tmp) / "run", Path(tmp) / "proc"
    assert monitor.snapshot(root)["state"] == "awaiting_plan"
    proc.mkdir()
    for path, source in ((root/"candidate"/won/"public", offline/won/"public"),
                         (root/"baseline"/small/"public", sdk)):
        path.parent.mkdir(parents=True)
        path.symlink_to(source, target_is_directory=True)
    plan = dict(arms={a:dict(game_ids=games, root="/test/revisions/"+a, commit=a)
                      for a,games in (("candidate",[won,never]), ("baseline",[small]))},
                cpu_assignment={"candidate/"+won:25, "baseline/"+small:26,"candidate/"+never:24})
    write(root/"plan.json",plan)
    write(root/"candidate/public25.json", {"games":[archived]})
    write(root/"launcher.json", {"submitted":{"baseline/"+small:{"unit":"pub25-campaign-case"}}})
    write(root/"candidate"/never/"grade/sdk-admission-server.json",{"state":"READY"})
    write(root/"candidate"/never/"grade/runner-started.json",{"pid":700,"assigned_cpu":24})
    statuses = {"pub25-campaign-case.service":{"Id":"pub25-campaign-case.service","ActiveState":"active","MainPID":"700"},
                scope:{"Id":scope,"ActiveState":"active"}}
    public = root/"baseline"/small/"public"
    def pid(pid, data, group=scope, masks=("26",), name="julia"):
        f=proc/str(pid)
        f.mkdir()
        (f/"comm").write_text(name+"\n")
        (f/"cmdline").write_bytes(b"\0".join(x.encode() for x in ["/usr/bin/"+name,*data])+b"\0")
        (f/"cgroup").write_text("0::/user.slice/"+group+"\n")
        for i,mask in enumerate(masks):
            t=f/"task"/str(pid+i)
            t.mkdir(parents=True)
            kernel_stat(t)
            (t/"status").write_text("State:\tS (sleeping)\nCpus_allowed_list:\t"+mask+"\n")
    args=["/test/revisions/baseline/scripts/run.jl","--supervised","--config","/case.toml","--public-dir",str(public)]
    pid(701,args,masks=("26","26"))
    pid(704,args,group="tddesc-solver-"+"f"*32+".scope")
    pid(705,args[:-1]+[str(root/"other")])
    pid(706,args,name="bwrap")
    pid(707,["/test/revisions/baseline/scripts/run.jl","--check-compute","/x"])
    sampled=monitor.snapshot(root,proc=proc,query=lambda _: (statuses,None))
    c,b=sampled["arms"]["candidate"],sampled["arms"]["baseline"]
    assert (c["summary"]["verified_wins"],c["summary"]["confirmed_resets"],
            c["summary"]["confirmed_actions"],c["summary"]["peak_levels_sum"])==(1,12,939,7)
    assert c["summary"]["games_with_reset"]==1 and c["summary"]["live_solver_pids"]==0
    assert b["summary"]["games_with_reset"]==b["summary"]["games_with_action"]==1
    assert b["summary"]["confirmed_resets"]==2 and b["summary"]["confirmed_actions"]==1
    assert b["summary"]["active_case_services"]==b["summary"]["live_solver_pids"]==1
    assert b["distinct_live_assigned_cpus"]==[26]
    assert b["cases"][0]["attempts"]["original"]["solver_processes"][0]["pid"]==701
    (proc/"701/task/702/status").write_text("State:\tS\nCpus_allowed_list:\t26-27\n")
    changed=monitor.snapshot(root,proc=proc,query=lambda _: (statuses,None))
    assert changed["arms"]["baseline"]["summary"]["live_solver_pids"]==1
    assert changed["arms"]["baseline"]["distinct_live_assigned_cpus"]==[]

    case_row=changed["arms"]["baseline"]["cases"][0]
    assert case_row["affinity"]["adjustable_threads_match"] is False
    assert case_row["affinity"]["all_threads_match"] is False
    helper=proc/"701/task/702"
    # The comm alone is insufficient. A wide ordinary worker still fails.
    kernel_stat(helper, "iou-sqp-701", flags=0)
    audit=lambda: monitor.snapshot(root,proc=proc,query=lambda _: (statuses,None))["arms"]["baseline"]
    assert audit()["cases"][0]["affinity"]["adjustable_threads_match"] is False
    kernel_stat(helper, "any ) helper", flags=monitor.PF_NO_SETAFFINITY)
    b=audit(); a=b["cases"][0]["affinity"]
    assert a == dict(adjustable_threads_match=True, all_threads_match=False, unknown_class_threads=0, wide_mask_protected_tids=[702])
    assert b["summary"]["wide_mask_protected_threads"]==1
    assert b["distinct_live_assigned_cpus"]==[26] and b["distinct_live_all_thread_cpus"]==[]
    process=b["cases"][0]["attempts"]["original"]["solver_processes"][0]
    assert process["thread_masks"]=={"26":1,"26-27":1} and process["adjustable_thread_masks"]=={"26":1}
    assert process["protected_threads"][0]["cpu_ticks"]==5 and process["protected_threads"][0]["comm"]=="any ) helper"
    (helper/"stat").unlink()
    b=audit()
    assert b["cases"][0]["affinity"]["adjustable_threads_match"] is None
    assert b["cases"][0]["affinity"]["all_threads_match"] is False
    assert b["summary"]["live_games_adjustable_mask_unknown"]==1 and not b["distinct_live_assigned_cpus"]
    # A known bad ordinary worker remains a counterexample even when a different
    # thread's kernel flags could not be read.
    (proc/"701/task/701/status").write_text("State:\tS\nCpus_allowed_list:\t26-27\n")
    assert audit()["cases"][0]["affinity"]["adjustable_threads_match"] is False

    # A claimed WIN without an authentic final scorecard or successful official replay cannot pass.
    for changes in (dict(scorecard_sha256="0"*64),dict(replay_exit=1)):
        candidate=monitor.receipt_counts(offline/won/"public",won,{**archived,**changes})
        assert not candidate["verified_win"] and candidate["action"]==939
    case=root/"baseline"/small
    retry=case/"transport-retry"/"public"
    retry.parent.mkdir()
    retry.symlink_to(sdk,target_is_directory=True)
    result=monitor.snapshot(root,proc=proc,query=lambda _: (statuses,None))["arms"]["baseline"]
    assert len(result["cases"][0]["attempts"])==2 and result["summary"]["games_with_reset"]==1
    assert result["summary"]["confirmed_actions"]==2
print("PASS: recorded WIN, live prefix, adjustable/protected/unknown thread flags and masks, exact scope/PID, SDK readiness, unverified WIN and retry accounting")
