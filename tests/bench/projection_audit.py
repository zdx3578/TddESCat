"""Reconstruct projection applicability from earlier responses in wire format."""

from collections import defaultdict
from hashlib import sha256
from itertools import product
import json

from tests.bench.autonomous_audit import require


def content(value):
    return sha256(
        json.dumps(value, separators=(",", ":"), sort_keys=True).encode()
    ).hexdigest()


def translate(patch, origin):
    dx, dy = origin
    return [(x + dx, y + dy, old, baseline, new) for x, y, old, baseline, new in patch]


def feature_value(feature, record):
    kind, index = feature
    if kind in ("pixel", "relative"):
        x, y = index
        if kind == "relative":
            if record["anchor"] is None:
                return None
            dx, dy = record["anchor"]
            x, y = x + dx, y + dy
        frame = record["frame"]
        if 0 <= y < len(frame) and 0 <= x < len(frame[y]):
            return frame[y][x]
    elif kind == "history":
        if len(record["history"]) >= index:
            return tuple(record["history"][-index:])
    elif kind == "quantity":
        if len(record["quantities"]) >= index:
            return record["quantities"][index - 1]
    elif kind == "meter":
        return record["meter_values"].get(index)
    elif kind == "joint":
        pair = tuple(feature_value(part, record) for part in index)
        if None not in pair:
            return pair
    return None


def fit_feature(feature, trials, outcomes, readings=None):
    readings = (
        [feature_value(feature, row) for row in trials]
        if readings is None
        else readings
    )
    if None in readings or len(set(readings)) <= 1:
        return None
    table, distinct = {}, defaultdict(set)
    for value, outcome, trial in zip(readings, outcomes, trials, strict=True):
        if table.setdefault(value, outcome) != outcome:
            return None
        distinct[value].add(trial["sha"])
    if max(map(len, distinct.values())) <= 1:
        return None
    return feature, table, distinct


def fit_scope(trials, lengths):
    relative_observations = defaultdict(set)
    anchored = all(row["anchor"] is not None for row in trials)
    if anchored:
        for row in trials:
            if row["patch"]:
                relative = translate(row["patch"], [-i for i in row["anchor"]])
                relative_observations[tuple(relative)].add(row["anchor"])
    relative = (
        relative_observations and min(map(len, relative_observations.values())) > 1
    )
    patches = [
        translate(row["patch"], [-i for i in row["anchor"]])
        if relative
        else row["patch"]
        for row in trials
    ]
    outcomes = [
        content(patch) if relative and patch else row["outcome"]
        for row, patch in zip(trials, patches, strict=True)
    ]
    corrections = {
        key: patch
        for key, patch in zip(outcomes, patches, strict=True)
        if key != "unresolved"
    }
    features = {
        ("relative" if relative else "pixel", (x, y))
        for patch in patches
        for x, y, *_ in patch
    }
    features.update(("history", n) for n in lengths if n)
    if any(row["channels"] for row in trials):
        features.update(
            ("meter", key)
            for key in set.intersection(*(set(row["channels"]) for row in trials))
        )
    else:
        features.update(
            ("quantity", i)
            for i in range(1, min(len(row["quantities"]) for row in trials) + 1)
        )
    conditions = []
    if len(set(outcomes)) > 1:
        conditions = [
            model for item in features if (model := fit_feature(item, trials, outcomes))
        ]
        if not conditions and anchored:
            h, w = len(trials[0]["frame"]), len(trials[0]["frame"][0])
            named = [(f, tuple(feature_value(f, r) for r in trials)) for f in features]
            named = [(f, values) for f, values in named if len(set(values)) > 1]
            if named and all(
                len(row["frame"]) == h and len(row["frame"][0]) == w for row in trials
            ):
                groups = defaultdict(list)
                for y, x in product(range(h), range(w)):
                    values = tuple(row["frame"][y][x] for row in trials)
                    if 1 < len(set(values)) < len(trials):
                        groups[values].append((x, y))
                for values, points in groups.items():
                    for f, inputs in named:
                        pairs = [
                            None if a is None else (a, b)
                            for a, b in zip(inputs, values, strict=True)
                        ]
                        key = ("joint", (f, ("pixel", points[0])))
                        if model := fit_feature(key, trials, outcomes, pairs):
                            _, table, distinct = model
                            conditions.extend(
                                (("joint", (f, ("pixel", point))), table, distinct)
                                for point in points
                            )
    return outcomes, corrections, relative, conditions


class ProjectionAuditor:
    def __init__(self, lengths):
        self.lengths = lengths
        self.previous = defaultdict(list)

    def check(self, claim, feedback, before, event, history, observed_meters):
        require(claim["history"] == history, "projection_history_prefix")
        frame = before["frame"][-1]
        parent = event["before_ref"]
        anchors, quantities, channels = [], [], []
        for binding in claim["bindings"]:
            family, port = binding["family"], binding["port"]
            if family == "measurement":
                number = observed_meters.get(port["instance"])
                require(number == port["value"], "unproved_projection_meter")
                quantities.append(number)
                channels.append(port["instance"])
                continue
            support = port["support"] if family == "count" else port
            require(
                all(
                    0 <= y < len(frame)
                    and 0 <= x < len(frame[y])
                    and frame[y][x] == color
                    for x, y, color in support
                ),
                "unproved_projection_support",
            )
            if family == "count":
                quantities.append(port["count"])
                channels.append(port["instance"])
            if family == "translation":
                anchors.append(
                    tuple(min(cell[i] for cell in support) for i in range(2))
                )
        require(quantities == claim["quantities"], "projection_quantity_bindings")
        origin = tuple(claim["anchor"]) if claim.get("anchor") is not None else None
        claimed_channels = claim.get("quantity_channels", [])
        if "anchor" in claim:
            require(
                origin == (anchors[0] if anchors else None), "projection_anchor_binding"
            )
            require(claimed_channels == channels, "projection_quantity_identity")
        trial = dict(
            frame=frame,
            anchor=origin,
            quantities=quantities,
            channels=claimed_channels,
            meter_values=dict(zip(claimed_channels, quantities)),
            history=history[:],
            sha=content(frame),
            before=parent,
            event=event["event_id"],
            outcome=feedback["outcome"],
            patch=feedback["correction"],
        )
        prior = self.previous[claim["contract"]]
        status, reads, patch = "witnessed_base", [], []
        if prior and any(row["outcome"] != "unchanged" for row in prior):
            _, corrections, relative, models = fit_scope(prior, self.lengths)
            status = "unproved_projection_scope"
            reads = sorted(
                {ref for row in prior for ref in (row["before"], row["event"])}
            )
            votes = []
            for f, table, distinct in models:
                value = feature_value(f, trial)
                votes.append(
                    table.get(value) if len(distinct.get(value, ())) > 1 else None
                )
            if votes and len(set(votes)) == 1 and votes[0] in corrections:
                patch = corrections[votes[0]]
                if relative:
                    require(origin is not None, "projection_missing_relative_anchor")
                    patch = translate(patch, origin)
                status = "conditioned_projection"
        require(
            claim["condition_reads"] == reads, "projection_complete_condition_reads"
        )
        if (
            status == "conditioned_projection"
            and claim["status"] == "projection_condition_binding_unknown"
        ):
            require(
                claim["projected_writes"] == claim["base_writes"],
                "unproved_projection_correction",
            )
        else:
            require(claim["status"] == status, "projection_scope_disagreement")
            writes = {(x, y): (old, new) for x, y, old, new in claim["base_writes"]}
            for x, y, old, baseline, new in patch:
                require(
                    0 <= y < len(frame)
                    and 0 <= x < len(frame[y])
                    and frame[y][x] == old
                    and writes.get((x, y), (old, old)) == (old, baseline),
                    "unbound_projection_correction",
                )
                if old == new:
                    writes.pop((x, y), None)
                else:
                    writes[x, y] = old, new
            require(
                writes
                == {(x, y): (old, new) for x, y, old, new in claim["projected_writes"]},
                "projection_reconstructed_patch",
            )
        prior.append(trial)
