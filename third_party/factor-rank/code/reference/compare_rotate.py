#!/usr/bin/env python3
"""Differential cross-check for the ATDD rotation surgery (atdd-rotate-v1).

Loads one or more `atdd-rotate-v1` JSON documents emitted by the Rust rotation
surgery, rebuilds the canonical input from the document's vtree + clauses, runs
`rotation_alg_toy.py`'s OWN surgery (`build_left_canon` / `right_surgery_inverse`)
on that input, and diffs the toy's result against the document's `out_canonical`
node-by-node (pivots and every rational) — the direct Rust↔toy cross-check. It
additionally confirms the toy surgery equals the from-scratch canonical ATDD
w.r.t. the rotated vtree, and that `rank_r` matches the created cut's dimension.

Pure stdlib; imports `atdd_toy` and `rotation_alg_toy` from the same directory.
Runnable with `uv run python compare_rotate.py <file.json> [...]`.

Usage:
    python compare_rotate.py [--selftest] <file.json> [file2.json ...]

`--selftest` flips one output entry in memory and confirms a MISMATCH — proving
the comparator can fail. Exit code 0 iff every file is OK.
"""
import copy
import json
import sys
from fractions import Fraction as F

from atdd_toy import V, annotate, postorder, reference_canonical, tt_clause
from rotation_alg_toy import (build_left_canon, right_surgery_inverse,
                              find_by_varset)


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
        f = [a * b for a, b in zip(f, tt_clause(n, lits, root))]
    return f


def run_toy_surgery(f, root, dir_, node_vars):
    """Run the reference surgery; return {frozenset(vars): (pivots, data)}
    keyed by the rotated tree's nodes, plus (root2, rankR_or_None)."""
    canon_T = reference_canonical(f, root)
    vs = frozenset(node_vars)
    v = find_by_varset(root, vs)
    if v is None:
        raise ValueError(f"rotation site {sorted(node_vars)} not found")
    if dir_ == "left":
        root2, canonp, _m, _vp, rankR = build_left_canon(f, root, v, canon_T)
    elif dir_ == "right":
        root2, canonp = right_surgery_inverse(root, canon_T, v)
        rankR = None
    else:
        raise ValueError(f"bad direction {dir_!r}")
    by_vars = {frozenset(t.vars): canonp[t] for t in postorder(root2)}
    return by_vars, root2, rankR


def compare_entry(k, node_out, cnode, ref_piv, ref_data):
    """Diff one out_canonical node against a reference (pivots, data) pair."""
    got_piv = [int(s, 2) for s in cnode["pivots"]]
    if got_piv != ref_piv:
        return f"node #{k} {sorted(node_out.vars)}: pivots {got_piv} != {ref_piv}"

    is_leaf = node_out.var is not None
    if is_leaf != (cnode["kind"] == "leaf"):
        return f"node #{k}: kind mismatch ({cnode['kind']})"

    if is_leaf:
        data = cnode["data"]
        if len(data) != len(ref_data):
            return f"node #{k}: leaf rows {len(data)} != {len(ref_data)}"
        for i, row in enumerate(data):
            for j, s in enumerate(row):
                if F(s) != ref_data[i][j]:
                    return (f"node #{k}: leaf [{i}][{j}] {s} != "
                            f"{ref_data[i][j]}")
    else:
        slices = cnode["data"]
        if len(slices) != len(ref_data):
            return f"node #{k}: slices {len(slices)} != {len(ref_data)}"
        for i, sl in enumerate(slices):
            for j, row in enumerate(sl):
                for kk, s in enumerate(row):
                    if F(s) != ref_data[i][j][kk]:
                        return (f"node #{k}: internal [{i}][{j}][{kk}] {s} "
                                f"!= {ref_data[i][j][kk]}")
    return None


def compare_doc(doc):
    """Return (ok: bool, message: str|None)."""
    if doc.get("format") != "atdd-rotate-v1":
        return False, f"unexpected format tag {doc.get('format')!r}"
    n = doc["n"]
    root = annotate(parse_vtree(doc["vtree"]))
    f = build_function(n, doc.get("clauses", []), root)
    dir_ = doc["rotation"]["dir"]
    node_vars = doc["rotation"]["node_vars"]

    by_vars, root2, rankR = run_toy_surgery(f, root, dir_, node_vars)

    # Cross-check 1: the toy surgery is itself the from-scratch canonical.
    ref2 = {frozenset(t.vars): reference_canonical(f, root2)[t]
            for t in postorder(root2)}
    for vs, (tp, td) in by_vars.items():
        rp, rd = ref2[vs]
        if tp != rp or td != rd:
            return False, (f"toy surgery != from-scratch canonical at "
                           f"{sorted(vs)}")

    # Cross-check 2 (the point): Rust out_canonical == toy surgery, node by node.
    nodes_out = postorder(annotate(parse_vtree(doc["out_vtree"])))
    canon = doc["out_canonical"]
    if len(canon) != len(nodes_out):
        return False, (f"out_canonical count {len(canon)} != out_vtree "
                       f"postorder {len(nodes_out)}")
    for k, (node_out, cnode) in enumerate(zip(nodes_out, canon)):
        vs = frozenset(node_out.vars)
        if vs not in by_vars:
            return False, f"node #{k} {sorted(vs)} absent from toy surgery"
        ref_piv, ref_data = by_vars[vs]
        msg = compare_entry(k, node_out, cnode, ref_piv, ref_data)
        if msg is not None:
            return False, msg

    # rank_r == created cut dimension (and == the toy's rankR for left). The
    # created node is the one present in root2 but not in root's cut family.
    root_cuts = {frozenset(t.vars) for t in postorder(root)}
    created_vs = [frozenset(t.vars) for t in postorder(root2)
                  if frozenset(t.vars) not in root_cuts]
    if len(created_vs) != 1:
        return False, f"expected exactly one created cut, got {created_vs}"
    toy_dim = len(by_vars[created_vs[0]][1])
    if doc["rank_r"] != toy_dim:
        return False, f"rank_r {doc['rank_r']} != created dim {toy_dim}"
    if rankR is not None and doc["rank_r"] != rankR:
        return False, f"rank_r {doc['rank_r']} != toy rankR {rankR}"

    # Sanity: the rotation preserves f (model count).
    mc = F(doc["stats"]["model_count"])
    if mc != sum(f):
        return False, f"model_count {mc} != brute-force sum {sum(f)}"
    return True, None


def flip_one(doc):
    """A copy of `doc` with one out_canonical rational changed."""
    d = copy.deepcopy(doc)
    for cnode in d["out_canonical"]:
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
        print("usage: compare_rotate.py [--selftest] <file.json> [...]",
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
            ok2, _ = compare_doc(flip_one(doc))
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
