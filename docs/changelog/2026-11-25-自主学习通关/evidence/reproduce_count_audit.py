#!/usr/bin/env python3
"""复现固定基线审计器不能发现已绑定剩余集合漏项的问题。

从仓库根目录运行：
    python docs/changelog/2026-11-25-自主学习通关/evidence/reproduce_count_audit.py --auditor tests/bench/autonomous_audit.py

只导入指定审计函数，不修改函数、不启动游戏。退出 0 表示复现现有行为；
不表示理想的完整性审计通过。该夹具明确给定两个已绑定、未处理的候选；
删去一个非目标项时公共证据与已知绑定域不变。

这不证明实际 764 动作轨迹漏项，也不推断未观察到的真实目标。
"""

from __future__ import annotations

import argparse
import importlib.util
import hashlib
import json
from pathlib import Path


def load_existing_auditor(path: Path):
    spec = importlib.util.spec_from_file_location("existing_public_auditor", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot import the auditor: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def site_binding(x: int) -> list:
    # The first item is the role's anchor point. The second item describes the
    # public frame, pixel window and decoded pattern supporting this binding.
    return [
        [x, 0],
        {
            "event": "e0",
            "field": {
                "box": {"x": x, "y": 0, "width": 1, "height": 1},
                "scale": 1,
                "background": 0,
            },
            "value": {"width": 1, "height": 1, "mask": 1, "pigment": 1},
        },
    ]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--auditor",
        type=Path,
        required=True,
        help="待核查的现有 autonomous_audit.py 路径。",
    )
    args = parser.parse_args()
    auditor_path = args.auditor.resolve(strict=True)
    auditor = load_existing_auditor(auditor_path)

    # A single public frame: two color-1 pixels separated by background color 0.
    # Both sites belong to level 0, and neither has a processed/unbound event.
    receipts = {
        "e0": {
            "levels_completed": 0,
            "frame": [[[1, 0, 1]]],
        }
    }
    # A one-pixel role: relative x, relative y, observed color.
    role = [(0, 0, 1)]
    known_bound_unprocessed_domain = [[0, 0], [2, 0]]
    baseline = {
        "remaining": [site_binding(0), site_binding(2)],
        "previous_action": 1,
    }
    omitted = {
        "remaining": [site_binding(0)],
        "previous_action": 1,
    }
    results = []
    for name, facts, expected_new_audit in (
        ("complete_declared_domain", baseline, "accept"),
        ("omitted_non_target_binding", omitted, "reject_incomplete_remaining_set"),
    ):
        points = auditor.audit_site_facts(facts, receipts, level=0, role=role)
        variables = auditor.progress_variables(facts, action=1)
        results.append(
            {
                "case": name,
                "current_audit_result": "accepted",
                "current_remaining_sites": variables["remaining_sites"],
                "audited_points": [list(point) for point in sorted(points)],
                "expected_new_audit": expected_new_audit,
            }
        )

    # These assertions verify reproduction of the current behavior, not the
    # desired future completeness guarantee. A corrected audit should reject
    # the second case after independently reconstructing the binding domain.
    assert results[0]["current_remaining_sites"] == 2
    assert results[1]["current_remaining_sites"] == 1
    assert results[0]["audited_points"] == known_bound_unprocessed_domain
    assert results[1]["audited_points"] == [[0, 0]]
    print(
        json.dumps(
            {
                "kind": "synthetic_existing_audit_mutation",
                "auditor": str(auditor_path),
                "review_base_commit": "0652a3450e8b2191d6921d45343256f943609d30",
                "auditor_sha256": hashlib.sha256(auditor_path.read_bytes()).hexdigest(),
                "known_bound_unprocessed_domain": known_bound_unprocessed_domain,
                "target_point": [0, 0],
                "omitted_point": [2, 0],
                "results": results,
                "conclusion": (
                    "The existing function validates submitted entries but does not "
                    "detect omission from an independently established binding domain."
                ),
                "scope_limit": (
                    "This probe does not demonstrate an omission in the actual game "
                    "run and does not infer completeness of unseen map targets."
                ),
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
