"""Compare the two actual effect consumers after a wide public observation."""

from dataclasses import replace

from tddesc_env.bench.build import materialize, read_plan, scenes
from tddesc_env.bench.grade import http_trace
from tddesc_tools.isolation import environment_server
from tddesc_tools.public_run import supervise
from tddesc_tools.run import write_json
from tests.bench.check_online import load, online_config


def check_open_matches(root, runtime, run):
    plan = read_plan(root / "config/bench_scenarios.toml")
    table = {scene.variant: scene for scene in scenes(plan, plan["training_seeds"][0])}
    template = table["resource-one"]
    body = template.bodies[0]
    used = {template.background, template.letterbox, template.resource.color}
    used.update(color for _, _, color in body)
    background_marker = next(color for color in range(16) if color not in used)
    scene = replace(
        template,
        public_id=template.public_id + "7",
        variant="wide-matching",
        logical_size=(64, 64),
        viewport=(0, 0, 64, 64),
        active=(0, 0, 64, 64),
        bodies=(body, body),
        start=((3, 6), (17, 6)),
        moves=((1, 1, 0),),
        static=tuple(
            (x, y, background_marker) for y in range(25, 61, 2) for x in range(0, 63, 2)
        ),
        blocked=(),
        holes=(),
        dynamics="autonomous",
        resource=replace(
            template.resource, panel=(55, 8), gate_cells=((5, 6),), initial=1
        ),
        prefix=(1,),
    )
    games = run / "private/wide-matching-games"
    materialize(games, [scene])
    public = run / "public/open-matches"
    public.mkdir()
    with environment_server(
        root,
        runtime,
        root / "config/bench_server.toml",
        games,
        run / "private/wide-matching-server",
        run / "grade/wide-matching-http.log",
    ) as (url, _):
        _, trace = http_trace(url, scene)
        write_json(run / "grade/wide-matching-oracle.json", trace)
        agent = public / "agent.toml"
        online_config(agent, root, url, scene, budget=2, batch=1)
        assert supervise(root, agent, public) == 0, (public / "solver.log").read_text()

    (checked,) = sorted((public / "checks").glob("*.json"))
    actual = load(public, checked.relative_to(public))["evidence"]
    reference = load(public, "learning/job-000001/observations.json")
    (offline,) = reference["events"]
    assert actual == offline, (
        "Online feedback and offline corpus interpreted different witnesses"
    )
    assert actual["candidate_roles"] > 512
    assert "competing_support_correspondences" in actual["alternatives"]
    assert [effect["family"] for effect in actual["effects"]] == ["count"]
    assert actual["effects"][0]["values"] == [-1]
    assert (
        reference["dispositions"][actual["event_ref"]]
        == "compiled_with_unresolved_interpretation"
    )
    assert reference["scope_complete"] is False
    summary = load(public, "learning/job-000001/output/learning-summary.json")
    assert summary["fixed_point"] is False
    assert summary["termination_reason"] == "input_scope_incomplete"
    write_json(
        public / "summary.json",
        {
            "candidate_roles": actual["candidate_roles"],
            "event_ref": actual["event_ref"],
            "checks": checked.relative_to(public).as_posix(),
            "corpus": "learning/job-000001/observations.json",
            "legitimate_effects": actual["effects"],
            "unresolved": actual["alternatives"],
        },
    )
