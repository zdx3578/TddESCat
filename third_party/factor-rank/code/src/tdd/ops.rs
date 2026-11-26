//! TDD operations beyond conjunction (paper §"Succinctness and operations",
//! the ¬C / ∨BC / CD / SFO rows of the operations table).
//!
//! * `negate`: make the automaton *complete* bottom-up — at every vtree node
//!   add (if needed) one completion node whose input set is exactly the pairs
//!   not covered by any existing node (paper's `n_t`) — then the completion
//!   node at the root computes `¬f`.
//! * `disjoin`: De Morgan, `f ∨ g = ¬(¬f ∧ ¬g)` (paper: ∨BC from ¬C + ∧BC).
//! * `condition`: fold the conditioned leaf into its parent on the induced
//!   vtree (`Vtree::without_var`): determinism gives at most one surviving
//!   leaf node `g*`; each parent node contracts to the union of its
//!   `(g*, ·)`-siblings, whose input sets are pairwise disjoint, so the
//!   union is again a deterministic node. Contracted nodes with no
//!   `(g*, ·)` pair die; a seeded prune pass drops them and every node
//!   above that loses all its pairs.
//! * `forget`: `∃x f = f[x=0] ∨ f[x=1]` on the shared induced vtree (SFO).
//! * `entails`: `f ⊨ g  ⟺  f ∧ ¬g` unsatisfiable.
//!
//! All outputs are raw (may contain unreachable or non-canonical structure);
//! callers normalize with `minimize`, mirroring `apply_and`'s contract.
//! `None` means the resulting function is identically false (UNSAT), for
//! which no diagram exists in this representation.

use super::compile::{apply_and, label_of, minimize, or_labels, pairs_of};
use super::{LeafLabel, Level, NId, Tdd};
use crate::vtree::Vtree;

/// Make the diagram complete: for every vtree node and every assignment of
/// its variables, exactly one node is satisfied. Returns the completed
/// diagram and, per vtree node, the id of the added completion node (`None`
/// where the level was already complete). Bottom-up; preserves all existing
/// node ids and input sets (completion pairs live over completed children).
fn complete(a: &Tdd, vt: &Vtree) -> (Tdd, Vec<Option<NId>>) {
    let n = vt.num_nodes();
    let mut levels: Vec<Level> = vec![Level::Leaf(Vec::new()); n];
    let mut comp: Vec<Option<NId>> = vec![None; n];
    for t in vt.postorder() {
        let node = vt.node(t);
        if node.is_leaf() {
            let Level::Leaf(labels) = &a.levels[t] else {
                unreachable!("leaf level expected");
            };
            let mut labels = labels.clone();
            let covers_0 = labels.iter().any(|l| l.satisfied_by(false));
            let covers_1 = labels.iter().any(|l| l.satisfied_by(true));
            let missing = match (covers_0, covers_1) {
                (false, false) => Some(LeafLabel::One),
                (false, true) => Some(LeafLabel::Neg),
                (true, false) => Some(LeafLabel::Pos),
                (true, true) => None,
            };
            if let Some(lab) = missing {
                comp[t] = Some(labels.len() as NId);
                labels.push(lab);
            }
            levels[t] = Level::Leaf(labels);
        } else {
            let (l, r) = (node.left.unwrap(), node.right.unwrap());
            let Level::Internal(nodes) = &a.levels[t] else {
                unreachable!("internal level expected");
            };
            let mut nodes = nodes.clone();
            // Pair space over the COMPLETED children levels.
            let (dl, dr) = (levels[l].len(), levels[r].len());
            let mut covered = vec![false; dl * dr];
            for e in &nodes {
                for &(u, v) in e.iter() {
                    covered[u as usize * dr + v as usize] = true;
                }
            }
            let missing: Vec<(NId, NId)> = (0..dl)
                .flat_map(|u| (0..dr).map(move |v| (u as NId, v as NId)))
                .filter(|&(u, v)| !covered[u as usize * dr + v as usize])
                .collect();
            if !missing.is_empty() {
                comp[t] = Some(nodes.len() as NId);
                nodes.push(missing.into_boxed_slice());
            }
            levels[t] = Level::Internal(nodes);
        }
    }
    (Tdd { levels }, comp)
}

/// Negation `¬f` (paper ¬C). Input must be minimized (single root node).
/// Returns `None` iff `f ≡ 1` (then `¬f ≡ 0` has no diagram). Output raw.
pub fn negate(a: &Tdd, vt: &Vtree) -> Option<Tdd> {
    let root = vt.root();
    assert_eq!(
        a.levels[root].len(),
        1,
        "negate expects a minimized diagram (single root node)"
    );
    let (mut c, comp) = complete(a, vt);
    let comp_root = comp[root]?; // None: f covers everything, i.e. f ≡ 1
    // The completion node at the root computes ¬f; make it the single output.
    c.levels[root] = match &c.levels[root] {
        Level::Leaf(labels) => Level::Leaf(vec![labels[comp_root as usize]]),
        Level::Internal(nodes) => Level::Internal(vec![nodes[comp_root as usize].clone()]),
    };
    Some(c)
}

/// Disjunction `f ∨ g = ¬(¬f ∧ ¬g)` (paper ∨BC). Inputs minimized; output
/// raw. Never UNSAT: both inputs represent satisfiable functions.
pub fn disjoin(a: &Tdd, b: &Tdd, vt: &Vtree) -> Tdd {
    let (Some(na), Some(nb)) = (negate(a, vt), negate(b, vt)) else {
        // One operand is the constant 1 ⇒ so is the disjunction.
        return Tdd::constant_true(vt);
    };
    let na = minimize(&na, vt);
    let nb = minimize(&nb, vt);
    match apply_and(&na, &nb, vt) {
        // ¬f ∧ ¬g ≡ 0 ⇒ f ∨ g ≡ 1.
        None => Tdd::constant_true(vt),
        Some(both) => {
            let both = minimize(&both, vt);
            negate(&both, vt).expect("f ∨ g of satisfiable f, g is satisfiable")
        }
    }
}

/// Entailment `f ⊨ g ⟺ f ∧ ¬g ≡ 0`. Inputs minimized.
pub fn entails(a: &Tdd, b: &Tdd, vt: &Vtree) -> bool {
    match negate(b, vt) {
        None => true, // g ≡ 1 is entailed by everything
        Some(nb) => {
            let nb = minimize(&nb, vt);
            apply_and(a, &nb, vt).is_none()
        }
    }
}

/// Bottom-up prune over `vt`: start from an optional seeded liveness map at
/// one level (`seed = (vtree node, old id -> surviving new id)`, where the
/// level's data already contains ONLY the surviving nodes), drop pairs that
/// reference dead children and nodes whose input set empties, reindexing
/// throughout. Returns `None` if the root output (node 0) dies.
fn prune_dead(
    mut levels: Vec<Level>,
    vt: &Vtree,
    seed: Option<(usize, Vec<Option<NId>>)>,
) -> Option<Tdd> {
    let n = vt.num_nodes();
    let root = vt.root();
    let mut out: Vec<Level> = vec![Level::Leaf(Vec::new()); n];
    let mut alive: Vec<Vec<Option<NId>>> = vec![Vec::new(); n];
    let (seed_t, mut seed_map) = match seed {
        Some((t, m)) => (Some(t), Some(m)),
        None => (None, None),
    };
    for t in vt.postorder() {
        if seed_t == Some(t) {
            // Level data already pruned by the builder; adopt its map.
            alive[t] = seed_map.take().expect("seed consumed once");
            out[t] = std::mem::take(&mut levels[t]);
            continue;
        }
        let node = vt.node(t);
        match &levels[t] {
            Level::Leaf(labels) => {
                alive[t] = (0..labels.len()).map(|i| Some(i as NId)).collect();
                out[t] = std::mem::take(&mut levels[t]);
            }
            Level::Internal(nodes) => {
                let (l, r) = (node.left.unwrap(), node.right.unwrap());
                let mut new_nodes: Vec<Box<[(NId, NId)]>> = Vec::new();
                let mut map = Vec::with_capacity(nodes.len());
                for e in nodes {
                    let pruned: Vec<(NId, NId)> = e
                        .iter()
                        .filter_map(
                            |&(u, v)| match (alive[l][u as usize], alive[r][v as usize]) {
                                (Some(nu), Some(nv)) => Some((nu, nv)),
                                _ => None,
                            },
                        )
                        .collect();
                    if pruned.is_empty() {
                        map.push(None);
                    } else {
                        map.push(Some(new_nodes.len() as NId));
                        new_nodes.push(pruned.into_boxed_slice());
                    }
                }
                alive[t] = map;
                out[t] = Level::Internal(new_nodes);
            }
        }
    }
    match alive[root].first() {
        Some(Some(0)) => Some(Tdd { levels: out }),
        _ => None,
    }
}

/// Conditioning `f[x := b]` onto a caller-provided induced vtree (paper CD,
/// contracted like the ATDD side). Returns `None` iff `f[x := b] ≡ 0`.
/// Output raw. Requires `n ≥ 2`.
pub fn condition_onto(
    a: &Tdd,
    vt: &Vtree,
    x: usize,
    b: bool,
    new_vt: &Vtree,
    mapping: &[Option<usize>],
) -> Option<Tdd> {
    let leaf = (0..vt.num_nodes())
        .find(|&t| vt.node(t).var == Some(x))
        .expect("variable x has a leaf");
    let pn = vt.node(leaf).parent.expect("condition needs n >= 2");
    let p = vt.node(pn);
    let leaf_is_left = p.left == Some(leaf);
    let s = if leaf_is_left {
        p.right.unwrap()
    } else {
        p.left.unwrap()
    };
    // The unique leaf node of x satisfied by b (determinism), if any.
    let Level::Leaf(labels) = &a.levels[leaf] else {
        unreachable!("x's node is a leaf");
    };
    let Some(gstar) = labels.iter().position(|l| l.satisfied_by(b)) else {
        // No leaf value survives: f[x := b] ≡ 0.
        return None;
    };
    let gstar = gstar as NId;

    // Build the new levels: the s-position takes the parent's contracted
    // nodes (dead ones skipped, recorded in the seed map); everything else
    // copies unchanged — node ids above p stay valid via the seed remap.
    let s_new = mapping[s].expect("sibling survives");
    let mut inv: Vec<Option<usize>> = vec![None; new_vt.num_nodes()];
    for (old, new) in mapping.iter().enumerate() {
        if let Some(nid) = new {
            inv[*nid] = Some(old);
        }
    }
    let np = a.levels[pn].len();
    let mut seed_map: Vec<Option<NId>> = Vec::with_capacity(np);
    let mut levels: Vec<Level> = Vec::with_capacity(new_vt.num_nodes());
    for (nid, old) in inv.iter().enumerate() {
        let old = old.expect("every new node has a preimage");
        if nid != s_new {
            levels.push(a.levels[old].clone());
            continue;
        }
        // Contract parent node p_i to ∪ { h : (g*, h) ∈ E(p_i) }.
        let sibling_of = |&(u, v): &(NId, NId)| -> Option<NId> {
            let (gu, h) = if leaf_is_left { (u, v) } else { (v, u) };
            (gu == gstar).then_some(h)
        };
        match &a.levels[s] {
            Level::Leaf(_) => {
                let mut labels_new: Vec<LeafLabel> = Vec::new();
                for i in 0..np {
                    let mut hs = pairs_of(a, pn, i as NId).iter().filter_map(sibling_of);
                    match hs.next() {
                        None => seed_map.push(None),
                        Some(h0) => {
                            let lab = hs.fold(label_of(a, s, h0), |acc, h| {
                                or_labels(acc, label_of(a, s, h))
                            });
                            seed_map.push(Some(labels_new.len() as NId));
                            labels_new.push(lab);
                        }
                    }
                }
                levels.push(Level::Leaf(labels_new));
            }
            Level::Internal(_) => {
                let mut nodes_new: Vec<Box<[(NId, NId)]>> = Vec::new();
                for i in 0..np {
                    let mut e: Vec<(NId, NId)> = Vec::new();
                    for pair in pairs_of(a, pn, i as NId) {
                        if let Some(h) = sibling_of(pair) {
                            e.extend_from_slice(pairs_of(a, s, h));
                        }
                    }
                    if e.is_empty() {
                        seed_map.push(None);
                    } else {
                        e.sort_unstable();
                        e.dedup();
                        seed_map.push(Some(nodes_new.len() as NId));
                        nodes_new.push(e.into_boxed_slice());
                    }
                }
                levels.push(Level::Internal(nodes_new));
            }
        }
    }
    prune_dead(levels, new_vt, Some((s_new, seed_map)))
}

/// Conditioning `f[x := b]`: builds the induced vtree and returns it with
/// the conditioned diagram (`None` = UNSAT).
pub fn condition(a: &Tdd, vt: &Vtree, x: usize, b: bool) -> (Vtree, Option<Tdd>) {
    let (new_vt, mapping) = vt.without_var(x);
    let cond = condition_onto(a, vt, x, b, &new_vt, &mapping);
    (new_vt, cond)
}

/// Single forgetting `∃x f = f[x=0] ∨ f[x=1]` on the shared induced vtree
/// (paper SFO). For satisfiable `f` the result is satisfiable, so this
/// always yields a diagram.
pub fn forget(a: &Tdd, vt: &Vtree, x: usize) -> (Vtree, Tdd) {
    let (new_vt, mapping) = vt.without_var(x);
    let c0 = condition_onto(a, vt, x, false, &new_vt, &mapping);
    let c1 = condition_onto(a, vt, x, true, &new_vt, &mapping);
    let result = match (c0, c1) {
        (Some(a0), Some(a1)) => {
            let a0 = minimize(&a0, &new_vt);
            let a1 = minimize(&a1, &new_vt);
            disjoin(&a0, &a1, &new_vt)
        }
        (Some(a0), None) => a0,
        (None, Some(a1)) => a1,
        (None, None) => unreachable!("satisfiable f has a satisfiable restriction"),
    };
    (new_vt, result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::instances::random_kcnf;
    use crate::rng::Rng;
    use crate::tdd::{Compiled, compile};
    use crate::truthtable::{cnf_truth_table, factor_width};
    use crate::vtree::Vtree;

    /// A random satisfiable compiled TDD with its truth table.
    fn random_sat_tdd(n: usize, rng: &mut Rng) -> Option<(Vtree, Tdd, Vec<bool>)> {
        let m = 2 + rng.below(6);
        let k = 1 + rng.below(n.min(3));
        let cnf = random_kcnf(n, m, k, rng);
        let vt = match rng.below(3) {
            0 => Vtree::right_linear(n),
            1 => Vtree::balanced(n),
            _ => Vtree::random(n, rng),
        };
        match compile(&cnf, &vt) {
            Compiled::Tdd(t) => {
                let f = cnf_truth_table(&cnf, &vt);
                Some((vt, t, f))
            }
            Compiled::Unsat => None,
        }
    }

    /// Assert the minimized diagram is canonical: widths == S_t oracle.
    fn assert_canonical(t: &Tdd, vt: &Vtree, f: &[bool]) {
        let widths = t.widths();
        for vid in vt.postorder() {
            assert_eq!(widths[vid], factor_width(f, vt, vid), "S_t at {vid}");
        }
    }

    #[test]
    fn negate_matches_brute_force_and_oracle() {
        let mut rng = Rng::new(0x0417);
        let mut checked = 0;
        while checked < 40 {
            let n = 2 + rng.below(5); // 2..=6
            let Some((vt, t, f)) = random_sat_tdd(n, &mut rng) else {
                continue;
            };
            let fneg: Vec<bool> = f.iter().map(|&b| !b).collect();
            match negate(&t, &vt) {
                None => assert!(f.iter().all(|&b| b), "None only for f ≡ 1"),
                Some(nf) => {
                    let nf = minimize(&nf, &vt);
                    assert_eq!(nf.to_truth_table(&vt), fneg, "n={n}");
                    assert_canonical(&nf, &vt, &fneg);
                    // Double negation restores the original canonical form.
                    if let Some(back) = negate(&nf, &vt) {
                        assert_eq!(minimize(&back, &vt), t, "¬¬f == f");
                    } else {
                        assert!(fneg.iter().all(|&b| b));
                    }
                }
            }
            checked += 1;
        }
        // f ≡ 1 (empty CNF) negates to None.
        let vt = Vtree::balanced(3);
        let one = Tdd::constant_true(&vt);
        assert!(negate(&one, &vt).is_none());
    }

    #[test]
    fn disjoin_matches_brute_force_and_oracle() {
        let mut rng = Rng::new(0x0418);
        let mut checked = 0;
        while checked < 25 {
            let n = 2 + rng.below(5);
            let Some((vt, ta, fa)) = random_sat_tdd(n, &mut rng) else {
                continue;
            };
            // Second function on the SAME vtree.
            let m = 2 + rng.below(6);
            let k = 1 + rng.below(n.min(3));
            let cnf_b = random_kcnf(n, m, k, &mut rng);
            let Compiled::Tdd(tb) = compile(&cnf_b, &vt) else {
                continue;
            };
            let fb = cnf_truth_table(&cnf_b, &vt);
            let forr: Vec<bool> = fa.iter().zip(&fb).map(|(&a, &b)| a | b).collect();
            let or = minimize(&disjoin(&ta, &tb, &vt), &vt);
            assert_eq!(or.to_truth_table(&vt), forr, "n={n}");
            assert_canonical(&or, &vt, &forr);
            checked += 1;
        }
    }

    #[test]
    fn condition_and_forget_match_brute_force() {
        let mut rng = Rng::new(0x0419);
        let mut checked = 0;
        while checked < 30 {
            let n = 2 + rng.below(5); // 2..=6
            let Some((vt, t, f)) = random_sat_tdd(n, &mut rng) else {
                continue;
            };
            let x = rng.below(n);
            let b = rng.next_bool();
            let (cvt, cond) = condition(&t, &vt, x, b);
            // Brute-force restricted table in the NEW vtree's leaf order.
            let new_vars = cvt.leaf_order().to_vec();
            let mut fc = Vec::with_capacity(1 << new_vars.len());
            let mut assign = vec![false; n];
            for idx in 0..(1usize << new_vars.len()) {
                for (i, &v) in new_vars.iter().enumerate() {
                    assign[v] = (idx >> (new_vars.len() - 1 - i)) & 1 == 1;
                }
                assign[x] = b;
                let mut gidx = 0usize;
                for &v in vt.leaf_order() {
                    gidx = (gidx << 1) | usize::from(assign[v]);
                }
                fc.push(f[gidx]);
            }
            match cond {
                None => assert!(fc.iter().all(|&v| !v), "None only for f[x=b] ≡ 0"),
                Some(c) => {
                    let c = minimize(&c, &cvt);
                    assert_eq!(c.to_truth_table(&cvt), fc, "condition x{x}={b} n={n}");
                    assert_canonical(&c, &cvt, &fc);
                }
            }
            // Forgetting: ∃x f.
            let (evt, ef) = forget(&t, &vt, x);
            let ef = minimize(&ef, &evt);
            let mut fex = Vec::with_capacity(fc.len());
            let new_vars = evt.leaf_order().to_vec();
            for idx in 0..(1usize << new_vars.len()) {
                let mut any = false;
                for xb in [false, true] {
                    for (i, &v) in new_vars.iter().enumerate() {
                        assign[v] = (idx >> (new_vars.len() - 1 - i)) & 1 == 1;
                    }
                    assign[x] = xb;
                    let mut gidx = 0usize;
                    for &v in vt.leaf_order() {
                        gidx = (gidx << 1) | usize::from(assign[v]);
                    }
                    any |= f[gidx];
                }
                fex.push(any);
            }
            assert_eq!(ef.to_truth_table(&evt), fex, "forget x{x} n={n}");
            assert_canonical(&ef, &evt, &fex);
            checked += 1;
        }
    }

    #[test]
    fn entails_matches_brute_force() {
        let mut rng = Rng::new(0x041A);
        let mut checked = 0;
        while checked < 30 {
            let n = 2 + rng.below(5);
            let Some((vt, ta, fa)) = random_sat_tdd(n, &mut rng) else {
                continue;
            };
            let m = 2 + rng.below(6);
            let k = 1 + rng.below(n.min(3));
            let cnf_b = random_kcnf(n, m, k, &mut rng);
            let Compiled::Tdd(tb) = compile(&cnf_b, &vt) else {
                continue;
            };
            let fb = cnf_truth_table(&cnf_b, &vt);
            let sub = fa.iter().zip(&fb).all(|(&a, &b)| !a || b);
            assert_eq!(entails(&ta, &tb, &vt), sub, "f |= g vs brute force");
            // f ∧ g |= f and f |= f ∨ g.
            if let Some(and) = apply_and(&ta, &tb, &vt) {
                let and = minimize(&and, &vt);
                assert!(entails(&and, &ta, &vt), "f ∧ g |= f");
            }
            let or = minimize(&disjoin(&ta, &tb, &vt), &vt);
            assert!(entails(&ta, &or, &vt), "f |= f ∨ g");
            checked += 1;
        }
    }
}
