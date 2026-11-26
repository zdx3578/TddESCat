//! ATDD operations beyond conjunction (`reference/ops_toy.py`;
//! `atdd_note.tex` operations table, thm:operations): negation, disjunction,
//! entailment, conditioning, and single forgetting.
//!
//! Conditioning moves to the *induced* vtree (`Vtree::without_var`): the leaf
//! of `x` disappears and its parent contracts to the sibling, whose new node
//! carries `L · (sibling data)` where `L[i] = Σ_j λ_j(b) W^p_i[j][·]` folds
//! the conditioned leaf into the parent slices (toy `condition`). Forgetting
//! is `∃x f = f[x=0] ∨ f[x=1]` on the shared induced vtree (toy `forget`).
//!
//! All outputs are *unreduced* — callers normalize with
//! `minimize` (+ `canonicalize`) as the pipeline discipline requires.

use super::combine::{constant_one, direct_sum, hadamard, scale_root};
use super::contract::{cross_inner, ones_contract};
use super::linalg::{Mat, Q};
use super::{Atdd, NodeData};
use crate::vtree::Vtree;
use num_traits::{One, Zero};

/// Negation `¬f = 1 − f` (toy `atdd_not`): direct sum of the constant-1
/// network with `(−1)·f`. Dimensions grow by 1 at non-root nodes
/// (`ρ_t(¬f) ≤ ρ_t(f) + 1`).
pub fn negate(a: &Atdd, vt: &Vtree) -> Atdd {
    let mut neg = a.clone();
    scale_root(&mut neg, vt, &-Q::one());
    direct_sum(&constant_one(vt), &neg, vt)
}

/// Disjunction `f ∨ g = f + g − f·g` (toy `atdd_or`), for Boolean operands.
/// `ρ_t(f ∨ g) ≤ ρ_t(f)·ρ_t(g) + ρ_t(f) + ρ_t(g)`.
pub fn disjoin(a: &Atdd, b: &Atdd, vt: &Vtree) -> Atdd {
    let mut prod = hadamard(a, b, vt);
    scale_root(&mut prod, vt, &-Q::one());
    direct_sum(&direct_sum(a, b, vt), &prod, vt)
}

/// Sentential entailment `f ⊨ g` for Boolean `f, g` (toy `entails`):
/// `⟨f, 1⟩ − ⟨f, g⟩ == 0` — every model of `f` is a model of `g`.
pub fn entails(a: &Atdd, b: &Atdd, vt: &Vtree) -> bool {
    let f1 = ones_contract(a, vt, vt.root()).swap_remove(0);
    let fg = cross_inner(a, b, vt, vt.root());
    (f1 - fg.at(0, 0)).is_zero()
}

/// Conditioning `f[x := b]` onto a caller-provided induced vtree
/// (`new_vt`, `mapping` from [`Vtree::without_var`]) — the shared-target
/// form used by [`forget`] (toy `condition` with `target`).
pub fn condition_onto(
    a: &Atdd,
    vt: &Vtree,
    x: usize,
    b: bool,
    new_vt: &Vtree,
    mapping: &[Option<usize>],
) -> Atdd {
    // Locate x's leaf, its parent p, and the sibling s.
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

    // λ_j = u^leaf_j(b); L[i][k] = Σ_j λ_j W^p_i[j][k] (leaf left) or
    // L[i][j] = Σ_k W^p_i[j][k] λ_k (leaf right): shape d(p) × d(s).
    let NodeData::Leaf(lrows) = &a.node[leaf] else {
        unreachable!("x's node is a leaf");
    };
    let lam: Vec<Q> = (0..lrows.r)
        .map(|j| lrows.at(j, usize::from(b)).clone())
        .collect();
    let NodeData::Internal(wp) = &a.node[pn] else {
        unreachable!("parent of a leaf is internal");
    };
    let ds = a.dim(s);
    let l_mat = Mat::from_fn(wp.len(), ds, |i, k| {
        let wi = &wp[i];
        let mut sum = Q::zero();
        if leaf_is_left {
            for (j, lj) in lam.iter().enumerate() {
                if !lj.is_zero() && !wi.at(j, k).is_zero() {
                    sum += lj * wi.at(j, k);
                }
            }
        } else {
            for (jk, lk) in lam.iter().enumerate() {
                if !lk.is_zero() && !wi.at(k, jk).is_zero() {
                    sum += lk * wi.at(k, jk);
                }
            }
        }
        sum
    });

    // Assemble the new diagram: every surviving node copies its data; the
    // node at s's new position gets L folded into s's data.
    let s_new = mapping[s].expect("sibling survives");
    let mut node: Vec<NodeData> = Vec::with_capacity(new_vt.num_nodes());
    // Fill by new-vtree id; build an inverse map new-id -> old-id first.
    let mut inv: Vec<Option<usize>> = vec![None; new_vt.num_nodes()];
    for (old, new) in mapping.iter().enumerate() {
        if let Some(nid) = new {
            inv[*nid] = Some(old);
        }
    }
    for (nid, old) in inv.iter().enumerate() {
        let old = old.expect("every new node has a preimage");
        if nid == s_new {
            // L · (s's data).
            let folded = match &a.node[s] {
                NodeData::Leaf(m) => NodeData::Leaf(l_mat.mul(m)),
                NodeData::Internal(ws) => {
                    let (d1, d2) = (
                        a.dim(vt.node(s).left.unwrap()),
                        a.dim(vt.node(s).right.unwrap()),
                    );
                    let mut slices = Vec::with_capacity(l_mat.r);
                    for i in 0..l_mat.r {
                        let mut m = Mat::zero(d1, d2);
                        for (k, wk) in ws.iter().enumerate() {
                            let c = l_mat.at(i, k);
                            if !c.is_zero() {
                                m.axpy(c, wk);
                            }
                        }
                        slices.push(m);
                    }
                    NodeData::Internal(slices)
                }
            };
            node.push(folded);
        } else {
            node.push(a.node[old].clone());
        }
    }
    Atdd { node }
}

/// Conditioning `f[x := b]` (toy `condition` without target): builds the
/// induced vtree and returns it with the conditioned diagram. Requires
/// `n ≥ 2` (conditioning the only variable yields a constant, not a diagram).
pub fn condition(a: &Atdd, vt: &Vtree, x: usize, b: bool) -> (Vtree, Atdd) {
    let (new_vt, mapping) = vt.without_var(x);
    let cond = condition_onto(a, vt, x, b, &new_vt, &mapping);
    (new_vt, cond)
}

/// Single forgetting `∃x f = f[x=0] ∨ f[x=1]` on the shared induced vtree
/// (toy `forget`). `ρ_t(∃x f) ≤ ρ_t(f)² + 2ρ_t(f)` at corresponding nodes.
pub fn forget(a: &Atdd, vt: &Vtree, x: usize) -> (Vtree, Atdd) {
    let (new_vt, mapping) = vt.without_var(x);
    let a0 = condition_onto(a, vt, x, false, &new_vt, &mapping);
    let a1 = condition_onto(a, vt, x, true, &new_vt, &mapping);
    let or = disjoin(&a0, &a1, &new_vt);
    (new_vt, or)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::atdd::linalg::q;
    use crate::atdd::minimize::minimize;
    use crate::atdd::oracle::{brute_ranks, to_q};
    use crate::atdd::pipeline::is_boolean;
    use crate::atdd::{contract, func, oracle};
    use crate::rng::Rng;
    use std::collections::HashMap;

    fn random_nonzero_tt(n: usize, rng: &mut Rng, density_pct: usize) -> Vec<Q> {
        loop {
            let f: Vec<bool> = (0..(1usize << n))
                .map(|_| rng.below(100) < density_pct)
                .collect();
            if f.iter().any(|&b| b) {
                return to_q(&f);
            }
        }
    }

    /// Truth table of `f[x=b]` in the NEW vtree's leaf order (toy
    /// `tt_condition`).
    fn tt_condition(f: &[Q], vt: &Vtree, new_vt: &Vtree, x: usize, b: bool) -> Vec<Q> {
        let new_vars = new_vt.leaf_order();
        let mut out = Vec::with_capacity(1 << new_vars.len());
        for idx in 0..(1usize << new_vars.len()) {
            let mut bv: HashMap<usize, usize> = HashMap::new();
            for (i, &v) in new_vars.iter().enumerate() {
                bv.insert(v, (idx >> (new_vars.len() - 1 - i)) & 1);
            }
            bv.insert(x, usize::from(b));
            let mut gidx = 0usize;
            for &v in vt.leaf_order() {
                gidx = (gidx << 1) | bv[&v];
            }
            out.push(f[gidx].clone());
        }
        out
    }

    /// Old vtree nodes keyed by variable set (toy `node_by_varset`).
    fn node_by_varset(vt: &Vtree) -> HashMap<Vec<usize>, usize> {
        let mut m = HashMap::new();
        for t in vt.postorder() {
            let mut vs = vt.node(t).vars.clone();
            vs.sort_unstable();
            m.insert(vs, t);
        }
        m
    }

    /// The toy's corresponding-node rank check: for each new node, the rank
    /// must be bounded via the old node with the same varset OR varset ∪ {x}.
    fn rank_bound_holds(
        new_ranks: &[usize],
        new_vt: &Vtree,
        old_ranks: &[usize],
        old_by_set: &HashMap<Vec<usize>, usize>,
        x: usize,
        bound: impl Fn(usize) -> usize,
    ) -> bool {
        new_vt.postorder().into_iter().all(|t| {
            let mut vs = new_vt.node(t).vars.clone();
            vs.sort_unstable();
            let mut cands = Vec::new();
            if let Some(&u) = old_by_set.get(&vs) {
                cands.push(u);
            }
            let mut vsx = vs.clone();
            vsx.push(x);
            vsx.sort_unstable();
            if let Some(&u) = old_by_set.get(&vsx) {
                cands.push(u);
            }
            cands.iter().any(|&u| new_ranks[t] <= bound(old_ranks[u]))
        })
    }

    #[test]
    fn ops_match_brute_force_o1_to_o8() {
        let mut rng = Rng::new(20260610);
        for trial in 0..6 {
            let n = 4 + rng.below(3); // 4..=6
            let vt = Vtree::random(n, &mut rng);
            let f = random_nonzero_tt(n, &mut rng, 30 + 20 * (trial % 2));
            let g = random_nonzero_tt(n, &mut rng, 40);
            let af = oracle::build_from_truthtable(&f, &vt);
            let ag = oracle::build_from_truthtable(&g, &vt);
            let rf = brute_ranks(&f, &vt);
            let rg = brute_ranks(&g, &vt);

            // O1 direct sum: computes f+g, dims add at non-root nodes.
            let s = direct_sum(&af, &ag, &vt);
            let fpg: Vec<Q> = f.iter().zip(&g).map(|(a, b)| a + b).collect();
            assert_eq!(func(&s, &vt), fpg, "O1 sum, n={n}");
            for t in vt.postorder() {
                if t != vt.root() {
                    assert_eq!(s.dim(t), af.dim(t) + ag.dim(t), "O1 dims add");
                }
            }

            // O2 negation: 1-f; rank bound; Boolean.
            let nf = negate(&af, &vt);
            let fneg: Vec<Q> = f.iter().map(|a| q(1) - a).collect();
            assert_eq!(func(&nf, &vt), fneg, "O2 negation, n={n}");
            let rn = brute_ranks(&fneg, &vt);
            for t in vt.postorder() {
                assert!(rn[t] <= rf[t] + 1, "O2 rho(not f) <= rho(f)+1");
            }
            assert!(is_boolean(&nf, &vt), "O2 Boolean");

            // O3 disjunction: f+g-fg; rank bound; minimize preserves; Boolean.
            let of = disjoin(&af, &ag, &vt);
            let forr: Vec<Q> = f.iter().zip(&g).map(|(a, b)| a + b - a * b).collect();
            assert_eq!(func(&of, &vt), forr, "O3 disjunction, n={n}");
            let ro = brute_ranks(&forr, &vt);
            for t in vt.postorder() {
                assert!(
                    ro[t] <= rf[t] * rg[t] + rf[t] + rg[t],
                    "O3 rho(f or g) bound"
                );
            }
            let mut om = of.clone();
            minimize(&mut om, &vt);
            assert_eq!(func(&om, &vt), forr, "O3 minimize preserves");
            assert_eq!(om.dims(), ro, "O3 minimized dims == ranks");
            assert!(is_boolean(&om, &vt), "O3 Boolean");

            // O4 conjunction rank bound (hadamard itself is pipeline-tested).
            let fand: Vec<Q> = f.iter().zip(&g).map(|(a, b)| a * b).collect();
            let ra = brute_ranks(&fand, &vt);
            for t in vt.postorder() {
                assert!(ra[t] <= rf[t] * rg[t], "O4 rho(f and g) <= rho rho'");
            }

            // O5 conditioning: function correct on the induced vtree; rank
            // bound at corresponding nodes; Boolean.
            let x = rng.below(n);
            let b = rng.next_bool();
            let (cvt, cf) = condition(&af, &vt, x, b);
            cf.check(&cvt).unwrap();
            let fc = tt_condition(&f, &vt, &cvt, x, b);
            assert_eq!(func(&cf, &cvt), fc, "O5 condition f[x{x}={b}], n={n}");
            let old_by_set = node_by_varset(&vt);
            if fc.iter().any(|v| !num_traits::Zero::is_zero(v)) {
                let rc = brute_ranks(&fc, &cvt);
                assert!(
                    rank_bound_holds(&rc, &cvt, &rf, &old_by_set, x, |r| r),
                    "O5 rho(f[x=b]) <= rho(f) at corresponding node"
                );
            }
            assert!(is_boolean(&cf, &cvt), "O5 Boolean");

            // O6 forgetting: exists x f; minimize preserves; rank bound;
            // Boolean.
            let (evt, ef) = forget(&af, &vt, x);
            ef.check(&evt).unwrap();
            let f0 = tt_condition(&f, &vt, &evt, x, false);
            let f1 = tt_condition(&f, &vt, &evt, x, true);
            let fex: Vec<Q> = f0.iter().zip(&f1).map(|(a, b)| a + b - a * b).collect();
            assert_eq!(func(&ef, &evt), fex, "O6 forget exists x{x} f, n={n}");
            let mut em = ef.clone();
            minimize(&mut em, &evt);
            assert_eq!(func(&em, &evt), fex, "O6 minimize preserves");
            if fex.iter().any(|v| !num_traits::Zero::is_zero(v)) {
                let re = brute_ranks(&fex, &evt);
                assert!(
                    rank_bound_holds(&re, &evt, &rf, &old_by_set, x, |r| r * r + 2 * r),
                    "O6 rho(exists x f) <= rho^2 + 2 rho"
                );
            }
            assert!(is_boolean(&em, &evt), "O6 Boolean");

            // O7 entailment.
            let mut aand = hadamard(&af, &ag, &vt);
            minimize(&mut aand, &vt);
            assert!(entails(&aand, &af, &vt), "O7 f and g |= f");
            assert!(entails(&af, &of, &vt), "O7 f |= f or g");
            let sub = f.iter().zip(&g).all(|(a, b)| a <= b);
            assert_eq!(entails(&af, &ag, &vt), sub, "O7 f |= g vs brute force");

            // O8-ish sanity: model counts of derived networks.
            let mc_or: Q = forr.iter().sum();
            assert_eq!(contract::model_count(&om, &vt), mc_or, "MC(f or g)");
            let mc_not = q(1 << n) - f.iter().sum::<Q>();
            assert_eq!(contract::model_count(&nf, &vt), mc_not, "MC(not f)");
        }
    }

    #[test]
    fn condition_and_forget_edge_cases() {
        let mut rng = Rng::new(7);
        // n = 2: conditioning leaves a single-leaf vtree; both variables.
        let vt = Vtree::balanced(2);
        // f = x0 XOR x1
        let f = to_q(&[false, true, true, false]);
        let af = oracle::build_from_truthtable(&f, &vt);
        for x in 0..2 {
            for b in [false, true] {
                let (cvt, cf) = condition(&af, &vt, x, b);
                assert_eq!(cvt.n_vars(), 1);
                cf.check(&cvt).unwrap();
                let fc = tt_condition(&f, &vt, &cvt, x, b);
                assert_eq!(func(&cf, &cvt), fc);
            }
            let (evt, ef) = forget(&af, &vt, x);
            // exists x (x0 XOR x1) = constant 1 over the other variable.
            assert!(func(&ef, &evt).iter().all(num_traits::One::is_one));
        }
        // Conditioning the root's direct leaf child on a right-linear vtree
        // (parent = root: the sibling becomes the new root).
        let n = 4;
        let vt = Vtree::right_linear(n);
        let f = random_nonzero_tt(n, &mut rng, 50);
        let af = oracle::build_from_truthtable(&f, &vt);
        let (cvt, cf) = condition(&af, &vt, 0, true);
        cf.check(&cvt).unwrap();
        assert_eq!(func(&cf, &cvt), tt_condition(&f, &vt, &cvt, 0, true));
    }
}
