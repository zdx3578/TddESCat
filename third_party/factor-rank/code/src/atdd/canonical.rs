//! Lex-RREF canonicalization via pivot descent (`FABLE_NOTES/02` §5; toy
//! 589–637; def:canonical, lem:tests, thm:canonicalize).
//!
//! Precondition: the ATDD is minimized (§4) — every bond family is a basis of
//! its cut space `V_t(f)`. `pivot_descent` finds the canonical tests
//! `c_0 < … < c_{r-1}` (the pivots of the lex-RREF basis of `V_t`) by a
//! greedy MSB-first bit descent on conditioned Gram traces: over ℚ,
//! `trace(B·G_π·Bᵀ) = 0` iff every function in the current subspace vanishes
//! on the subcube `π`. `canonicalize` then applies the exact gauge
//! `T = (Pᵀ)⁻¹, D = Pᵀ` so every non-root bond family becomes the
//! interpolation basis (`e_i(c_j) = δ_ij`) — the unique canonical form:
//! equal functions on the same vtree give syntactically identical data
//! (prop:canonicity), with entries of `O(ρ log ρ)` bits (lem:bits).

use super::contract::Partial;
use super::linalg::{Mat, Q};
use super::minimize::apply_node_transform;
use super::shadow::Shadow;
use super::{Atdd, NodeData};
use crate::vtree::Vtree;
use num_traits::{One, Zero};
use std::fmt;

/// A canonical test: an assignment of `vars(t)` as bits in leaf order, MSB
/// first (spec §0.3). Arbitrary-width (a `u64` index would overflow for
/// `nv(t) > 63`). Lexicographic `Ord` = numeric order of the local index.
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub struct Pivot(pub Vec<bool>);

impl Pivot {
    /// Read the bits of `vars(t)` (leaf order) out of a full local assignment.
    pub fn from_partial(vt: &Vtree, t: usize, partial: &Partial) -> Pivot {
        Pivot(
            vt.node(t)
                .vars
                .iter()
                .map(|&v| partial.get(v).expect("pivot assignment fixes vars(t)"))
                .collect(),
        )
    }

    /// The local index (MSB-first fold); test/interchange use, `nv ≤ 63`.
    pub fn to_local_index(&self) -> usize {
        assert!(self.0.len() <= 63, "local index overflows");
        self.0
            .iter()
            .fold(0usize, |acc, &b| (acc << 1) | usize::from(b))
    }

    /// Reconstruct an `nbits`-wide pivot from its local index (inverse of
    /// [`Pivot::to_local_index`], MSB first). Used to lift the reference
    /// oracle's `usize` pivots and to form product tests in rotation surgery.
    pub fn from_local_index(idx: usize, nbits: usize) -> Pivot {
        assert!(nbits <= 63, "local index overflows");
        Pivot((0..nbits).rev().map(|b| (idx >> b) & 1 == 1).collect())
    }

    /// Concatenate two pivots, `self` in the high bits: the canonical test at a
    /// merged node `m = (a, b)` is `p^a × p^b` with `a` the more significant
    /// (left) child (Theorem 8(iii)).
    pub fn concat(&self, low: &Pivot) -> Pivot {
        let mut bits = self.0.clone();
        bits.extend_from_slice(&low.0);
        Pivot(bits)
    }
}

impl fmt::Display for Pivot {
    /// Bitstring, e.g. `"0101"` — the JSON interchange format.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for &b in &self.0 {
            write!(f, "{}", u8::from(b))?;
        }
        Ok(())
    }
}

/// The canonical certificate: per vtree node, the canonical tests and the
/// canonical tensor data. Two ATDDs over the same vtree compute the same
/// function iff their `CanonicalForm`s are `==` (prop:canonicity).
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct CanonicalForm {
    /// Canonical tests per vtree node id (strictly ascending within a node).
    pub pivots: Vec<Vec<Pivot>>,
    /// Canonical node data (snapshot of the gauged ATDD).
    pub data: Vec<NodeData>,
}

impl CanonicalForm {
    /// Snapshot the certificate of an already-canonicalized ATDD (deep clone
    /// of the diagram data). Take it only where the certificate is actually
    /// consumed — the compile loop deliberately does NOT snapshot per step.
    pub fn snapshot(a: &Atdd, pivots: Vec<Vec<Pivot>>) -> CanonicalForm {
        CanonicalForm {
            pivots,
            data: a.node.clone(),
        }
    }
}

/// Find the canonical tests of `f` at `t` and the evaluation matrix
/// `P[m][j] = u_j(c_m)` (toy 589–615). Requires the bond family at `t` to be
/// a basis of `V_t` (i.e. the ATDD is minimized).
///
/// Loop invariant: `rowspace(bmat)` parametrizes, in `u`-coefficients, the
/// subspace `S_m = { v ∈ V_t : v(c_0) = … = v(c_{m-1}) = 0 }`. The greedy
/// MSB-first descent lands on the lex-least live coordinate of `S_m`, which
/// by lem:tests/lem:echelon is exactly the `m`-th canonical test.
///
/// Runs over a prebuilt integer [`Shadow`] that `canonicalize` maintains across
/// the whole postorder. The scaled Gram `σ_t·G_π` leaves every zero test
/// unchanged (`σ_t > 0`) and `point_eval_exact` recovers the exact evaluation
/// matrix `P`, so the pivots and `P` are byte-identical to the ℚ descent.
pub(crate) fn pivot_descent_sh(a: &Atdd, vt: &Vtree, t: usize, sh: &Shadow) -> (Vec<Pivot>, Mat) {
    super::shadow::pivot_descent_bareiss(sh, vt, t, a.dim(t))
}

/// The reference ℚ pivot descent (the pre-Stage-2 implementation). Kept only for
/// the differential test that the fraction-free integer descent
/// ([`pivot_descent_sh`]) returns byte-identical `(pivots, P)`.
#[cfg(test)]
pub(crate) fn pivot_descent_q_ref(
    a: &Atdd,
    vt: &Vtree,
    t: usize,
    sh: &Shadow,
) -> (Vec<Pivot>, Mat) {
    let r = a.dim(t);
    let mut bmat = Mat::eye(r);
    let mut pivots: Vec<Pivot> = Vec::with_capacity(r);
    let mut evals: Vec<Vec<Q>> = Vec::with_capacity(r);
    let vars = &vt.node(t).vars;
    for _m in 0..r {
        let mut partial = Partial::default();
        for &v in vars {
            partial.set(v, false);
            let gc = sh.gram_scaled_q(vt, t, &partial);
            if bmat.mul(&gc).frob(&bmat).is_zero() {
                partial.set(v, true);
            }
        }
        let gc = sh.gram_scaled_q(vt, t, &partial);
        assert!(
            !bmat.mul(&gc).frob(&bmat).is_zero(),
            "pivot descent dead end (input not minimized?)"
        );
        pivots.push(Pivot::from_partial(vt, t, &partial));
        let ev = sh.point_eval_exact(vt, t, &partial);
        let w = bmat.mul_vec(&ev);
        evals.push(ev);
        let nz = w
            .iter()
            .position(|x| !x.is_zero())
            .expect("evaluation functional vanishes on S_m");
        let mut rows: Vec<Vec<Q>> = Vec::with_capacity(bmat.r.saturating_sub(1));
        for a_ in 0..bmat.r {
            if a_ == nz {
                continue;
            }
            let coef = &w[a_] / &w[nz];
            rows.push(
                (0..bmat.c)
                    .map(|j| bmat.at(a_, j) - &coef * bmat.at(nz, j))
                    .collect(),
            );
        }
        bmat = if rows.is_empty() {
            Mat::zero(0, r)
        } else {
            Mat::from_rows(rows)
        };
    }
    debug_assert!(
        pivots.windows(2).all(|w| w[0] < w[1]),
        "pivots not strictly ascending"
    );
    (pivots, Mat::from_rows(evals))
}

/// Apply the lex-RREF gauge at every non-root node, bottom-up (toy 617–637).
/// Precondition: minimized, `f ≢ 0`, and for the root assertion Boolean-like
/// (leading value 1 — always true for `f` the indicator of a nonempty set).
/// The mutated `a` *is* canonical afterwards; the returned pivots are the
/// canonical tests per node. Build a [`CanonicalForm`] certificate with
/// [`CanonicalForm::snapshot`] where one is needed — the compile loop skips
/// the per-step snapshot (it was a discarded full-diagram clone per clause).
pub fn canonicalize(a: &mut Atdd, vt: &Vtree) -> Vec<Vec<Pivot>> {
    let root = vt.root();
    let mut pivots: Vec<Vec<Pivot>> = vec![Vec::new(); vt.num_nodes()];
    // One integer shadow maintained across the whole bottom-up gauge: each
    // gauge touches node `t` and its parent, both re-cleared afterwards, so the
    // shadow is exact when a higher node's descent reads it (postorder).
    let mut sh = Shadow::build(a, vt);
    for t in vt.postorder() {
        let (piv, p) = pivot_descent_sh(a, vt, t, &sh);
        if t == root {
            assert!(
                p.at(0, 0).is_one(),
                "root leading value != 1 (f not Boolean/normalized)"
            );
        } else {
            // Gauge to the interpolation basis: ê = (Pᵀ)⁻¹·u, u = Pᵀ·ê.
            let pt = p.transpose();
            let arows = pt
                .inv()
                .expect("P invertible: sampling at the tests is bijective on V_t");
            apply_node_transform(a, vt, t, &arows, &pt);
            sh.refresh(a, t);
            if let Some(par) = vt.node(t).parent {
                sh.refresh(a, par);
            }
        }
        pivots[t] = piv;
    }
    pivots
}

/// `max(numer.bits(), denom.bits())` of one entry (`BigInt::bits` matches
/// Python `int.bit_length`, `bits(0) = 0`).
fn bits_of(x: &Q) -> u64 {
    x.numer().bits().max(x.denom().bits())
}

/// Maximum entry bit size over a diagram's node data (toy `max_bits`).
/// Meaningful after `canonicalize` (the `O(ρ log ρ)` bound applies then).
pub fn max_bits_atdd(a: &Atdd) -> u64 {
    max_bits_data(&a.node)
}

/// Max entry bit size at a single node (the per-node form of
/// [`max_bits_atdd`], for the `cuts.csv` `atdd_bits_max` column).
pub fn node_bits(nd: &NodeData) -> u64 {
    max_bits_data(std::slice::from_ref(nd))
}

/// Total rational bit-mass of a canonicalized diagram: `Σ` over every stored
/// entry of `numer().bits() + denom().bits()`. A whole-diagram size proxy for
/// the canonical tensor data — the aggregate companion to the per-node maximum
/// [`max_bits_atdd`], validating the `O(ρ log ρ)` canonical-bit bound (C5). A
/// stored `0` contributes `1` (its denominator is `1`), so on a sparse diagram
/// the mass tracks [`nonzero_entries_atdd`] plus the numerator/denominator
/// growth of the nonzero weights.
pub fn bit_mass_atdd(a: &Atdd) -> u64 {
    let mut mass = 0u64;
    for d in &a.node {
        match d {
            NodeData::Leaf(m) => {
                for x in m.entries() {
                    mass += x.numer().bits() + x.denom().bits();
                }
            }
            NodeData::Internal(w) => {
                for x in w.iter().flat_map(Mat::entries) {
                    mass += x.numer().bits() + x.denom().bits();
                }
            }
        }
    }
    mass
}

/// Number of nonzero stored entries across a diagram's node data — the sparsity
/// companion to [`bit_mass_atdd`] (how many of the dense tensor slots actually
/// carry a nonzero canonical weight).
pub fn nonzero_entries_atdd(a: &Atdd) -> usize {
    let mut nz = 0usize;
    for d in &a.node {
        match d {
            NodeData::Leaf(m) => nz += m.entries().filter(|x| !x.is_zero()).count(),
            NodeData::Internal(w) => {
                nz += w
                    .iter()
                    .flat_map(Mat::entries)
                    .filter(|x| !x.is_zero())
                    .count();
            }
        }
    }
    nz
}

/// Whether every canonical entry at a single node lies in `{0, 1}` — the
/// `atdd_entries_01` observable (prop:counting's 0/1 implication; its converse
/// fails at MUX gap nodes, whose interpolators are still 0/1 per rem:tddcoincide).
pub fn node_entries_01(nd: &NodeData) -> bool {
    let is01 = |x: &Q| x.is_zero() || x.is_one();
    match nd {
        NodeData::Leaf(m) => m.entries().all(is01),
        NodeData::Internal(w) => w.iter().flat_map(Mat::entries).all(is01),
    }
}

/// Maximum entry bit size over a certificate's data snapshot.
pub fn max_bits(c: &CanonicalForm) -> u64 {
    max_bits_data(&c.data)
}

fn max_bits_data(data: &[NodeData]) -> u64 {
    let mut mb = 0u64;
    for d in data {
        match d {
            NodeData::Leaf(m) => {
                for x in m.entries() {
                    mb = mb.max(bits_of(x));
                }
            }
            NodeData::Internal(w) => {
                for x in w.iter().flat_map(Mat::entries) {
                    mb = mb.max(bits_of(x));
                }
            }
        }
    }
    mb
}

/// The practical Hadamard-pipeline bit bound `~(ρ/2+1)·log2 ρ + 8`
/// (toy 659–663; lem:bits). Diagnostic only — the sole float in the crate;
/// it feeds `StepStats.bits_bound` and test assertions, never any semantic
/// value. The `+8` slack absorbs any ulp issue.
#[allow(
    clippy::cast_precision_loss,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)]
pub fn hadamard_bit_bound(rho: usize) -> u64 {
    if rho <= 1 {
        8
    } else {
        let r = rho as f64;
        (r / 2.0 * r.log2() + r.log2()).floor() as u64 + 8
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::atdd::func;
    use crate::atdd::linalg::q;
    use crate::atdd::minimize::minimize;
    use crate::atdd::minimize::testutil::messy;
    use crate::atdd::shadow::Shadow;
    use crate::rng::Rng;
    use crate::vtree::Vtree;

    /// Stage 2a: the fraction-free integer descent [`pivot_descent_sh`] returns
    /// byte-identical `(pivots, P)` to the reference ℚ descent at every node,
    /// on fractional-interpolator families (HWB/THR — `σ > 1` in the shadow).
    #[test]
    fn integer_descent_matches_q_reference() {
        use crate::atdd::oracle::{build_from_truthtable, to_q};
        use crate::instances::{tt_hwb, tt_threshold};
        let mut rng = Rng::new(0xB47155);
        let mut nodes_checked = 0;
        for trial in 0..14 {
            let n = 3 + rng.below(4);
            let vt = if trial % 2 == 0 {
                Vtree::balanced(n)
            } else {
                Vtree::right_linear(n)
            };
            let f = match trial % 3 {
                0 => to_q(&tt_hwb(n, &vt)),
                1 => to_q(&tt_threshold(n, n.div_ceil(2))),
                _ => loop {
                    let bits: Vec<bool> = (0..(1usize << n)).map(|_| rng.chance(2, 5)).collect();
                    if bits.iter().any(|&b| b) {
                        break to_q(&bits);
                    }
                },
            };
            let mut a = build_from_truthtable(&f, &vt);
            minimize(&mut a, &vt);
            let sh = Shadow::build(&a, &vt);
            for t in vt.postorder() {
                let (piv_i, p_i) = pivot_descent_sh(&a, &vt, t, &sh);
                let (piv_q, p_q) = pivot_descent_q_ref(&a, &vt, t, &sh);
                assert_eq!(piv_i, piv_q, "pivots differ at node {t}, trial {trial}");
                assert_eq!(p_i, p_q, "eval matrix P differs at node {t}, trial {trial}");
                nodes_checked += 1;
            }
        }
        assert!(nodes_checked > 40, "too few nodes checked: {nodes_checked}");
    }

    /// The hand-built PARITY network (same as minimize::tests).
    fn parity_atdd(vt: &Vtree) -> Atdd {
        let root = vt.root();
        let mut node = Vec::with_capacity(vt.num_nodes());
        for t in 0..vt.num_nodes() {
            let n = vt.node(t);
            if n.is_leaf() {
                node.push(NodeData::Leaf(Mat::from_rows(vec![
                    vec![q(1), q(0)],
                    vec![q(0), q(1)],
                ])));
            } else {
                let w_even = Mat::from_rows(vec![vec![q(1), q(0)], vec![q(0), q(1)]]);
                let w_odd = Mat::from_rows(vec![vec![q(0), q(1)], vec![q(1), q(0)]]);
                node.push(if t == root {
                    NodeData::Internal(vec![w_odd])
                } else {
                    NodeData::Internal(vec![w_even, w_odd])
                });
            }
        }
        Atdd { node }
    }

    #[test]
    fn canonical_form_is_gauge_and_padding_invariant() {
        let mut rng = Rng::new(0xCA401);
        for trial in 0..10 {
            let n = 3 + rng.below(3); // 3..=5
            let vt = if trial % 2 == 0 {
                Vtree::balanced(n)
            } else {
                Vtree::random(n, &mut rng)
            };
            let a0 = parity_atdd(&vt);
            let f0 = func(&a0, &vt);
            let mut canons = Vec::new();
            for m in 0..3 {
                let mut am = if m == 0 {
                    a0.clone()
                } else {
                    messy(&a0, &vt, &mut rng, 3)
                };
                minimize(&mut am, &vt);
                let pivots = canonicalize(&mut am, &vt);
                assert_eq!(func(&am, &vt), f0, "canonicalize preserves f");
                am.check(&vt).unwrap();
                canons.push(CanonicalForm::snapshot(&am, pivots));
            }
            assert_eq!(canons[0], canons[1], "gauge/padding invariance");
            assert_eq!(canons[0], canons[2], "gauge/padding invariance");
        }
    }

    #[test]
    fn canonicalize_is_idempotent() {
        let mut rng = Rng::new(0xCA402);
        let vt = Vtree::balanced(4);
        let mut a = messy(&parity_atdd(&vt), &vt, &mut rng, 2);
        minimize(&mut a, &vt);
        let p1 = canonicalize(&mut a, &vt);
        let c1 = CanonicalForm::snapshot(&a, p1);
        let snapshot = a.clone();
        let p2 = canonicalize(&mut a, &vt);
        let c2 = CanonicalForm::snapshot(&a, p2);
        assert_eq!(c1, c2, "idempotent certificate");
        assert_eq!(a, snapshot, "second canonicalize is the identity gauge");
    }

    #[test]
    fn parity_pivots_are_lex_least() {
        // For PARITY at an internal non-root node, V_t = span{even, odd}
        // indicators; the lex-RREF pivots are the two lex-least assignments
        // 00…0 (even) and 00…01 (odd).
        let vt = Vtree::balanced(4);
        let mut a = parity_atdd(&vt);
        minimize(&mut a, &vt);
        let pivots = canonicalize(&mut a, &vt);
        for t in vt.postorder() {
            let piv = &pivots[t];
            if t == vt.root() {
                // lex-least model of odd parity over 4 vars: 0001.
                assert_eq!(piv.len(), 1);
                assert_eq!(piv[0].to_local_index(), 1);
            } else {
                assert_eq!(piv.len(), 2);
                assert_eq!(piv[0].to_local_index(), 0);
                assert_eq!(piv[1].to_local_index(), 1);
            }
        }
    }

    #[test]
    fn bit_bound_matches_toy() {
        // Spot values computed from the Python expression.
        assert_eq!(hadamard_bit_bound(0), 8);
        assert_eq!(hadamard_bit_bound(1), 8);
        assert_eq!(hadamard_bit_bound(2), 10); // 1 + 1 = 2 -> +8
        assert_eq!(hadamard_bit_bound(4), 14); // 4 + 2 = 6 -> +8
        assert_eq!(hadamard_bit_bound(8), 23); // 12 + 3 = 15 -> +8
    }

    #[test]
    fn hwb4_hardcoded_canonical_vector() {
        // Note ex:hwbcanon / FABLE_NOTES/02 verification step 3: HWB_4 on the
        // balanced vtree ((x1,x2),(x3,x4)) — our vars ((0,1),(2,3)). Left
        // tests 01 < 10 < 11, right tests 00 < 01 < 10, root slice
        // [[0,1,1],[1,0,0],[1,0,1]], all entries 0/1, leaves = I₂.
        let vt = Vtree::balanced(4);
        let f: Vec<Q> = crate::instances::tt_hwb(4, &vt)
            .into_iter()
            .map(|b| if b { q(1) } else { q(0) })
            .collect();
        let mut a = crate::atdd::oracle::build_from_truthtable(&f, &vt);
        minimize(&mut a, &vt);
        let pivots = canonicalize(&mut a, &vt);
        let c = CanonicalForm::snapshot(&a, pivots);
        assert_eq!(func(&a, &vt), f);
        let root = vt.root();
        let (l, r) = (vt.node(root).left.unwrap(), vt.node(root).right.unwrap());
        let piv =
            |t: usize| -> Vec<usize> { c.pivots[t].iter().map(Pivot::to_local_index).collect() };
        assert_eq!(piv(l), vec![1, 2, 3]);
        assert_eq!(piv(r), vec![0, 1, 2]);
        let NodeData::Internal(w) = &c.data[root] else {
            panic!("root is internal");
        };
        let expect = Mat::from_rows(vec![
            vec![q(0), q(1), q(1)],
            vec![q(1), q(0), q(0)],
            vec![q(1), q(0), q(1)],
        ]);
        assert_eq!(w[0], expect);
        assert_eq!(max_bits(&c), 1, "HWB_4 canonical entries are all 0/1");
        // Leaves carry the identity interpolators.
        for t in vt.postorder() {
            if vt.node(t).is_leaf() {
                assert_eq!(c.data[t], NodeData::Leaf(Mat::eye(2)));
                assert_eq!(piv(t), vec![0, 1]);
            }
        }
    }
}
