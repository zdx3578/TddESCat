"""Read a real publication on held public layouts through the production controller."""

from dataclasses import replace
from hashlib import sha256
import json
from pathlib import Path
from shutil import copy2
import sys

from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import process_jobs
from tddesc_tools.run import append_assertion, read_task, runtime_paths, write_json
from tddesc_tools.stitch import build_identity

from tests.bench.check_evidence import solver_process
from tests.bench.check_online import online_config
from tests.bench.measurement_audit import receipts


def motif(point, background, ink):
    x0, y0 = point
    ink_cells = {(0, 0), (0, 1), (0, 2), (1, 2), (2, 2)}
    return tuple(
        (x0 + x, y0 + y, ink if (x, y) in ink_cells else background)
        for x in range(-1, 4)
        for y in range(-1, 4)
    )


def held_scenes(base):
    layouts = (
        ((9, 21), ((21, 21),), (37, 8), (9, 4, 13), False),
        ((13, 17), ((25, 17), (17, 29)), (42, 10), (11, 5, 14), False),
        ((13, 17), ((25, 17), (17, 29)), (42, 10), (11, 5, 14), True),
        ((13, 17), ((25, 17), (17, 29), (33, 25)), (42, 10), (11, 5, 14), False),
    )
    for i, (start, targets, cue, colors, refute) in enumerate(layouts):
        ink, background, role = colors
        moves = ((1, 4, 0), (2, -4, 0), (3, 0, 4), (4, 0, -4))
        moves = tuple((1 + (num + i - 1) % 4, x, y) for num, x, y in moves)
        board = motif(cue, background, ink)
        scene = replace(
            base,
            public_id=f"{base.public_id}WP{i}",
            logical_size=(64, 64),
            viewport=(0, 0, 64, 64),
            background=2,
            letterbox=2,
            active=(3, 3, 60, 60),
            start=(start,),
            static=board,
            bodies=(tuple((x, y, role) for x in range(3) for y in range(3)),),
            moves=moves,
        )
        target_draws = [motif(target, background, ink) for target in targets]
        yield scene, tuple(zip(targets, target_draws, strict=True)), refute


def materialize_held(root, layouts):
    materialize(root, [scene for scene, _, _ in layouts])
    for scene, targets, refute in layouts:
        file = root / scene.public_id / "fixture.py"
        original = file.read_text()
        file.write_text(
            original.replace(
                "        super().__init__",
                f"        self.targets = {dict(targets)!r}\n"
                "        self.resolved = set()\n"
                f"        self.refute_next = {refute!r}\n"
                "        super().__init__",
            )
            + """
    def _shift(self, dx, dy):
        origin = self.positions[0]
        point = (origin[0] + dx, origin[1] + dy)
        if self.refute_next and point in self.targets:
            self.refute_next = False
            return
        super()._shift(dx, dy)
        if self.positions[0] != origin and point in self.targets and point not in self.resolved:
            self.resolved.add(point)
            if len(self.resolved) == len(self.targets):
                self.next_level()

    def _render(self, **kwargs):
        super()._render(**kwargs)
        view = self.current_level.get_sprites()[0].pixels
        subject = self._footprint(0, *self.positions[0])
        for point, cells in self.targets.items():
            if point not in self.resolved:
                for x, y, color in cells:
                    if (x, y) not in subject:
                        view[y, x] = color
"""
        )


def read(path):
    return json.loads(path.read_bytes())


def export_training_prefix(source, cutoff, output):
    for folder in ("commands", "events", "predictions", "checks", "blobs"):
        (output / folder).mkdir(parents=True)
    commands = [
        p for p in sorted((source / "commands").glob("c*.json")) if p.stem <= cutoff
    ]
    assert commands and commands[-1].stem == cutoff
    if (source / "prior-events.json").is_file():
        copy2(source / "prior-events.json", output)
    for path in commands:
        row = read(path)
        copy2(path, output / "commands")
        if digest := row.get("response_blob"):
            assert len(digest) == 64 and all(c in "0123456789abcdef" for c in digest)
            copy2(source / "blobs" / digest, output / "blobs")
        if ref := row.get("event_id"):
            assert ref.endswith("-" + path.stem) and Path(ref).name == ref
            copy2(source / "events" / (ref + ".json"), output / "events")
            for folder in ("predictions", "checks"):
                payload = source / folder / path.name
                if payload.is_file():
                    copy2(payload, output / folder)
    assert read(commands[-1])["completion"] == "confirmed"
    return output


def audit_case(public, policy, targets, *, refuted):
    trace = receipts(public)
    allowed = {row["event_id"] for row in read(public / "prior-events.json")}
    use, supported = [], []
    removed = []
    expected_domain = set(targets)
    counterexample = followup = None
    for event, reply in trace.values():
        ref = event["event_id"]
        if event["action"]["id"] == 0:
            allowed.add(ref)
            continue
        file = event["command_ref"] + ".json"
        decision = read(public / "decisions" / file)
        check = read(public / "checks" / file)
        binding = decision.get("learned_policy")
        feedback = check.get("learned_policy_feedback")
        assert event["before_ref"] in allowed and decision["action"] == event["action"]
        allowed.add(ref)
        if binding:
            assert binding["definition"] == policy["definition"]
            assert binding["publication"] == policy["publication"]
            assert binding["available_after"] in allowed - {ref}
            assert set(binding["reads"]) <= allowed - {ref}
            assert {tuple(p) for p in binding["targets"]} == expected_domain
            assert tuple(binding["site"]) in targets
        if feedback:
            use.append((ref, feedback["result"], feedback["relation"], event["action"]))
            if feedback["result"] == "decreased":
                removal = tuple(feedback["site"])
                assert removal in targets
                expected_domain.remove(removal)
                removed.append(removal)
                assert any(
                    row["status"] in ("disappeared", "changed")
                    and tuple(row["point"]) == removal
                    for row in check["site_transitions"]
                )
                assert reply["frame"][-1][removal[1]][removal[0]] == 2
            if feedback["result"] == "stopped":
                assert reply["state"] == "WIN" and reply["levels_completed"] == 1
                supported.append(ref)
            if feedback["result"] == "refuted_branch":
                counterexample = (ref, event["action"])
        if counterexample and counterexample[0] != ref:
            assert binding is None and feedback is None
            if followup is None:
                assert event["before_ref"] == counterexample[0]
                assert decision["policy_counterexample"]["event"] == counterexample[0]
                assert event["action"] != counterexample[1]
                followup = dict(event=ref, action=event["action"])
    if refuted:
        assert counterexample and followup
        assert not supported
    else:
        assert len(supported) == 1
        assert len(removed) == len(targets) - 1
        assert any(relation == "discriminate" for _, _, relation, _ in use) == (
            len(targets) not in dict(policy["body"]["rows"])
        )
    assert {row["guid"] for _, row in trace.values()} == {
        list(trace.values())[-1][1]["guid"]
    }
    return dict(
        public=str(public),
        use=use,
        supported=supported,
        removed=removed,
        followup=followup,
    )


def main(config, run):
    root = Path.cwd()
    runtime = runtime_paths(root)
    task = read_task(config)
    base_plan = read_plan(task["judge_config"])
    base = next(
        s
        for s in scenes(base_plan, base_plan["training_seeds"][0])
        if s.variant == "open-square"
    )
    layouts = list(held_scenes(base))
    games, public = run / "private/games", run / "public"
    materialize_held(games, layouts)
    source = export_training_prefix(
        task["training_evidence"],
        task["training_cutoff"],
        run / "grade/training-prefix",
    )
    worker = root / "target/release/tddesc-stitch"
    prefs = root / "config/stitch.toml"
    policy_sha = sha256(prefs.read_bytes()).hexdigest()
    identity = build_identity(root, worker)
    write_json(
        public / "supervision.json",
        dict(policy_sha256=policy_sha, engine_identity=identity),
    )
    script = root / "tests/julia/learned_policy_public.jl"
    agent = task.get("agent_config", root / "config/autonomous_public.toml")

    def julia(mode, *extra, offline=False):
        proc = solver_process(
            root,
            runtime,
            public,
            mode,
            str(source),
            task["training_cutoff"],
            str(public),
            str(agent),
            *extra,
            script=script,
            extra_read=(
                source,
                agent,
                prefs,
                root / "Cargo.lock",
                root / "rust-toolchain.toml",
                root / "third_party/egg-stitch/UPSTREAM.toml",
            ),
            offline=offline,
            timeout=335,
        )
        (run / f"grade/{mode}.log").write_text(proc.stdout + proc.stderr)
        assert proc.returncode == 0, proc.stderr

    julia("prepare", offline=True)
    process_jobs(
        root,
        public,
        worker,
        identity["binary_sha256"],
        policy_sha,
        6 * 1024**3,
        None,
        set(),
    )
    with environment_server(
        root,
        runtime,
        task["environment_config"],
        games,
        run / "private/server",
        run / "grade/environment.log",
    ) as (url, _):
        held = []
        for index, (scene, _, _) in enumerate(layouts):
            path = public / f"held-{index}"
            path.mkdir()
            cfg = path / "agent.toml"
            online_config(cfg, root, url, scene, planning=True, budget=65)
            cfg.write_text(
                cfg.read_text() + "autonomous = true\nrelation_goals = true\n"
            )
            held.append(dict(config=str(cfg), public=str(path)))
        requests = public / "held-public.json"
        write_json(requests, held)
        julia("verify", str(requests))
    policy = read(public / "verified-policy.json")
    coverage = [
        audit_case(Path(row["public"]), policy, set(dict(targets)), refuted=refuted)
        for row, (_, targets, refuted) in zip(held, layouts, strict=True)
    ]
    hashes = [read(Path(row["public"]) / "frozen.json") for row in held]
    assert len({row["training_digest"] for row in hashes}) == 1
    assert len({row["frozen_before"] for row in hashes}) == 1
    write_json(
        public / "held-policy.json",
        dict(policy=policy, observed=coverage, frozen=hashes),
    )
    append_assertion(
        run, "published_policy_withheld_instances", True, ["public/held-policy.json"]
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*(Path(arg) for arg in sys.argv[1:])))
