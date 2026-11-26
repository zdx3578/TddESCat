//! Two-phase ATDD minimization (`FABLE_NOTES/02` §4; toy 412–577;
//! thm:minimize).
//!
//! Phase 1 (bottom-up postorder): drop Gram-kernel redundancy so every bond
//! family becomes linearly independent. Phase 2 (top-down preorder): restrict
//! each bond family to the context-relevant subspace `K = colspace(H)`, where
//! `H = G̃^t` is the context Gram built by a fresh chain from the root (stale
//! caches are unsound — earlier phase-2 steps change sibling Grams along the
//! path). Preserves the function; afterwards `d(t) = ρ_t(f) = rank M_t(f)` at
//! every node and every bond family is a basis of the cut space `V_t(f)` —
//! the precondition for canonicalization.
//!
//! The theory-violation checks (phase-1 residual, invertibility of `G[S,S]`
//! and `KᵀK`) are deliberate always-on panics: over ℚ they can only fire on
//! an implementation bug, and they are cheap relative to the surrounding
//! linear algebra.

use super::contract::Partial;
use super::linalg::{Mat, Q};
use super::shadow::Shadow;
use super::{Atdd, NodeData};
use crate::vtree::Vtree;
use num_traits::{One, Zero};

/// `apply_node_transform`, then re-clear the shadow at the (≤ 2) nodes it
/// touched — node `t` and its parent — so the integer shadow stays exact.
fn apply_node_transform_sh(
    a: &mut Atdd,
    vt: &Vtree,
    t: usize,
    tm: &Mat,
    dm: &Mat,
    sh: &mut Shadow,
) {
    apply_node_transform(a, vt, t, tm, dm);
    sh.refresh(a, t);
    if let Some(p) = vt.node(t).parent {
        sh.refresh(a, p);
    }
}

/// How often each minimization phase actually reduced a dimension.
#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
pub struct MinimizeStats {
    pub p1: u64,
    pub p2: u64,
}

/// Rewrite node `t`'s bond family by the row transform `tm` (`d_new × d_old`)
/// and fold `dm` (`d_old × d_new`) into the parent slot (toy 412–440).
///
/// Three calibers of `(tm, dm)` are used (spec §4.1): exact gauge
/// (`dm = tm⁻¹`), phase-1 selection/reconstruction (`u_old = dm · u_new`
/// exact), and phase-2 (`dm = Λᵀ`, sound only by the context-subspace
/// argument). In all three, `f` is preserved.
pub fn apply_node_transform(a: &mut Atdd, vt: &Vtree, t: usize, tm: &Mat, dm: &Mat) {
    // 1) node t's own data: new bond family û_a = Σ_j tm[a][j] · u_j.
    match &a.node[t] {
        NodeData::Leaf(rows) => {
            a.node[t] = NodeData::Leaf(tm.mul(rows)); // (d_new × d_old)·(d_old × 2)
        }
        NodeData::Internal(w) => {
            let node = vt.node(t);
            // Shapes from the CHILDREN, never from w[0] (d_old may be 0).
            let (d1, d2) = (a.dim(node.left.unwrap()), a.dim(node.right.unwrap()));
            let mut new = Vec::with_capacity(tm.r);
            for arow in 0..tm.r {
                let mut m = Mat::zero(d1, d2);
                for (j, wj) in w.iter().enumerate() {
                    let c = tm.at(arow, j);
                    if !c.is_zero() {
                        m.axpy(c, wj);
                    }
                }
                new.push(m);
            }
            a.node[t] = NodeData::Internal(new);
        }
    }
    // 2) parent slot fold: left child W_i ← dmᵀ·W_i, right child W_i ← W_i·dm.
    let node = vt.node(t);
    let Some(p) = node.parent else { return };
    let NodeData::Internal(wp) = &a.node[p] else {
        unreachable!("parent of {t} is a leaf");
    };
    let new_wp: Vec<Mat> = if node.is_left {
        let dt = dm.transpose();
        wp.iter().map(|wi| dt.mul(wi)).collect()
    } else {
        wp.iter().map(|wi| wi.mul(dm)).collect()
    };
    a.node[p] = NodeData::Internal(new_wp);
}

/// Two-phase minimization (toy `minimize`, 505–577). Preserves `f`;
/// afterwards `d(t) = ρ_t(f)` at every node. The input must represent
/// `f ≢ 0` (check [`Atdd::is_zero_function`] first — on `f ≡ 0` dimensions
/// legally collapse to 0 and canonicalize is undefined).
pub fn minimize(a: &mut Atdd, vt: &Vtree) -> MinimizeStats {
    let mut stats = MinimizeStats::default();
    let root = vt.root();
    let none = Partial::default();
    // Integer shadow of the working diagram — all Gram/context contractions run
    // over it (gcd-free); kept in sync after every transform.
    let mut sh = Shadow::build(a, vt);

    // ---- Phase 1: Gram-kernel drop, bottom-up (thm:minimize Phase 1).
    for t in vt.postorder() {
        if t == root {
            continue;
        }
        // `σ_t · G_t` as a denom-1 ℚ matrix: the uniform scale cancels in the
        // reconstruction `γ = (G[S,S])⁻¹·G[S,l]` and the pivot set is invariant
        // (Lemma C), so `kept`/`tm`/`dm` are byte-identical to the ℚ pipeline.
        let g = sh.gram_scaled_q(vt, t, &none);
        let r = g.r;
        let (_, kept) = g.rref(); // PSD: pivot columns = lex-first independent subset
        if kept.len() == r {
            continue;
        }
        stats.p1 += 1;
        // T: selection of the kept rows; D: exact reconstruction of all rows.
        let tm = Mat::from_fn(kept.len(), r, |a_, j| {
            if j == kept[a_] { Q::one() } else { Q::zero() }
        });
        let mut dm = Mat::zero(r, kept.len());
        for (a_, &j) in kept.iter().enumerate() {
            *dm.at_mut(j, a_) = Q::one();
        }
        let gs = g.submatrix(&kept, &kept);
        let gs_inv = gs
            .inv()
            .expect("theory: G[S,S] invertible (thm:minimize (2))");
        for l in (0..r).filter(|l| !kept.contains(l)) {
            let rhs: Vec<Q> = kept.iter().map(|&k| g.at(k, l).clone()).collect();
            let gamma = gs_inv.mul_vec(&rhs);
            // res = ⟨w,w⟩ for the reconstruction residual w; must vanish over ℚ.
            let mut res = g.at(l, l).clone();
            for (x, y) in gamma.iter().zip(&rhs) {
                res -= x * y;
            }
            assert!(res.is_zero(), "phase-1 residual nonzero (theory violation)");
            for (a_, ga) in gamma.iter().enumerate() {
                *dm.at_mut(l, a_) = ga.clone();
            }
        }
        apply_node_transform_sh(a, vt, t, &tm, &dm, &mut sh);
    }

    // ---- Phase 2: context restriction, top-down, fresh H-chain per node.
    for t in vt.preorder() {
        if t == root {
            continue;
        }
        // Context Gram `H`, integer-scaled over the shadow: `h = σ_H · H`
        // (denom-1 ℚ) with the tracked integer scale `σ_H`.
        let (h, sigma_h) = sh.context_gram_scaled(a, vt, t);
        let r = h.r;
        let (_, pivcols) = h.rref(); // pivot columns invariant under σ_H (Lemma C)
        let rk = pivcols.len();
        if rk == r {
            continue;
        }
        stats.p2 += 1;
        // Recover the EXACT `K = H[:,pivcols]` by dividing out `σ_H` once per
        // entry (`h` has denominator 1, so its numer is `σ_H·K[i][j]`).
        let k = Mat::from_fn(r, rk, |i, j| {
            Q::new(h.at(i, pivcols[j]).numer().clone(), sigma_h.clone())
        });
        let ktk_inv = k
            .transpose()
            .mul(&k)
            .inv()
            .expect("KᵀK invertible: K has full column rank");
        let lam = ktk_inv.mul(&k.transpose()); // Λ = (KᵀK)⁻¹Kᵀ, left inverse of K
        apply_node_transform_sh(a, vt, t, &k.transpose(), &lam.transpose(), &mut sh);
    }

    stats
}

/// Gauge/padding utilities (toy 402–497) — used by tests across the ATDD
/// modules to exercise both minimize phases and gauge invariance. Test-only.
#[cfg(test)]
pub(crate) mod testutil {
    use super::*;
    use crate::rng::Rng;

    /// Random invertible matrix `L·U·P` with small integer entries (toy 402).
    pub fn random_invertible(n: usize, rng: &mut Rng) -> Mat {
        let mut lm = Mat::eye(n);
        let mut um = Mat::eye(n);
        for i in 0..n {
            for j in 0..i {
                *lm.at_mut(i, j) = Q::from_integer(rng.range_inclusive(-2, 2).into());
                *um.at_mut(j, i) = Q::from_integer(rng.range_inclusive(-2, 2).into());
            }
        }
        let mut perm: Vec<usize> = (0..n).collect();
        rng.shuffle(&mut perm);
        let p = Mat::from_fn(n, n, |i, j| if perm[i] == j { Q::one() } else { Q::zero() });
        lm.mul(&um).mul(&p)
    }

    /// Apply a random exact gauge (`D = T⁻¹`) at every non-root node.
    pub fn random_gauge(a: &mut Atdd, vt: &Vtree, rng: &mut Rng) {
        for t in vt.postorder() {
            if t == vt.root() || a.dim(t) == 0 {
                continue;
            }
            let r = random_invertible(a.dim(t), rng);
            let ri = r.inv().expect("random_invertible is invertible");
            apply_node_transform(a, vt, t, &r, &ri);
        }
    }

    /// Duplicate bond `j` at `t` with mixing weight α (toy `pad_duplicate`):
    /// exercises phase 1 without changing `f`.
    pub fn pad_duplicate(a: &mut Atdd, vt: &Vtree, t: usize, rng: &mut Rng) {
        let root = vt.root();
        if t == root {
            return;
        }
        let r = a.dim(t);
        let j = rng.below(r);
        let alpha = Q::new(
            (1 + rng.below(3) as i64).into(),
            (4 + rng.below(3) as i64).into(),
        );
        match &mut a.node[t] {
            NodeData::Leaf(m) => {
                let row: Vec<Q> = m.row(j).to_vec();
                let mut rows: Vec<Vec<Q>> = (0..m.r).map(|i| m.row(i).to_vec()).collect();
                rows.push(row);
                *m = Mat::from_rows(rows);
            }
            NodeData::Internal(w) => {
                let wj = w[j].clone();
                w.push(wj);
            }
        }
        let node = vt.node(t);
        let p = node.parent.unwrap();
        let NodeData::Internal(wp) = &a.node[p] else {
            unreachable!()
        };
        let one_minus = Q::one() - &alpha;
        let new_wp: Vec<Mat> = wp
            .iter()
            .map(|wi| {
                if node.is_left {
                    // new row = α·row_j; row_j ← (1-α)·row_j
                    let mut m = Mat::from_fn(wi.r + 1, wi.c, |x, y| {
                        if x < wi.r {
                            wi.at(x, y).clone()
                        } else {
                            &alpha * wi.at(j, y)
                        }
                    });
                    for y in 0..wi.c {
                        let v = &one_minus * wi.at(j, y);
                        *m.at_mut(j, y) = v;
                    }
                    m
                } else {
                    let mut m = Mat::from_fn(wi.r, wi.c + 1, |x, y| {
                        if y < wi.c {
                            wi.at(x, y).clone()
                        } else {
                            &alpha * wi.at(x, j)
                        }
                    });
                    for x in 0..wi.r {
                        let v = &one_minus * wi.at(x, j);
                        *m.at_mut(x, j) = v;
                    }
                    m
                }
            })
            .collect();
        a.node[p] = NodeData::Internal(new_wp);
    }

    /// Append a random bond at `t` whose parent coefficients are all zero
    /// (toy `pad_dead`): exercises phase 1/2 without changing `f`.
    pub fn pad_dead(a: &mut Atdd, vt: &Vtree, t: usize, rng: &mut Rng) {
        let root = vt.root();
        if t == root {
            return;
        }
        let node = vt.node(t);
        match &mut a.node[t] {
            NodeData::Leaf(m) => {
                let mut rows: Vec<Vec<Q>> = (0..m.r).map(|i| m.row(i).to_vec()).collect();
                rows.push(vec![
                    Q::from_integer((rng.below(3) as i64).into()),
                    Q::from_integer((rng.below(3) as i64).into()),
                ]);
                *m = Mat::from_rows(rows);
            }
            NodeData::Internal(w) => {
                let (d1, d2) = (w[0].r, w[0].c);
                let m = Mat::from_fn(d1, d2, |_, _| {
                    Q::from_integer(rng.range_inclusive(-1, 1).into())
                });
                w.push(m);
            }
        }
        let p = node.parent.unwrap();
        let NodeData::Internal(wp) = &a.node[p] else {
            unreachable!()
        };
        let new_wp: Vec<Mat> = wp
            .iter()
            .map(|wi| {
                if node.is_left {
                    Mat::from_fn(wi.r + 1, wi.c, |x, y| {
                        if x < wi.r {
                            wi.at(x, y).clone()
                        } else {
                            Q::zero()
                        }
                    })
                } else {
                    Mat::from_fn(wi.r, wi.c + 1, |x, y| {
                        if y < wi.c {
                            wi.at(x, y).clone()
                        } else {
                            Q::zero()
                        }
                    })
                }
            })
            .collect();
        a.node[p] = NodeData::Internal(new_wp);
    }

    /// Random pads followed by a random gauge (toy `messy`): preserves `f`,
    /// destroys minimality and any canonical structure.
    pub fn messy(a0: &Atdd, vt: &Vtree, rng: &mut Rng, n_pads: usize) -> Atdd {
        let mut a = a0.clone();
        let nodes: Vec<usize> = vt
            .postorder()
            .into_iter()
            .filter(|&t| t != vt.root())
            .collect();
        for _ in 0..n_pads {
            let t = nodes[rng.below(nodes.len())];
            if rng.next_bool() {
                pad_duplicate(&mut a, vt, t, rng);
            } else {
                pad_dead(&mut a, vt, t, rng);
            }
        }
        random_gauge(&mut a, vt, rng);
        a
    }
}

#[cfg(test)]
mod tests {
    use super::testutil::*;
    use super::*;
    use crate::atdd::func;
    use crate::atdd::linalg::q;
    use crate::rng::Rng;

    /// Hand-built PARITY network on any vtree: leaves [even, odd] =
    /// [[1,0],[0,1]]; internal W_even/W_odd = parity convolution; root emits
    /// odd parity. Minimal by construction (ρ_t = 2 internally).
    fn parity_atdd(vt: &Vtree) -> Atdd {
        let root = vt.root();
        let mut node = Vec::with_capacity(vt.num_nodes());
        for t in 0..vt.num_nodes() {
            let n = vt.node(t);
            if n.is_leaf() {
                let rows = vec![vec![q(1), q(0)], vec![q(0), q(1)]];
                node.push(NodeData::Leaf(Mat::from_rows(rows)));
            } else {
                let w_even = Mat::from_rows(vec![vec![q(1), q(0)], vec![q(0), q(1)]]);
                let w_odd = Mat::from_rows(vec![vec![q(0), q(1)], vec![q(1), q(0)]]);
                if t == root {
                    node.push(NodeData::Internal(vec![w_odd]));
                } else {
                    node.push(NodeData::Internal(vec![w_even, w_odd]));
                }
            }
        }
        // n = 1: the root is a leaf; represent x0 directly.
        if vt.node(root).is_leaf() {
            node[root] = NodeData::Leaf(Mat::from_rows(vec![vec![q(0), q(1)]]));
        }
        Atdd { node }
    }

    #[test]
    fn parity_network_is_correct_and_minimal() {
        for vt in [Vtree::balanced(4), Vtree::right_linear(5)] {
            let a = parity_atdd(&vt);
            a.check(&vt).unwrap();
            let f = func(&a, &vt);
            let expect: Vec<super::super::linalg::Q> = crate::instances::tt_parity(vt.n_vars())
                .into_iter()
                .map(|b| if b { q(1) } else { q(0) })
                .collect();
            assert_eq!(f, expect);
            // Already minimal: minimize must not fire or change anything.
            let mut b = a.clone();
            let stats = minimize(&mut b, &vt);
            assert_eq!(stats, MinimizeStats::default());
            assert_eq!(a, b);
        }
    }

    #[test]
    fn messy_then_minimize_restores_dims_and_function() {
        let mut rng = Rng::new(20260707);
        let mut fired = MinimizeStats::default();
        for trial in 0..20 {
            let n = 2 + rng.below(4); // 2..=5
            let vt = if trial % 2 == 0 {
                Vtree::balanced(n)
            } else {
                Vtree::random(n, &mut rng)
            };
            let a0 = parity_atdd(&vt);
            let f0 = func(&a0, &vt);
            let mut am = messy(&a0, &vt, &mut rng, 3);
            am.check(&vt).unwrap();
            assert_eq!(func(&am, &vt), f0, "messy must preserve f");
            let stats = minimize(&mut am, &vt);
            am.check(&vt).unwrap();
            assert_eq!(func(&am, &vt), f0, "minimize must preserve f");
            // PARITY: every non-root node has ρ_t = 2 (leaf or internal),
            // except n=... all internal non-root = 2; leaves = 2.
            for t in vt.postorder() {
                let want = if t == vt.root() { 1 } else { 2 };
                assert_eq!(am.dim(t), want, "dim at node {t}, n={n}");
            }
            fired.p1 += stats.p1;
            fired.p2 += stats.p2;
        }
        assert!(
            fired.p1 > 0 && fired.p2 > 0,
            "both phases must fire across trials: {fired:?}"
        );
    }

    #[test]
    fn gauge_alone_is_undone_without_dimension_change() {
        let mut rng = Rng::new(7);
        let vt = Vtree::balanced(4);
        let a0 = parity_atdd(&vt);
        let f0 = func(&a0, &vt);
        let mut ag = a0.clone();
        random_gauge(&mut ag, &vt, &mut rng);
        assert_eq!(func(&ag, &vt), f0, "gauge preserves f");
        let stats = minimize(&mut ag, &vt);
        // A pure gauge changes no dimension: minimize is a no-op on dims.
        assert_eq!(stats, MinimizeStats::default());
        assert_eq!(ag.dims(), a0.dims());
        assert_eq!(func(&ag, &vt), f0);
    }
}
