#!/usr/bin/env python3
"""Differential cross-check for the ATDD backend (atdd-canon-v1 interchange).

Loads one or more `atdd-canon-v1` JSON documents emitted by the Rust compiler,
rebuilds the represented function from the document's vtree + clauses, computes
the brute-force reference canonical form via `atdd_toy.reference_canonical`,
and diffs it against the document's `canonical` list node-by-node (pivots and
every rational) plus the summary stats.

Pure stdlib; imports `atdd_toy` from the same directory. Runnable with
`uv run python compare_canon.py <file.json> [...]` or plain `python3`.

Usage:
    python compare_canon.py <file.json> [file2.json ...]
    python compare_canon.py --selftest <file.json> [...]

`--selftest` additionally flips one canonical entry in memory and confirms the
comparator reports a MISMATCH — proving it can actually fail.

Exit code 0 iff every file is OK (and, under --selftest, every flip detected).
"""
import copy
import json
import sys
from fractions import Fraction as F

from atdd_toy import V, annotate, postorder, reference_canonical, tt_clause


def parse_vtree(node):
    """JSON vtree shape -> atdd_toy `V` node (unannotated)."""
    if "leaf" in node:
        return V(var=node["leaf"])
    return V(l=parse_vtree(node["l"]), r=parse_vtree(node["r"]))


def build_function(n, clauses, root):
    """Conjunction of the clause truth tables (Fraction 0/1), MSB-first in
    leaf order (atdd_toy convention). Empty clause list -> all ones."""
    f = [F(1)] * (1 << n)
    for cl in clauses:
        lits = [(abs(l) - 1, 1 if l > 0 else -1) for l in cl]
        tt = tt_clause(n, lits, root)
        f = [a * b for a, b in zip(f, tt)]
    return f


def compare_doc(doc):
    """Return (ok: bool, message: str|None)."""
    if doc.get("format") != "atdd-canon-v1":
        return False, f"unexpected format tag {doc.get('format')!r}"
    n = doc["n"]
    root = annotate(parse_vtree(doc["vtree"]))
    clauses = doc.get("clauses", [])
    f = build_function(n, clauses, root)
    ref = reference_canonical(f, root)

    nodes = postorder(root)
    canon = doc["canonical"]
    if len(canon) != len(nodes):
        return False, (f"canonical node count {len(canon)} != "
                       f"postorder length {len(nodes)}")

    for k, (node, cnode) in enumerate(zip(nodes, canon)):
        ref_piv, ref_data = ref[node]
        got_piv = [int(s, 2) for s in cnode["pivots"]]
        if got_piv != ref_piv:
            return False, f"node #{k}: pivots {got_piv} != reference {ref_piv}"

        is_leaf = node.var is not None
        if is_leaf != (cnode["kind"] == "leaf"):
            return False, f"node #{k}: kind mismatch ({cnode['kind']})"

        if is_leaf:
            data = cnode["data"]
            if len(data) != len(ref_data):
                return False, (f"node #{k}: leaf row count {len(data)} != "
                               f"reference {len(ref_data)}")
            for i, row in enumerate(data):
                for j, s in enumerate(row):
                    if F(s) != ref_data[i][j]:
                        return False, (f"node #{k}: leaf entry [{i}][{j}] "
                                       f"{s} != {ref_data[i][j]}")
        else:
            slices = cnode["data"]
            if len(slices) != len(ref_data):
                return False, (f"node #{k}: slice count {len(slices)} != "
                               f"reference {len(ref_data)}")
            for i, sl in enumerate(slices):
                for j, row in enumerate(sl):
                    for kk, s in enumerate(row):
                        if F(s) != ref_data[i][j][kk]:
                            return False, (f"node #{k}: internal entry "
                                           f"[{i}][{j}][{kk}] {s} != "
                                           f"{ref_data[i][j][kk]}")

    stats = doc["stats"]
    mc = F(stats["model_count"])
    if mc != sum(f):
        return False, f"model_count {mc} != brute-force sum {sum(f)}"
    exp_width = max(len(c["data"]) for c in canon)
    if stats["width"] != exp_width:
        return False, f"width {stats['width']} != max node dim {exp_width}"

    return True, None


def flip_one(doc):
    """A copy of `doc` with one canonical rational entry changed (for the
    --selftest sensitivity check)."""
    d = copy.deepcopy(doc)
    for cnode in d["canonical"]:
        if cnode["kind"] == "leaf":
            for row in cnode["data"]:
                if row:
                    row[0] = str(F(row[0]) + 1)
                    return d
        else:
            for sl in cnode["data"]:
                for row in sl:
                    if row:
                        row[0] = str(F(row[0]) + 1)
                        return d
    return d


def main():
    args = sys.argv[1:]
    selftest = "--selftest" in args
    files = [a for a in args if a != "--selftest"]
    if not files:
        print("usage: compare_canon.py [--selftest] <file.json> [...]",
              file=sys.stderr)
        sys.exit(2)

    any_fail = False
    for fn in files:
        with open(fn) as fh:
            doc = json.load(fh)
        ok, msg = compare_doc(doc)
        if not ok:
            print(f"MISMATCH {fn}: {msg}")
            any_fail = True
            continue
        if selftest:
            broken = flip_one(doc)
            ok2, _ = compare_doc(broken)
            if ok2:
                print(f"SELFTEST-FAIL {fn}: flipped entry NOT detected")
                any_fail = True
                continue
            print(f"OK {fn} (selftest: flipped entry correctly rejected)")
        else:
            print(f"OK {fn}")

    sys.exit(1 if any_fail else 0)


if __name__ == "__main__":
    main()
