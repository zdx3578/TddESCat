"""Independently audit the stationary-pointer comparisons in a chronological replay."""

import argparse
from collections import deque
from hashlib import sha256
from itertools import combinations
import json
from pathlib import Path

from scripts.check_v13_process import load, public_response, require
from tests.bench.public_coverage import parameter_key


def components(frame):
    unseen = {(x, y) for y, row in enumerate(frame) for x in range(len(row))}
    groups = []
    while unseen:
        x, y = unseen.pop()
        color = frame[y][x]
        cells = {(x, y)}
        queue = deque(cells)
        while queue:
            x, y = queue.popleft()
            for point in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                nx, ny = point
                if point in unseen and frame[ny][nx] == color:
                    unseen.remove(point)
                    cells.add(point)
                    queue.append(point)
        groups.append((color, frozenset(cells)))
    return groups


def translated(cells, delta):
    dx, dy = delta
    return frozenset((x + dx, y + dy) for x, y in cells)


def anchor(cells):
    return min(x for x, _ in cells), min(y for _, y in cells)


def zone(cells, point):
    if point in cells:
        return "support"
    x0, y0 = anchor(cells)
    x1, y1 = max(x for x, _ in cells), max(y for _, y in cells)
    complement = {(x, y) for x in range(x0, x1+1) for y in range(y0, y1+1)} - cells
    outside = {(x, y) for x, y in complement if x in (x0, x1) or y in (y0, y1)}
    waiting = deque(outside)
    while waiting:
        x, y = waiting.popleft()
        for cell in ((x-1,y),(x+1,y),(x,y-1),(x,y+1)):
            if cell in complement and cell not in outside:
                outside.add(cell)
                waiting.append(cell)
    return "box_gap" if point in outside else "hole"


def verify_site(public, row, key, direction):
    candidate = next(c for c in row["candidates"] if c["key"] == key)
    ((channel, delta),) = candidate["expected"].items()
    family, x, y = channel.split("-")
    require(family == "translation" and tuple(delta) == direction, "Wrong translation contract")
    origin = int(x), int(y)
    click = load(public / "events" / (row["before"] + ".json"))
    prior = load(public / "events" / (click["before_ref"] + ".json"))
    require(click["completion"] == prior["completion"] == "confirmed" and click["action"]["id"] == 6,
            "No confirmed preceding click")
    point = click["action"]["x"], click["action"]["y"]
    previous = components(public_response(public, prior)["frame"][-1])
    touched = next(s for s in previous if point in s[1])
    click_response = public_response(public, click)
    require(parameter_key(click["action"]) == parameter_key(click_response["action_input"]),
            "Click parameters differ from receipt")
    frames = click_response["frame"]
    for frame in frames:
        groups = components(frame)
        require(touched in groups, "Pointer support changed during the preceding receipt")

    candidates = [(color, cells) for color, cells in groups if anchor(cells) == origin]
    require(len(candidates) == 1, "Origin does not identify one public role")
    color, cells = candidates[0]
    template = translated(cells, (-origin[0], -origin[1]))
    roles = []
    for pigment, support in groups:
        pos = anchor(support)
        if pigment == color and translated(template, pos) == support:
            roles.append((pos, support))
    require(len(roles) >= 2, "No rival of matching appearance")
    hits = [pos for pos, shape in roles if pos[0] <= point[0] <= max(x for x, _ in shape)
            and pos[1] <= point[1] <= max(y for _, y in shape)]
    require(len(hits) == 1, "Point does not distinguish the roles")
    hit = next(shape for pos, shape in roles if pos == hits[0])
    observed_class = dict(owner="bound" if hits[0] == origin else "rival", zone=zone(hit, point))

    # Access the response after deriving the binding from the prior public frames.
    event = load(public / "events" / (row["event"] + ".json"))
    require(event["completion"] == "confirmed" and event["before_ref"] == click["event_id"],
            "Broken receipt chain")
    response = public_response(public, event)
    require(parameter_key(event["action"]) == parameter_key(response["action_input"]),
            "Movement request differs from receipt")
    after = components(response["frame"][-1])
    target = color, translated(cells, direction)
    stayed, arrived = (color, cells) in after, target in after
    require(stayed != arrived and target not in groups, "Ambiguous endpoint correspondence")
    context = json.dumps([frames[-1], click_response["levels_completed"], sorted(click_response["available_actions"])],
                         separators=(",", ":")).encode()
    return dict(event=event["event_id"], sequence=event["sequence"], before=click["event_id"],
                before_screen_domain_sha256=sha256(context).hexdigest(),
                pointer=point, pointer_color=frames[-1][point[1]][point[0]], role_color=color,
                role_pixels=len(hit), observed_class=observed_class, action=event["action"],
                origin=origin, expected=direction,
                measured=direction if arrived else (0, 0), response_sha256=event["response_blob"])


def verify(root, rows):
    indexed = {r["event"]: r for r in rows}
    checks = []
    for row in rows:
        for test in row["candidates"]:
            for contrast in test["pointer"]:
                public = root / row["game"] / "public"
                (direction,) = test["expected"].values()
                direction = tuple(direction)
                def check(r):
                    return verify_site(public, r, test["key"], direction)

                positive = [check(indexed[ref]) for ref in contrast["supports"]]
                negative = [check(indexed[ref]) for ref in contrast["excludes"]]
                held = check(row)
                require(all(w["sequence"] < held["sequence"] for w in positive + negative),
                        "Control uses a future receipt")
                require(len({w["origin"] for w in positive}) >= 2 and negative, "Missing role contrasts")
                owner = positive[0]["observed_class"]["owner"]
                require(all(w["observed_class"]["owner"] == owner and w["measured"] == direction
                            for w in positive), "Invalid positive control")
                require(all(w["measured"] != direction for w in negative), "Invalid negative control")
                zones = ("support", "hole", "box_gap")
                consistent = set()
                for n in range(1,len(zones)+1):
                    for subset in combinations(zones,n):
                        def matches(site):
                            c = site["observed_class"]
                            return c["owner"] == owner and c["zone"] in subset
                        if all(map(matches,positive)) and not any(map(matches,negative)):
                            consistent.add((owner, frozenset(subset), matches(held)))
                supplied = {(h["owner"], frozenset(h["zones"]), h["accepts"]) for h in contrast["hypotheses"]}
                require(consistent and consistent == supplied, "Inconsistent geometric version space")
                votes = {x[2] for x in consistent}
                verdict = "split" if len(votes)>1 else ("supported" if True in votes else "excluded")
                matching = [w for w in positive if w["observed_class"] == held["observed_class"]]
                supported = (verdict == "supported" and len({w["origin"] for w in matching}) >= 2
                             and len({w["before_screen_domain_sha256"] for w in matching}) >= 2)
                require(contrast["observed"] == held["observed_class"] and verdict == contrast["agreement"],
                        "Held-out geometry differs")
                require(supported == contrast["replicated"] == (test["scope"] == "replicated"),
                        "Held-out scope exceeds evidence")
                if verdict == "split":
                    require(test["scope"] == "unverified", "Disagreement admitted without a comparison")
                checks.append(dict(game=row["game"],producer=test["key"],scope=test["scope"],
                                   supports=positive,refutations=negative,held=held,agreement=verdict,
                                   consistent_hypotheses=len(consistent),applicable_hypotheses=sum(h[2] for h in consistent),
                                   observed_motion_agrees=held["measured"] == direction))
    return checks


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("replay", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.root, load(args.replay)), indent=2))
