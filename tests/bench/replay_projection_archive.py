"""Reconstruct committed legacy frame predictions from earlier public patches."""

import json
from pathlib import Path
import sys

from tests.bench.measurement_audit import receipts
from tests.bench.program_audit import frame_sha


def load(p):
    return json.loads(p.read_bytes())


def anchor(cells):
    return min(x for x, y, c in cells), min(y for x, y, c in cells)


def normalized(cells):
    x, y = anchor(cells)
    return sorted((a - x, b - y, ink) for a, b, ink in cells)


def projection_frame(
    before, actual, model_before, model_after, modeled, expected, current
):
    translated = [e for e in modeled if e["family"] == "translation"]
    slots = [
        e
        for e in current
        if e["family"] == "translation"
        and f"translation-{anchor(e['before'])[0]}-{anchor(e['before'])[1]}" in expected
    ]
    if len(translated) != len(slots):
        return
    if (
        model_before == []
        or len(before) != len(model_before)
        or len(before[0]) != len(model_before[0])
    ):
        return
    for bound in slots if slots else [None]:
        if slots:
            a, b = anchor(translated[0]["before"])
            i, j = anchor(bound["before"])
            shift = (i - a, j - b)
            if not all(
                any(
                    anchor(new["before"])
                    == (
                        anchor(old["before"])[0] + shift[0],
                        anchor(old["before"])[1] + shift[1],
                    )
                    and new["values"] == old["values"]
                    and normalized(new["before"]) == normalized(old["before"])
                    for new in slots
                )
                for old in translated
            ):
                continue
        else:
            shift = (0, 0)
        writes = {}
        legal = True
        for effect in modeled:
            family = effect["family"]
            if family == "measurement":
                continue
            dx, dy = shift if family == "translation" else (0, 0)
            for x, y in effect["changed"]:
                u, v = x + dx, y + dy
                if (
                    not (0 <= u < len(before[0]) and 0 <= v < len(before))
                    or before[v][u] != model_before[y][x]
                    or (u, v) in writes
                    and writes[u, v] != model_after[y][x]
                ):
                    legal = False
                    break
                writes[u, v] = model_after[y][x]
            if not legal:
                break
        if not legal:
            continue
        for effect in current:
            if (
                effect["family"] != "measurement"
                or f"measurement-{effect['context']['instance']}" not in expected
            ):
                continue
            for x, y in effect["changed"]:
                if (x, y) in writes:
                    legal = False
                    break
                writes[x, y] = actual[y][x]
        if legal:
            predicted = [row[:] for row in before]
            for (x, y), color in writes.items():
                predicted[y][x] = color
            yield predicted, sorted(writes)


def recover_legacy_projections(public):
    events = receipts(public)
    checks = {
        d["event_ref"]: d for p in (public / "checks").glob("*.json") if (d := load(p))
    }
    witnesses = []
    for ref, c in checks.items():
        program = c.get("program") or {}
        if program.get("feedback") != "goal_projection_refuted":
            continue
        event, after = events[ref]
        before_ref = event["before_ref"]
        before = events[before_ref][1]
        a, z = before["frame"][-1], after["frame"][-1]
        proof = program["goal"]["steps"][0]
        target = proof["frame_sha256"]
        for source in c["read_events"]:
            training = checks.get(source)
            if (
                training is None
                or source == ref
                or training["action"] != event["action"]
                or training["evidence"]["alternatives"]
                or training["evidence"]["residual"]
            ):
                continue
            t_event, t_after = events[source]
            t_before = events[t_event["before_ref"]][1]
            patches = projection_frame(
                a,
                z,
                t_before["frame"][-1],
                t_after["frame"][-1],
                training["evidence"]["effects"],
                c["expected"],
                c["evidence"]["effects"],
            )
            for prediction, writes in patches:
                if frame_sha(prediction) != target:
                    continue
                changes = [
                    (x, y, prediction[y][x], z[y][x])
                    for y in range(len(z))
                    for x in range(len(z[0]))
                    if prediction[y][x] != z[y][x]
                ]
                witnesses.append(
                    dict(
                        ref=ref,
                        command=event["command_ref"],
                        before_ref=before_ref,
                        source=source,
                        action=event["action"],
                        frame_sha256=target,
                        actual_sha256=frame_sha(z),
                        mechanism=proof["mechanism"],
                        writes=writes,
                        inside=[
                            p
                            for p in changes
                            if list(p[:2]) in [list(w) for w in writes]
                        ],
                        outside=[
                            p
                            for p in changes
                            if list(p[:2]) not in [list(w) for w in writes]
                        ],
                        local_supported=set(c["assessments"].values()) == {"supported"},
                        complete=not c["evidence"]["residual"]
                        and not c["evidence"]["alternatives"],
                    )
                )
                break
            else:
                continue
            break
        else:
            raise AssertionError(
                f"No prior patch reproduces the signed prediction for {ref}"
            )
    return sorted(witnesses, key=lambda row: row["command"])


if __name__ == "__main__":
    out = recover_legacy_projections(Path(sys.argv[1]))
    Path(sys.argv[2]).write_text(json.dumps(out, indent=2) + "\n")
    print(
        [
            (
                row["command"],
                row["source"].split("-")[-1],
                len(row["inside"]),
                len(row["outside"]),
            )
            for row in out
        ]
    )
