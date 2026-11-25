"""Independently check the public witnesses used by the contact controller."""

from hashlib import sha256
from itertools import product
import json


COMPARISONS = ("extent", "support", "pigment", "cardinality")


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def decode_value(frame, field):
    x, y, w, h = (field["box"][k] for k in ("x", "y", "width", "height"))
    scale = field["scale"]
    if not (
        scale > 0
        and w > 0
        and h > 0
        and x >= 0
        and y >= 0
        and y + h <= len(frame)
        and x + w <= len(frame[0])
        and w % scale == h % scale == 0
    ):
        return None
    width, height = w // scale, h // scale
    pigment = None
    mask = 0
    for row, col in product(range(height), range(width)):
        px, py = x + col * scale, y + row * scale
        color = frame[py][px]
        if any(
            frame[py + dy][px + dx] != color
            for dy, dx in product(range(scale), repeat=2)
        ):
            return None
        if color == field["background"]:
            continue
        if pigment is not None and color != pigment:
            return None
        pigment = color
        mask |= 1 << (row * width + col)
    if pigment is None or width * height > 64:
        return None
    return {"width": width, "height": height, "mask": mask, "pigment": pigment}


def locate_role(frame, role):
    if not role:
        return None
    dx, dy, ink = role[0]
    height, width = len(frame), len(frame[0])
    found = None
    for py, row in enumerate(frame):
        for px, value in enumerate(row):
            if value != ink:
                continue
            x, y = px - dx, py - dy
            if all(
                0 <= y + v < height
                and 0 <= x + u < width
                and frame[y + v][x + u] == color
                for u, v, color in role
            ):
                if found is not None:
                    return None
                found = (x, y)
    return found


def signature(context, mark):
    extent = (context["width"], context["height"]) == (mark["width"], mark["height"])
    bits = (
        extent,
        extent and context["mask"] == mark["mask"],
        context["pigment"] == mark["pigment"],
        context["mask"].bit_count() == mark["mask"].bit_count(),
    )
    return sum(value << i for i, value in enumerate(bits))


def audit_site_geometry(point, field, role):
    box = field["box"]
    width = 1 + max(x for x, _, _ in role)
    height = 1 + max(y for _, y, _ in role)
    require(
        [2 * point[0] + width, 2 * point[1] + height]
        == [2 * box["x"] + box["width"], 2 * box["y"] + box["height"]],
        "site_role_geometry",
    )


def audit_site_facts(facts, receipts, level, role=None):
    points = set()
    for point, site in facts["remaining"]:
        require(tuple(point) not in points, "repeated_site_binding")
        points.add(tuple(point))
        receipt = receipts[site["event"]]
        require(receipt["levels_completed"] == level, "site_instance")
        require(
            decode_value(receipt["frame"][-1], site["field"]) == site["value"],
            "site_context_witness",
        )
        if role:
            audit_site_geometry(point, site["field"], role)
    return points


def audit_progress_sample(sample, before, after, receipts):
    facts = sample["facts"]
    require(
        facts["previous_action"] == before["action_input"]["id"], "progress_history"
    )
    require(sample["public_state"] == after["state"], "public_terminal_label")
    points = audit_site_facts(facts, receipts, sample["level"], sample["role"])
    require(tuple(sample["point"]) in points, "missing_contact_binding")
    require(
        [sample["point"], sample["site"]] in facts["remaining"],
        "substituted_site_context",
    )


def progress_variables(row, action):
    return {
        "remaining_sites": len(row["remaining"]),
        "action": action,
        "previous_action": row["previous_action"],
    }


def audit_progress_plan(plan, samples, reads, receipts, *, executing, before, action):
    progress = plan["progress"]
    facts = progress["facts"]
    points = audit_site_facts(facts, receipts, before["levels_completed"])
    require(tuple(plan["point"]) in points, "missing_progress_target")
    require(
        [plan["point"], plan["site"]] in facts["remaining"], "wrong_progress_target"
    )
    if executing:
        require(
            facts["previous_action"] == before["action_input"]["id"], "progress_history"
        )
        require(progress["action"] == action, "progress_action")

    entries = []
    for ref in receipts:
        sample = samples.get(ref)
        if sample and sample["outcome"] in ("entered", "progress"):
            entries.append(sample)
        if ref == plan["selected_at"]:
            break
    require(
        progress["sample_events"] == [entry["event"] for entry in entries],
        "omitted_progress_evidence",
    )
    sources = {site["event"] for _, site in facts["remaining"]}
    for entry in entries:
        sources.update((entry["event"], entry["before"]))
        sources.update(site["event"] for _, site in entry["facts"]["remaining"])
    require(sources == set(progress["reads"]) <= reads, "progress_reads")

    observed = {row["outcome"] == "progress" for row in entries}
    candidates = []
    inputs = progress_variables(facts, progress["action"])
    votes = []
    if observed == {False, True}:
        for variable, value in inputs.items():
            outcomes = {}
            for entry in entries:
                instant = progress_variables(entry["facts"], entry["action"])[variable]
                outcome = entry["outcome"] == "progress"
                if outcomes.setdefault(instant, outcome) != outcome:
                    break
            else:
                rows = [[key, flag] for key, flag in sorted(outcomes.items())]
                candidates.append({"variable": variable, "rows": rows})
                votes.append(outcomes.get(value))
    require(progress["rules"] == candidates, "progress_rules")
    body = [[row["variable"], row["rows"]] for row in candidates]
    model = None
    if body:
        model = (
            "progress-"
            + sha256(json.dumps(body, separators=(",", ":")).encode()).hexdigest()
        )
    require(progress["model"] == model, "progress_model_identity")
    verdict = "unknown"
    if votes and len(set(votes)) == 1 and votes[0] is not None:
        verdict = "progress" if votes[0] else "enter_only"
    require(progress["judgment"] == verdict, "progress_judgment")
    return verdict


def audit_contact_sample(sample, ref, before, after, receipts, parents):
    require(sample["event"] == ref and sample["before"] == parents[ref], "sample_event")
    require(sample["level"] == before["levels_completed"], "sample_level")
    action = after["action_input"]["id"]
    role = sample["role"]
    origin = locate_role(before["frame"][-1], role)
    require(
        origin is not None
        and list(origin) == sample["origin"]
        and action == sample["action"],
        "contact_binding",
    )
    witness = sample["motion_event"]
    movement = receipts[witness]
    require(movement["action_input"]["id"] == action, "motion_action")
    source = locate_role(receipts[parents[witness]]["frame"][-1], role)
    landing = next(
        (
            point
            for frame in movement["frame"]
            if (point := locate_role(frame, role)) not in (None, source)
        ),
        None,
    )
    require(source is not None and landing is not None, "motion_witness")
    point = tuple(o + b - a for o, a, b in zip(origin, source, landing, strict=True))
    require(list(point) == sample["point"], "projected_contact_point")
    site = sample["site"]
    audit_site_geometry(sample["point"], site["field"], role)
    value = decode_value(before["frame"][-1], site["field"])
    require(value is not None and value == site["value"], "contact_value")
    require(
        decode_value(receipts[site["event"]]["frame"][-1], site["field"]) == value,
        "site_witness",
    )
    context = decode_value(before["frame"][-1], sample["field"])
    require(context is not None and context == sample["context"], "context_witness")
    positions = [locate_role(frame, role) for frame in after["frame"]]
    progress = after["levels_completed"] > before["levels_completed"]
    outcome = sample["outcome"]
    require(
        (outcome == "progress" and progress and point in positions)
        or (outcome == "entered" and not progress and positions[-1] == point)
        or (
            outcome == "blocked"
            and not progress
            and all(p == origin for p in positions)
        ),
        "contact_outcome",
    )


def audit_contact_plan(plan, samples, reads, receipts, *, executing, before):
    site = plan["site"]
    require(site["event"] in reads, "contact_site_read")
    require(
        decode_value(receipts[site["event"]]["frame"][-1], site["field"])
        == site["value"],
        "planned_site_witness",
    )
    context = plan["context"]
    if executing:
        require(
            decode_value(before["frame"][-1], plan["field"]) == context,
            "planned_context_witness",
        )
    conditions = plan["conditions"]
    s = signature(context, site["value"])
    require(conditions["signature"] == s, "contact_signature")
    selected = plan["selected_at"]
    require(selected in reads, "contact_selection_read")
    prefix = {}
    for ref in receipts:
        if ref in samples:
            row = samples[ref]
            key = (
                signature(row["context"], row["site"]["value"]),
                row["outcome"] != "blocked",
            )
            prefix.setdefault(key, ref)
        if ref == selected:
            break
    require(
        conditions["sample_events"] == sorted(prefix.values()),
        "omitted_contact_evidence",
    )
    records = [samples[ref] for ref in conditions["sample_events"]]
    needed = {
        ref
        for row in records
        for ref in (
            row["event"],
            row["before"],
            row["site"]["event"],
            row["motion_event"],
        )
    }
    require(needed == set(conditions["reads"]) <= reads, "contact_training_reads")
    examples = {
        (signature(row["context"], row["site"]["value"]), row["outcome"] != "blocked")
        for row in records
    }

    def accepts(rule, bits):
        return all(
            state == 0 or (state == 1) == bool(bits & (1 << i))
            for i, state in enumerate(rule)
        )

    feasible = [
        rule
        for rule in product(range(3), repeat=len(COMPARISONS))
        if all(accepts(rule, bits) == allowed for bits, allowed in examples)
    ]
    actual = {
        tuple(
            1 if c in rule["same"] else 2 if c in rule["different"] else 0
            for c in COMPARISONS
        )
        for rule in conditions["rules"]
    }
    require(actual == set(feasible), "contact_rules")
    votes = {accepts(rule, s) for rule in feasible}
    judgment = "unknown"
    if examples and len(votes) == 1:
        judgment = "admitted" if True in votes else "blocked"
    require(judgment == conditions["judgment"], "contact_judgment")
    return judgment, {allowed for _, allowed in examples} == {False, True}
