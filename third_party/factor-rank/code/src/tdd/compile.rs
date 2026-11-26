//! TDD bottom-up compilation (M2b): product `apply_and`, canonical `minimize`
//! (clean → classify → rebuild), the compile loop, and model counting.
//!
//! Authoritative spec: `FABLE_NOTES/03_tdd_canonicity.md` §4–§6. The crux, from
//! that note: hash-consing on input sets is *vacuous* for a deterministic TDD,
//! so minimization is a single-pass Myhill–Nerode partition refinement by
//! *upward* (subfunction) equivalence — classify top-down by the signature
//! `{(parent-class-id, raw-sibling-id)}`, then rebuild bottom-up with one node
//! per class and a deterministic canonical numbering. The result has exactly
//! `S_t` nodes per vtree node and is byte-identical for equal functions.

use super::{Compiled, LeafLabel, Level, NId, NormalizedClause, Tdd, normalize_clause};
use crate::cnf::Cnf;
use crate::vtree::Vtree;
use rustc_hash::FxHashMap;
use std::collections::hash_map::Entry;

/// `Pos<Neg<One`; `Zero` (`None`) is dead and never stored.
fn and_labels(a: LeafLabel, b: LeafLabel) -> Option<LeafLabel> {
    use LeafLabel::{Neg, One, Pos};
    match (a, b) {
        (One, x) | (x, One) => Some(x),
        (Pos, Pos) => Some(Pos),
        (Neg, Neg) => Some(Neg),
        (Pos, Neg) | (Neg, Pos) => None,
    }
}

/// The `∨` of two class-member leaf labels: two literals of opposite polarity
/// in one class cover both values, i.e. the constant `1`.
pub(super) fn or_labels(a: LeafLabel, b: LeafLabel) -> LeafLabel {
    use LeafLabel::{Neg, One, Pos};
    match (a, b) {
        (One, _) | (_, One) | (Pos, Neg) | (Neg, Pos) => One,
        (Pos, Pos) => Pos,
        (Neg, Neg) => Neg,
    }
}

pub(super) fn pairs_of(tdd: &Tdd, vid: usize, nid: NId) -> &[(NId, NId)] {
    match &tdd.levels[vid] {
        Level::Internal(v) => &v[nid as usize],
        Level::Leaf(_) => unreachable!("pairs_of on a leaf node"),
    }
}

pub(super) fn label_of(tdd: &Tdd, vid: usize, nid: NId) -> LeafLabel {
    match &tdd.levels[vid] {
        Level::Leaf(v) => v[nid as usize],
        Level::Internal(_) => unreachable!("label_of on an internal node"),
    }
}

fn intern(
    need: &mut [Vec<(NId, NId)>],
    idx: &mut [FxHashMap<(NId, NId), u32>],
    t: usize,
    pair: (NId, NId),
) {
    if let Entry::Vacant(e) = idx[t].entry(pair) {
        let p = need[t].len() as u32;
        need[t].push(pair);
        e.insert(p);
    }
}

/// Conjunction of two TDDs over the **same** vtree (paper `∧BC` / Prop 28).
/// Returns `None` when the conjunction is identically false (UNSAT), which
/// short-circuits the compile loop. Dead product nodes (a `0`-leaf, or an
/// internal node all of whose input pairs reference a dead child) are dropped
/// during construction; the result is a valid deterministic TDD, possibly with
/// unreachable-but-live junk that `minimize` removes.
pub fn apply_and(a: &Tdd, b: &Tdd, vt: &Vtree) -> Option<Tdd> {
    let n = vt.num_nodes();
    assert_eq!(a.levels.len(), n, "TDD/vtree size mismatch");
    assert_eq!(b.levels.len(), n, "TDD/vtree size mismatch");
    let root = vt.root();

    // Sweep 1 (pre-order): discover the reachable product nodes (g,h). `need[t]`
    // lists them in discovery order; `idx[t]` maps a pair to its position.
    let mut need: Vec<Vec<(NId, NId)>> = vec![Vec::new(); n];
    let mut idx: Vec<FxHashMap<(NId, NId), u32>> = vec![FxHashMap::default(); n];
    intern(&mut need, &mut idx, root, (0, 0));
    for &t in &vt.preorder() {
        let node = vt.node(t);
        let (Some(l), Some(r)) = (node.left, node.right) else {
            continue;
        };
        let m = need[t].len();
        for i in 0..m {
            let (g, h) = need[t][i];
            let ap = pairs_of(a, t, g);
            let bp = pairs_of(b, t, h);
            for &(a1, a2) in ap {
                for &(b1, b2) in bp {
                    intern(&mut need, &mut idx, l, (a1, b1));
                    intern(&mut need, &mut idx, r, (a2, b2));
                }
            }
        }
    }

    // Sweep 2 (post-order): resolve each product node, dropping dead ones.
    let mut live: Vec<Vec<Option<NId>>> = vec![Vec::new(); n];
    let mut out: Vec<Level> = vec![Level::Leaf(Vec::new()); n];
    for &t in &vt.postorder() {
        let node = vt.node(t);
        let m = need[t].len();
        let mut lv: Vec<Option<NId>> = Vec::with_capacity(m);
        if let (Some(l), Some(r)) = (node.left, node.right) {
            let mut nodes: Vec<Box<[(NId, NId)]>> = Vec::new();
            for &(g, h) in &need[t] {
                let ap = pairs_of(a, t, g);
                let bp = pairs_of(b, t, h);
                let mut ps: Vec<(NId, NId)> = Vec::with_capacity(ap.len() * bp.len());
                for &(a1, a2) in ap {
                    for &(b1, b2) in bp {
                        let cl = idx[l][&(a1, b1)] as usize;
                        let cr = idx[r][&(a2, b2)] as usize;
                        if let (Some(c1), Some(c2)) = (live[l][cl], live[r][cr]) {
                            ps.push((c1, c2));
                        }
                    }
                }
                if ps.is_empty() {
                    lv.push(None);
                } else {
                    ps.sort_unstable();
                    ps.dedup();
                    lv.push(Some(nodes.len() as NId));
                    nodes.push(ps.into_boxed_slice());
                }
            }
            out[t] = Level::Internal(nodes);
        } else {
            let mut labels: Vec<LeafLabel> = Vec::new();
            for &(g, h) in &need[t] {
                match and_labels(label_of(a, t, g), label_of(b, t, h)) {
                    Some(lab) => {
                        lv.push(Some(labels.len() as NId));
                        labels.push(lab);
                    }
                    None => lv.push(None),
                }
            }
            out[t] = Level::Leaf(labels);
        }
        live[t] = lv;
    }

    live[root][0].map(|_| Tdd { levels: out })
}

/// Group child nodes by signature into classes (Myhill–Nerode); returns the
/// class id per node (`None` for unreachable) and the number of classes. Class
/// ids are by first occurrence — the partition is what matters; `minimize`'s
/// rebuild assigns the canonical numbering. Signatures are sorted in place and
/// consumed (moved into the interning map).
fn group_sigs(sigs: &mut [Vec<(u32, NId)>], reach: &[bool]) -> (Vec<Option<u32>>, usize) {
    let mut map: FxHashMap<Vec<(u32, NId)>, u32> =
        FxHashMap::with_capacity_and_hasher(sigs.len(), rustc_hash::FxBuildHasher);
    let mut cls = vec![None; sigs.len()];
    let mut next = 0u32;
    for (i, sig) in sigs.iter_mut().enumerate() {
        if !reach[i] {
            continue;
        }
        sig.sort_unstable();
        let id = *map.entry(std::mem::take(sig)).or_insert_with(|| {
            let id = next;
            next += 1;
            id
        });
        cls[i] = Some(id);
    }
    (cls, next as usize)
}

/// Reduce a TDD to its canonical minimal form (`FABLE_NOTES/03` §5). Assumes a
/// dead-down-clean input (every stored leaf is a live label, every internal
/// node has a non-empty input set) — `apply_and` and the clause/constant
/// builders all satisfy this. After the call, `widths()[t] == S_t` at every
/// vtree node, and equal functions give byte-identical diagrams.
pub fn minimize(c: &Tdd, vt: &Vtree) -> Tdd {
    let n = vt.num_nodes();
    let root = vt.root();
    let pre = vt.preorder();

    // Phase 0: reachability (live-up) from the single output node.
    let mut reach: Vec<Vec<bool>> = (0..n).map(|t| vec![false; c.levels[t].len()]).collect();
    if !reach[root].is_empty() {
        reach[root][0] = true;
    }
    for &t in &pre {
        let node = vt.node(t);
        let (Some(l), Some(r)) = (node.left, node.right) else {
            continue;
        };
        for g in 0..c.levels[t].len() {
            if !reach[t][g] {
                continue;
            }
            for &(u, v) in pairs_of(c, t, g as NId) {
                reach[l][u as usize] = true;
                reach[r][v as usize] = true;
            }
        }
    }

    // Phase 1: classify top-down by the signature {(parent class, raw sibling)}.
    let mut cls: Vec<Vec<Option<u32>>> = (0..n).map(|t| vec![None; c.levels[t].len()]).collect();
    let mut nclasses: Vec<usize> = vec![0; n];
    if !cls[root].is_empty() {
        cls[root][0] = Some(0);
        nclasses[root] = 1;
    }
    for &t in &pre {
        let node = vt.node(t);
        let (Some(l), Some(r)) = (node.left, node.right) else {
            continue;
        };
        let mut sigl: Vec<Vec<(u32, NId)>> = vec![Vec::new(); c.levels[l].len()];
        let mut sigr: Vec<Vec<(u32, NId)>> = vec![Vec::new(); c.levels[r].len()];
        for g in 0..c.levels[t].len() {
            if !reach[t][g] {
                continue;
            }
            let cg = cls[t][g].expect("reachable node is classified");
            for &(u, v) in pairs_of(c, t, g as NId) {
                sigl[u as usize].push((cg, v));
                sigr[v as usize].push((cg, u));
            }
        }
        let (cl_l, nc_l) = group_sigs(&mut sigl, &reach[l]);
        let (cl_r, nc_r) = group_sigs(&mut sigr, &reach[r]);
        cls[l] = cl_l;
        nclasses[l] = nc_l;
        cls[r] = cl_r;
        nclasses[r] = nc_r;
    }

    // Phase 2: rebuild bottom-up, one node per class, canonical numbering.
    let mut newid: Vec<Vec<u32>> = vec![Vec::new(); n]; // phase-1 class id -> canonical nid
    let mut new_levels: Vec<Level> = vec![Level::Leaf(Vec::new()); n];
    for &t in &vt.postorder() {
        let node = vt.node(t);
        let k = nclasses[t];
        if let (Some(l), Some(r)) = (node.left, node.right) {
            // Canonical input set per class, over canonical child ids.
            let mut key: Vec<Vec<(NId, NId)>> = vec![Vec::new(); k];
            for g in 0..c.levels[t].len() {
                if !reach[t][g] {
                    continue;
                }
                let ci = cls[t][g].unwrap() as usize;
                for &(u, v) in pairs_of(c, t, g as NId) {
                    let nu = newid[l][cls[l][u as usize].unwrap() as usize];
                    let nv = newid[r][cls[r][v as usize].unwrap() as usize];
                    key[ci].push((nu, nv));
                }
            }
            for kk in &mut key {
                kk.sort_unstable();
                kk.dedup();
            }
            let mut order: Vec<usize> = (0..k).collect();
            order.sort_by(|&x, &y| key[x].cmp(&key[y]));
            let mut nodes: Vec<Box<[(NId, NId)]>> = vec![Box::default(); k];
            let mut nid_of = vec![0u32; k];
            for (new_nid, &ci) in order.iter().enumerate() {
                nodes[new_nid] = std::mem::take(&mut key[ci]).into_boxed_slice();
                nid_of[ci] = new_nid as u32;
            }
            new_levels[t] = Level::Internal(nodes);
            newid[t] = nid_of;
        } else {
            // Leaf class key = OR of member labels.
            let mut key: Vec<Option<LeafLabel>> = vec![None; k];
            for g in 0..c.levels[t].len() {
                if !reach[t][g] {
                    continue;
                }
                let ci = cls[t][g].unwrap() as usize;
                let lab = label_of(c, t, g as NId);
                key[ci] = Some(match key[ci] {
                    None => lab,
                    Some(prev) => or_labels(prev, lab),
                });
            }
            let mut order: Vec<usize> = (0..k).collect();
            order.sort_by_key(|&ci| key[ci].unwrap());
            let mut labels = vec![LeafLabel::One; k];
            let mut nid_of = vec![0u32; k];
            for (new_nid, &ci) in order.iter().enumerate() {
                labels[new_nid] = key[ci].unwrap();
                nid_of[ci] = new_nid as u32;
            }
            new_levels[t] = Level::Leaf(labels);
            newid[t] = nid_of;
        }
    }

    Tdd { levels: new_levels }
}

/// Compile a CNF into a TDD respecting `vt` by the bottom-up loop (paper
/// Algorithm 1): conjoin each clause and minimize after every step. Returns
/// `Compiled::Unsat` if the formula is unsatisfiable.
pub fn compile(cnf: &Cnf, vt: &Vtree) -> Compiled {
    let mut acc = Tdd::constant_true(vt);
    for clause in &cnf.clauses {
        match normalize_clause(clause) {
            NormalizedClause::Empty => return Compiled::Unsat,
            NormalizedClause::Tautology => continue,
            NormalizedClause::Lits(ls) => {
                let d = minimize(&Tdd::clause(vt, &ls), vt);
                match apply_and(&acc, &d, vt) {
                    None => return Compiled::Unsat,
                    Some(p) => acc = minimize(&p, vt),
                }
            }
        }
    }
    Compiled::Tdd(acc)
}

impl Tdd {
    /// Exact model count via the automaton DP (`u128`; ample for feasible `n`).
    /// Determinism makes every input set a disjoint union, so the counts add.
    pub fn model_count(&self, vt: &Vtree) -> u128 {
        let n = vt.num_nodes();
        let mut cnt: Vec<Vec<u128>> = vec![Vec::new(); n];
        for &t in &vt.postorder() {
            let node = vt.node(t);
            cnt[t] = match &self.levels[t] {
                Level::Leaf(labels) => labels
                    .iter()
                    .map(|l| if *l == LeafLabel::One { 2 } else { 1 })
                    .collect(),
                Level::Internal(nodes) => {
                    let (l, r) = (node.left.unwrap(), node.right.unwrap());
                    nodes
                        .iter()
                        .map(|pairs| {
                            pairs
                                .iter()
                                .map(|&(u, v)| cnt[l][u as usize] * cnt[r][v as usize])
                                .sum()
                        })
                        .collect()
                }
            };
        }
        cnt[vt.root()].first().copied().unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cnf::{Clause, Cnf, Lit};
    use crate::instances::random_kcnf;
    use crate::rng::Rng;
    use crate::truthtable::{cnf_truth_table, factor_width};
    use crate::vtree::Vtree;

    fn compiled_tt(cnf: &Cnf, vt: &Vtree) -> Option<Vec<bool>> {
        match compile(cnf, vt) {
            Compiled::Unsat => None,
            Compiled::Tdd(t) => Some(t.to_truth_table(vt)),
        }
    }

    #[test]
    fn compile_matches_brute_force() {
        let mut rng = Rng::new(20260707);
        let mut sat = 0;
        let mut unsat = 0;
        for _ in 0..300 {
            let n = 3 + rng.below(6); // 3..=8
            let m = 2 + rng.below(10);
            let k = 1 + rng.below(n.min(3));
            let cnf = random_kcnf(n, m, k, &mut rng);
            let f = cnf_truth_table(&cnf, &Vtree::right_linear(n));
            let is_sat = f.iter().any(|&b| b);
            for vt in [
                Vtree::right_linear(n),
                Vtree::balanced(n),
                Vtree::random(n, &mut rng),
            ] {
                let expected = cnf_truth_table(&cnf, &vt);
                match compiled_tt(&cnf, &vt) {
                    Some(tt) => {
                        assert!(is_sat, "SAT diagram for an UNSAT formula");
                        assert_eq!(tt, expected, "n={n} m={m} k={k}");
                    }
                    None => assert!(!is_sat, "UNSAT verdict for a SAT formula"),
                }
            }
            if is_sat {
                sat += 1;
            } else {
                unsat += 1;
            }
        }
        // The mix must exercise both branches.
        assert!(sat > 0 && unsat > 0, "sat={sat} unsat={unsat}");
    }

    #[test]
    fn width_equals_factor_width_oracle() {
        // The headline correctness check: |N_t| after minimize == S_t.
        let mut rng = Rng::new(0xC0FFEE);
        let mut checked = 0;
        for _ in 0..150 {
            let n = 3 + rng.below(5); // 3..=7
            let m = 2 + rng.below(6);
            let k = 1 + rng.below(n.min(3));
            let cnf = random_kcnf(n, m, k, &mut rng);
            for vt in [
                Vtree::right_linear(n),
                Vtree::balanced(n),
                Vtree::random(n, &mut rng),
            ] {
                if let Compiled::Tdd(t) = compile(&cnf, &vt) {
                    let f = cnf_truth_table(&cnf, &vt);
                    let widths = t.widths();
                    for vid in vt.postorder() {
                        assert_eq!(
                            widths[vid],
                            factor_width(&f, &vt, vid),
                            "S_t mismatch at node {vid}, n={n}"
                        );
                    }
                    checked += 1;
                }
            }
        }
        assert!(checked > 20, "too few SAT instances checked: {checked}");
    }

    #[test]
    fn crux_regression_and_xor_pair() {
        // (x0 ∨ x1) ∧ (x0 ∨ ¬x1) = x0. Hash-consing would leave 2 leaf-x1
        // nodes; the partition-refinement minimize must collapse them to One.
        let vt = Vtree::balanced(2); // root(leaf x0, leaf x1)
        let mut cnf = Cnf::new(2);
        cnf.add_clause(Clause::new(vec![Lit::positive(0), Lit::positive(1)]));
        cnf.add_clause(Clause::new(vec![Lit::positive(0), Lit::negative(1)]));
        let Compiled::Tdd(t) = compile(&cnf, &vt) else {
            panic!("x0 is satisfiable");
        };
        // f = x0: table over leaf order (x0,x1), MSB=x0: [F,F,T,T].
        assert_eq!(t.to_truth_table(&vt), vec![false, false, true, true]);
        // widths (1,1,1) at (leaf x0, leaf x1, root).
        assert_eq!(t.width(), 1);
        assert!(t.widths().iter().all(|&w| w == 1));
        // model count: x0=1 with x1 free ⇒ 2 models.
        assert_eq!(t.model_count(&vt), 2);
    }

    #[test]
    fn canonical_under_clause_permutation() {
        // The canonical form depends only on (f, T): permuting clauses must give
        // a byte-identical diagram. Also cross-check model_count vs brute force.
        let mut rng = Rng::new(2024);
        for _ in 0..40 {
            let n = 3 + rng.below(5);
            let m = 3 + rng.below(5);
            let k = 1 + rng.below(n.min(3));
            let cnf = random_kcnf(n, m, k, &mut rng);
            let vt = Vtree::balanced(n);
            let base = compile(&cnf, &vt);
            // shuffled clause order
            let mut shuffled = cnf.clone();
            rng.shuffle(&mut shuffled.clauses);
            let perm = compile(&shuffled, &vt);
            assert_eq!(
                base, perm,
                "canonical form changed under clause permutation"
            );
            if let Compiled::Tdd(t) = &base {
                let f = cnf_truth_table(&cnf, &vt);
                let models = f.iter().filter(|&&b| b).count() as u128;
                assert_eq!(t.model_count(&vt), models);
            }
        }
    }

    #[test]
    fn edge_cases_dont_panic() {
        // Empty CNF ⇒ constant true.
        let vt = Vtree::balanced(3);
        let Compiled::Tdd(t) = compile(&Cnf::new(3), &vt) else {
            panic!("empty CNF is satisfiable (constant true)");
        };
        assert!(t.to_truth_table(&vt).iter().all(|&b| b));

        // A CNF containing the empty clause ⇒ UNSAT.
        let mut cnf = Cnf::new(3);
        cnf.add_clause(Clause::new(vec![Lit::positive(0)]));
        cnf.add_clause(Clause::new(vec![])); // empty clause
        assert_eq!(compile(&cnf, &vt), Compiled::Unsat);

        // A tautological clause is skipped (contributes nothing).
        let mut cnf = Cnf::new(2);
        cnf.add_clause(Clause::new(vec![Lit::positive(0), Lit::negative(0)]));
        let vt2 = Vtree::right_linear(2);
        let Compiled::Tdd(t) = compile(&cnf, &vt2) else {
            panic!("a lone tautology is satisfiable");
        };
        assert!(t.to_truth_table(&vt2).iter().all(|&b| b));

        // n = 1 through the full compile loop.
        let vt1 = Vtree::right_linear(1);
        let mut cnf = Cnf::new(1);
        cnf.add_clause(Clause::new(vec![Lit::positive(0)]));
        let Compiled::Tdd(t) = compile(&cnf, &vt1) else {
            panic!("(x0) is satisfiable");
        };
        assert_eq!(t.to_truth_table(&vt1), vec![false, true]);
        assert_eq!(t.model_count(&vt1), 1);
        // contradiction on one variable
        let mut cnf = Cnf::new(1);
        cnf.add_clause(Clause::new(vec![Lit::positive(0)]));
        cnf.add_clause(Clause::new(vec![Lit::negative(0)]));
        assert_eq!(compile(&cnf, &vt1), Compiled::Unsat);
    }

    #[test]
    fn constant_true_model_count() {
        for n in 1..=6 {
            let vt = Vtree::balanced(n);
            let t = Tdd::constant_true(&vt);
            assert_eq!(t.model_count(&vt), 1u128 << n);
            // minimize is idempotent on the canonical constant.
            assert_eq!(minimize(&t, &vt), t);
        }
    }

    #[test]
    fn parity_widths_are_two() {
        // PARITY_n as a CNF is exponential, so build it as nested XOR via the
        // ATDD later; here just check a small XOR chain's compiled widths match
        // the S_t oracle (already covered generally, but pins the counting case).
        // x0 XOR x1 XOR x2 encoded as CNF (4 clauses).
        let n = 3;
        let vt = Vtree::right_linear(n);
        let mut cnf = Cnf::new(n);
        // odd parity: clauses ruling out even-weight assignments
        for bits in 0..(1u32 << n) {
            if (bits.count_ones() % 2) == 0 {
                // forbid this assignment: clause = OR of literals falsified by it
                let lits: Vec<Lit> = (0..n).map(|i| Lit::new(i, (bits >> i) & 1 == 0)).collect();
                cnf.add_clause(Clause::new(lits));
            }
        }
        let Compiled::Tdd(t) = compile(&cnf, &vt) else {
            panic!("odd parity is satisfiable");
        };
        let f = cnf_truth_table(&cnf, &vt);
        for vid in vt.postorder() {
            assert_eq!(t.widths()[vid], factor_width(&f, &vt, vid));
        }
    }
}
