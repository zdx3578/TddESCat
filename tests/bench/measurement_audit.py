"""Rebuild visible meter bindings from confirmed public frames."""

import json
from collections import Counter
from hashlib import sha256
from pathlib import Path


METHOD = "rectangular-strip-v1"
UNIT = "complete-cross-section"


def receipts(folder):
    result = {}
    for path in sorted(
        (folder / "events").glob("*.json"),
        key=lambda path: json.loads(path.read_bytes())["sequence"],
    ):
        event = json.loads(path.read_bytes())
        assert event["completion"] == "confirmed"
        raw = (folder / "blobs" / event["response_blob"]).read_bytes()
        assert sha256(raw).hexdigest() == event["response_blob"]
        result[event["event_id"]] = (event, json.loads(raw))
    return result


def rectangle(box):
    x, y, width, height = box
    return {(u, v) for u in range(x, x + width) for v in range(y, y + height)}


def rim(frame, box):
    x, y, w, h = box
    if x < 1 or y < 1 or y + h >= len(frame) or x + w >= len(frame[0]):
        return None
    colors = {
        frame[v][u] for u, v in rectangle((x - 1, y - 1, w + 2, h + 2)) - rectangle(box)
    }
    return next(iter(colors)) if len(colors) == 1 else None


def full_faces(frame):
    """Enumerate maximal runs with a visible complete enclosing rim."""
    height, width = len(frame), len(frame[0])
    seen = set()
    for y, row in enumerate(frame):
        for x, ink in enumerate(row):
            if (x, y) in seen:
                continue
            cells, agenda = {(x, y)}, [(x, y)]
            seen.add((x, y))
            for u, v in agenda:
                for a, b in ((u - 1, v), (u + 1, v), (u, v - 1), (u, v + 1)):
                    if (
                        0 <= a < width
                        and 0 <= b < height
                        and (a, b) not in seen
                        and frame[b][a] == ink
                    ):
                        seen.add((a, b))
                        cells.add((a, b))
                        agenda.append((a, b))
            left, top = min(u for u, _ in cells), min(v for _, v in cells)
            w = 1 + max(u for u, _ in cells) - left
            h = 1 + max(v for _, v in cells) - top
            if w * h != len(cells) or max(w, h) < 4 * min(w, h):
                continue
            box = (left, top, w, h)
            border = rim(frame, box)
            if border not in (None, ink):
                yield box, ink, border


def stripes(box):
    x, y, w, h = box
    if w > h:
        return [[(u, v) for v in range(y, y + h)] for u in range(x, x + w)]
    return [[(u, v) for u in range(x, x + w)] for v in range(y, y + h)]


def read_colors(frame, box, border):
    if rim(frame, box) != border:
        return None
    lanes = [{frame[y][x] for x, y in row} for row in stripes(box)]
    if all(len(row) == 1 for row in lanes):
        return [next(iter(row)) for row in lanes]
    return None


def value(row, fill, blank, from_end):
    if row is None:
        return None
    n = row.count(fill)
    if (row[::-1] if from_end else row) == [fill] * n + [blank] * (len(row) - n):
        return n
    return None


def identity(box, fill, border, source, blank, from_end):
    model = [METHOD, UNIT, list(box), source, fill, border, blank, from_end]
    return sha256(json.dumps(model, separators=(",", ":")).encode()).hexdigest()


def replay_meters(events):
    faces, bindings, result = {}, {}, {}
    for ref, (event, after) in events.items():
        before_ref = event["before_ref"]
        if not event["action"]["id"] or before_ref not in events:
            faces.clear()
            bindings.clear()
            continue
        _, before = events[before_ref]
        if before["levels_completed"] != after["levels_completed"]:
            faces.clear()
            bindings.clear()
            result[ref] = {}
            continue
        start, *tail = before["frame"][-1], *after["frame"]
        for box, fill, border in full_faces(start):
            faces.setdefault(box, (fill, border, before_ref))
        changes = {}
        for box, (fill, border, source) in faces.items():
            profile = [read_colors(frame, box, border) for frame in (start, *tail)]
            if None in profile:
                continue
            if box not in bindings:
                blanks = {color for row in profile for color in row} - {fill}
                if len(blanks) != 1 or border in blanks:
                    continue
                (blank,) = blanks
                directions = [
                    end
                    for end in (False, True)
                    if all(value(row, fill, blank, end) is not None for row in profile)
                ]
                if len(directions) != 1:
                    continue
                bindings[box] = (blank, directions[0], ref)
            blank, end, calibrated_at = bindings[box]
            readings = [value(row, fill, blank, end) for row in profile]
            if None in readings or readings[0] == readings[-1]:
                continue
            first, last = profile[0], profile[-1]
            pixels = sorted(
                p
                for i, lane in enumerate(stripes(box))
                if first[i] != last[i]
                for p in lane
            )
            key = identity(box, fill, border, source, blank, end)
            changes[key] = (readings, pixels, {source, calibrated_at, before_ref, ref})
        result[ref] = changes
    return result


def verify_step(row, expected):
    actual = {}
    for effect in row["effects"]:
        if effect["family"] != "measurement":
            continue
        ctx = effect["context"]
        key = ctx["instance"]
        assert key in expected and key not in actual
        assert ctx["measurement"] == {"method": METHOD, "unit": UNIT}
        readings = [ctx["before_value"], *ctx["response_values"]]
        assert ctx["after_value"] == readings[-1]
        assert effect["values"] == [readings[-1] - readings[0]]
        actual[key] = (readings, list(map(tuple, effect["changed"])), set(ctx["reads"]))
    assert actual == expected, (row["event_ref"], actual, expected)


def audit_corpus(folder, corpus):
    events = receipts(folder)
    measured = replay_meters(events)
    steps = [step for scope in corpus["scopes"] for step in scope["steps"]]
    compiled = {step["event_ref"] for step in steps}
    assert len(compiled) == len(steps) == corpus["confirmed_program_actions"]
    dispositions = {row["event_ref"]: row for row in corpus["obligations"]}
    dispositions.update((step["event_ref"], step) for step in steps)
    outcomes = Counter()
    rows = []
    for ref, expected in measured.items():
        row = dispositions[ref]
        verify_step(row, expected)
        event, after = events[ref]
        _, before = events[event["before_ref"]]
        a, b = before["frame"][-1], after["frame"][-1]
        if len(a) == len(b) and len(a[0]) == len(b[0]):
            changed = {
                (x, y)
                for y, (left, right) in enumerate(zip(a, b, strict=True))
                for x, (old, new) in enumerate(zip(left, right, strict=True))
                if old != new
            }
            covered = {tuple(p) for effect in row["effects"] for p in effect["changed"]}
            assert covered <= changed
            assert {tuple(p) for p in row["unexplained"]} == changed - covered
        reason = "compiled" if ref in compiled else row["reason"]
        outcomes[reason] += 1
        rows.append(
            dict(
                command=event["command_ref"],
                event_ref=ref,
                measurements=list(expected),
                disposition=reason,
                residual=len(row["unexplained"]),
                alternatives=row["alternatives"],
            )
        )
    return {
        "actions": len(measured),
        "measured_actions": sum(bool(observed) for observed in measured.values()),
        "compiled_measurement_actions": sum(bool(measured[ref]) for ref in compiled),
        "programs": len(corpus["scopes"]),
        "dispositions": outcomes,
        "actions_detail": rows,
    }


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("public", type=Path)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    report = audit_corpus(args.public, json.loads(args.corpus.read_bytes()))
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print({key: val for key, val in report.items() if key != "actions_detail"})
