"""Independently check the public witnesses used by the contact controller."""

from hashlib import sha256
from itertools import combinations, product
from math import gcd
import json


COMPARISONS = ("extent", "support", "pigment", "cardinality")
CONTACT_DOMAIN = "visible-site-obligations-v2"
OBSERVED_CONTACT_DOMAIN = "observed-site-obligations-v3"


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


def audit_site_facts(
    facts,
    receipts,
    level,
    role=None,
    *,
    domain=None,
    domain_reads=None,
    domain_version=None,
):
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
    if domain is not None:
        version = domain_version or CONTACT_DOMAIN
        require(facts.get("domain_version") == version, "site_domain_version")
        require(
            {tuple(point): site for point, site in facts["remaining"]} == domain,
            "incomplete_or_substituted_site_domain",
        )
    if domain_reads is not None:
        require(
            set(facts["domain_reads"]) == domain_reads <= receipts.keys(),
            "site_domain_reads",
        )
    return points


def audit_progress_sample(sample, before, after, receipts, *, site_domain=None):
    facts = sample["facts"]
    require(
        facts["previous_action"] == before["action_input"]["id"], "progress_history"
    )
    require(sample["public_state"] == after["state"], "public_terminal_label")
    audit_site_facts(
        facts,
        receipts,
        sample["level"],
        sample["role"],
        domain=None if site_domain is None else site_domain.remaining(),
        domain_reads=None if site_domain is None else site_domain.reads(),
        domain_version=None if site_domain is None else site_domain.version,
    )
    if site_domain is None:
        require(
            [sample["point"], sample["site"]] in facts["remaining"],
            "substituted_site_context",
        )
    else:
        require(
            site_domain.sites.get(tuple(sample["point"])) == sample["site"],
            "substituted_site_context",
        )


def progress_variables(row, action):
    return {
        "remaining_sites": len(row["remaining"]),
        "action": action,
        "previous_action": row["previous_action"],
    }


def audit_progress_plan(
    plan,
    samples,
    reads,
    receipts,
    *,
    executing,
    before,
    action,
    domain=None,
    domain_reads=None,
    domain_version=None,
):
    progress = plan["progress"]
    facts = progress["facts"]
    points = audit_site_facts(
        facts,
        receipts,
        before["levels_completed"],
        domain=domain,
        domain_reads=domain_reads,
        domain_version=domain_version,
    )
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
        outstanding = (
            sample and [sample["point"], sample["site"]] in sample["facts"]["remaining"]
        )
        if outstanding and sample["outcome"] in ("entered", "progress"):
            entries.append(sample)
        if ref == plan["selected_at"]:
            break
    require(
        progress["sample_events"] == [entry["event"] for entry in entries],
        "omitted_progress_evidence",
    )
    sources = {site["event"] for _, site in facts["remaining"]}
    sources.update(facts.get("domain_reads", ()))
    for entry in entries:
        sources.update((entry["event"], entry["before"]))
        sources.update(site["event"] for _, site in entry["facts"]["remaining"])
        sources.update(entry["facts"].get("domain_reads", ()))
    require(sources == set(progress["reads"]) <= reads, "progress_reads")

    observed = {row["outcome"] == "progress" for row in entries}
    candidates = []
    inputs = progress_variables(facts, progress["action"])
    votes = []
    if observed == {False, True}:
        widths = (
            (1, 2) if facts.get("domain_version") == OBSERVED_CONTACT_DOMAIN else (1,)
        )
        for width in widths:
            for variables in combinations(inputs, width):
                outcomes = {}
                for entry in entries:
                    row = progress_variables(entry["facts"], entry["action"])
                    instant = tuple(row[key] for key in variables)
                    outcome = entry["outcome"] == "progress"
                    if outcomes.setdefault(instant, outcome) != outcome:
                        break
                else:
                    rows = [
                        [key[0] if width == 1 else list(key), flag]
                        for key, flag in sorted(outcomes.items())
                    ]
                    variable = variables[0] if width == 1 else list(variables)
                    candidates.append({"variable": variable, "rows": rows})
                    votes.append(outcomes.get(tuple(inputs[key] for key in variables)))
            if candidates:
                break
    require(progress["rules"] == candidates, "progress_rules")
    body = [[row["variable"], row["rows"]] for row in candidates]
    if body and facts.get("domain_version") in (
        CONTACT_DOMAIN,
        OBSERVED_CONTACT_DOMAIN,
    ):
        body = [facts["domain_version"], body]
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


def contained_box(inner, outer):
    return (
        outer["x"] <= inner["x"]
        and outer["y"] <= inner["y"]
        and inner["x"] + inner["width"] <= outer["x"] + outer["width"]
        and inner["y"] + inner["height"] <= outer["y"] + outer["height"]
    )


def visible_motifs(frame, size_limit):
    height, width = len(frame), len(frame[0])
    found = {}
    for side in range(4, min(height, width, size_limit) + 1):
        for y in range(height - side + 1):
            for x in range(width - side + 1):
                right, bottom = x + side - 1, y + side - 1
                bg = frame[y][x]
                if not (
                    bg == frame[y][right] == frame[bottom][x] == frame[bottom][right]
                    and all(
                        frame[y][x + i]
                        == frame[bottom][x + i]
                        == frame[y + i][x]
                        == frame[y + i][right]
                        == bg
                        for i in range(1, side - 1)
                    )
                ):
                    continue
                ink = [
                    (a, b, frame[b][a])
                    for b in range(y + 1, bottom)
                    for a in range(x + 1, right)
                    if frame[b][a] != bg
                ]
                if len({c for _, _, c in ink}) != 1:
                    continue
                left, top = min(a for a, _, _ in ink), min(b for _, b, _ in ink)
                w = max(a for a, _, _ in ink) - left + 1
                h = max(b for _, b, _ in ink) - top + 1
                box = dict(x=left, y=top, width=w, height=h)
                for scale in range(gcd(w, h), 0, -1):
                    if min(w, h) < 2 * scale or w % scale or h % scale:
                        continue
                    field = dict(box=box, background=bg, scale=scale)
                    item = decode_value(frame, field)
                    if (
                        item
                        and 2
                        < item["mask"].bit_count()
                        < item["width"] * item["height"]
                    ):
                        found[(left, top, w, h, bg)] = (field, item)
                        break
    maximal = []
    for (_, _, w, h, bg), (field, item) in sorted(
        found.items(),
        key=lambda row: (
            -row[0][2] * row[0][3],
            row[0][1],
            row[0][0],
            row[0][2],
            row[0][3],
            row[0][4],
            row[1][1]["pigment"],
        ),
    ):
        if any(
            parent["background"] == bg
            and old["pigment"] == item["pigment"]
            and contained_box(field["box"], parent["box"])
            for parent, old in maximal
        ):
            continue
        maximal.append((field, item))
    return maximal


def contrasting_boundary(frame, field, max_margin):
    x, y, w, h = (field["box"][key] for key in ("x", "y", "width", "height"))
    for d in range(1, max_margin + 1):
        left, right, top, bottom = x - d, x + w + d - 1, y - d, y + h + d - 1
        if left < 0 or top < 0 or right >= len(frame[0]) or bottom >= len(frame):
            continue
        border = frame[top][left]
        if (
            border != field["background"]
            and all(
                frame[top][u] == frame[bottom][u] == border
                for u in range(left, right + 1)
            )
            and all(
                frame[v][left] == frame[v][right] == border
                for v in range(top, bottom + 1)
            )
        ):
            return True
    return False


class SiteDomain:
    """Replay the observable bound domain and its intervention lifecycle."""

    def __init__(self, version=CONTACT_DOMAIN):
        self.version = version
        self.field = None
        self.role = None
        self.sites = {}
        self.handled = set()
        self.detached = set()
        self.status = {}
        self.entries = {}

    def reset_attempt(self):
        self.handled.clear()
        self.detached.clear()
        self.status.clear()
        self.entries.clear()

    def reset_level(self):
        self.field = None
        self.role = None
        self.sites.clear()
        self.reset_attempt()

    def remaining(self):
        return {
            p: site
            for p, site in self.sites.items()
            if p not in self.handled and p not in self.detached
        }

    def reads(self):
        return {site["event"] for site in self.sites.values()} | set(
            self.status.values()
        )

    def entered(self, sample):
        if self.version == OBSERVED_CONTACT_DOMAIN:
            if sample["outcome"] == "entered":
                self.entries[tuple(sample["point"])] = sample["event"]
            return
        if sample["outcome"] != "blocked":
            point = tuple(sample["point"])
            self.handled.add(point)
            self.status[point] = sample["event"]

    def verify_site_transitions(self, ref, response, records):
        frame = response["frame"][-1]
        here = locate_role(frame, self.role) if self.role else None
        expected = []
        if here is not None:
            support = {(here[0] + x, here[1] + y) for x, y, _ in self.role}
            for point, entered in sorted(self.entries.items()):
                site = self.sites[point]
                field = site["field"]
                box = field["box"]
                x, y, w, h = (box[key] for key in ("x", "y", "width", "height"))
                if x < 0 or y < 0 or x + w > len(frame[0]) or y + h > len(frame):
                    continue
                cells = set(product(range(x, x + w), range(y, y + h)))
                if not cells.isdisjoint(support):
                    continue
                actual = decode_value(frame, field)
                if actual is None:
                    if not all(frame[v][u] == field["background"] for u, v in cells):
                        continue
                    result = "disappeared"
                elif actual != site["value"]:
                    result = "changed"
                else:
                    self.entries.pop(point)
                    if point not in self.handled:
                        continue
                    self.handled.remove(point)
                    result = "reopened"
                if result != "reopened":
                    if point in self.handled:
                        continue
                    self.handled.add(point)
                self.status[point] = ref
                expected.append(
                    dict(
                        point=list(point),
                        entered=entered,
                        observed=ref,
                        status=result,
                        site=site,
                        role=self.role,
                    )
                )
        require(records == expected, "unproved_or_missing_site_transition")

    def observe(self, surveys, receipts, level, *, frame_cache=None):
        for survey in surveys:
            ref = survey["event"]
            raw = receipts[ref]
            require(raw["levels_completed"] == level, "survey_level")
            frame = raw["frame"][-1]
            role = survey["role"]
            origin = tuple(survey["origin"])
            stride_x, stride_y = survey["stride"]
            require(
                locate_role(frame, role) == origin
                and 0 < stride_x <= len(frame[0])
                and 0 < stride_y <= len(frame),
                "survey_role_binding",
            )
            self.role = role
            w = 1 + max(x for x, _, _ in role)
            h = 1 + max(y for _, y, _ in role)
            occupied = {(origin[0] + u, origin[1] + v) for u, v, _ in role}
            for point, site in self.sites.items():
                field = site["field"]
                b = field["box"]
                right, bottom = b["x"] + b["width"], b["y"] + b["height"]
                if right > len(frame[0]) or bottom > len(frame):
                    continue
                cells = {
                    (u, v) for u in range(b["x"], right) for v in range(b["y"], bottom)
                }
                if (
                    point not in self.detached
                    and occupied.isdisjoint(cells)
                    and all(frame[v][u] == field["background"] for u, v in cells)
                ):
                    self.detached.add(point)
                    self.status[point] = ref
            maximal = 2 * max(w, h) + 1
            cache_key = (ref, maximal)
            if frame_cache is None:
                motifs = visible_motifs(frame, maximal)
            else:
                if cache_key not in frame_cache:
                    frame_cache[cache_key] = visible_motifs(frame, maximal)
                motifs = frame_cache[cache_key]
            windows, sites = [], {}
            for field, item in motifs:
                b = field["box"]
                center_x = 2 * b["x"] + b["width"] - w
                center_y = 2 * b["y"] + b["height"] - h
                p = (center_x // 2, center_y // 2)
                on_grid = (
                    center_x % 2 == center_y % 2 == 0
                    and (p[0] - origin[0]) % stride_x
                    == (p[1] - origin[1]) % stride_y
                    == 0
                )
                if not on_grid:
                    windows.append(field)
                elif (
                    b["width"] <= w
                    and b["height"] <= h
                    and contrasting_boundary(frame, field, max(w, h))
                ):
                    sites[p] = dict(field=field, value=item, event=ref)
            if not sites:
                continue
            if self.field is None:
                if not windows:
                    continue
                self.field = min(
                    windows,
                    key=lambda field: (
                        -field["box"]["width"] * field["box"]["height"],
                        field["box"]["y"],
                        field["box"]["x"],
                    ),
                )
            for point, site in sites.items():
                previous = self.sites.get(point)
                if (
                    point in self.detached
                    or previous is None
                    or any(previous[k] != site[k] for k in ("field", "value"))
                ):
                    self.sites[point] = site
                    self.handled.discard(point)
                    self.detached.discard(point)
                    self.entries.pop(point, None)
                    self.status[point] = ref


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
    history = []
    for ref in receipts:
        if ref in samples:
            row = samples[ref]
            history.append(row)
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
    scoped = history if not feasible else []
    require(
        conditions["scope_events"] == [row["event"] for row in scoped],
        "omitted_scoped_contact_evidence",
    )
    candidates = []
    if scoped:
        progress = plan["progress"]
        facts = progress["facts"]
        measures = {"signature": 0, **progress_variables(facts, progress["action"])}
        observed = []
        for row in scoped:
            needed.update(
                (row["event"], row["before"], row["site"]["event"], row["motion_event"])
            )
            needed.update(site["event"] for _, site in row["facts"]["remaining"])
            needed.update(row["facts"].get("domain_reads", ()))
            inputs = {"signature": 0, **progress_variables(row["facts"], row["action"])}
            observed.append(
                (
                    signature(row["context"], row["site"]["value"]),
                    inputs,
                    row["outcome"] != "blocked",
                )
            )
        for name, value in measures.items():
            outputs = {}
            for sig, inputs, admitted in observed:
                if outputs.setdefault((sig, inputs[name]), admitted) != admitted:
                    break
            else:
                rows = [[list(key), value] for key, value in sorted(outputs.items())]
                candidates.append({"variable": name, "rows": rows})
                votes.add(outputs.get((s, value)))
                if name == "signature":
                    break
    require(conditions["scope_rules"] == candidates, "scoped_contact_rules")
    require(needed == set(conditions["reads"]) <= reads, "contact_training_reads")
    judgment = "unknown"
    if examples and len(votes) == 1 and None not in votes:
        judgment = "admitted" if True in votes else "blocked"
    require(judgment == conditions["judgment"], "contact_judgment")
    return judgment, {allowed for _, allowed in examples} == {False, True}
