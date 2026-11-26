//! Brute-force oracle for the ATDD backend — the exponential ground truth for
//! differential testing (`FABLE_NOTES/02` §7; `atdd_toy.py` 340–396).
//!
//! Everything here builds `2^n` objects and is test/oracle use only (guarded by
//! `assert!(n <= 24)` at the table-building step). The core object is the cut
//! matrix `M_t(f)` over ℚ, with rows indexed by the local assignment
//! `τ ∈ 2^{X_t}` and columns by the outside assignment; its rank is the factor
//! rank `ρ_t` and its number of distinct nonzero rows is `S_t`. The lex-RREF of
//! the (deduped) column space gives the canonical bond bases from which
//! `reference_canonical` / `build_from_truthtable` assemble the canonical ATDD
//! (prop:realization(ii)).

use super::linalg::{Mat, Q};
use super::{Atdd, NodeData};
use crate::vtree::Vtree;
use num_traits::{One, Zero};
use std::collections::BTreeSet;

/// Lift a boolean truth table to `ℚ` (`false → 0`, `true → 1`).
pub fn to_q(f: &[bool]) -> Vec<Q> {
    f.iter()
        .map(|&b| if b { Q::one() } else { Q::zero() })
        .collect()
}

/// The cut matrix `M_t(f)` over ℚ: rows indexed by the local assignment
/// `τ ∈ 2^{X_t}` (`2^{nv(t)}` rows), columns by the outside assignment
/// (`2^{n-nv(t)}` cols). Same index layout as `truthtable::cut_matrix`: the
/// global index splits as `[prefix | subtree | suffix]` (prefix most
/// significant) with the subtree block contiguous, and the column index is
/// `(prefix << ns) | suffix`.
pub fn cut_matrix_q(f: &[Q], vt: &Vtree, t: usize) -> Mat {
    let n = vt.n_vars();
    assert!(n <= 24, "cut_matrix_q builds a 2^n table (n = {n})");
    debug_assert_eq!(f.len(), 1usize << n, "truth table length must be 2^n");
    let node = vt.node(t);
    let nt = node.nv();
    let np = node.off;
    let ns = n - nt - np;
    let rows = 1usize << nt;
    let cols = 1usize << (np + ns);
    let mut m = Mat::zero(rows, cols);
    for ip in 0..(1usize << np) {
        for itau in 0..rows {
            let base = (ip << (nt + ns)) | (itau << ns);
            for isuf in 0..(1usize << ns) {
                let v = &f[base | isuf];
                if !v.is_zero() {
                    *m.at_mut(itau, (ip << ns) | isuf) = v.clone();
                }
            }
        }
    }
    m
}

/// Factor rank `ρ_t = rank M_t(f)` at vtree node `t`.
pub fn brute_rank(f: &[Q], vt: &Vtree, t: usize) -> usize {
    cut_matrix_q(f, vt, t).rank()
}

/// Factor rank at every vtree node, indexed by node id (covers all
/// `0..vt.num_nodes()`).
pub fn brute_ranks(f: &[Q], vt: &Vtree) -> Vec<usize> {
    (0..vt.num_nodes()).map(|t| brute_rank(f, vt, t)).collect()
}

/// Factor width `S_t(f)`: the number of DISTINCT NONZERO rows of the cut matrix
/// over ℚ. Under (Q-INV) every stored `Q` is reduced, so structural equality of
/// rows coincides with mathematical equality.
pub fn subfunction_count_q(f: &[Q], vt: &Vtree, t: usize) -> usize {
    let m = cut_matrix_q(f, vt, t);
    let mut seen: BTreeSet<Vec<Q>> = BTreeSet::new();
    for i in 0..m.r {
        let row = m.row(i);
        if row.iter().any(|x| !x.is_zero()) {
            seen.insert(row.to_vec());
        }
    }
    seen.len()
}

/// Lex-RREF basis of `V_t = span` of the columns of `M_t` (functions of `τ`),
/// port of `atdd_toy.ref_subspace_basis` (360–369). Collects the DISTINCT
/// NONZERO columns into a `BTreeSet` (sorted for determinism — RREF is
/// row-space-determined, so the sort is cosmetic parity with the toy), builds a
/// matrix whose ROWS are those columns, and returns its `rref`. `piv` are the
/// pivot positions in `τ`-index space (the canonical tests as local indices).
pub fn ref_subspace_basis(f: &[Q], vt: &Vtree, t: usize) -> (Mat, Vec<usize>) {
    let m = cut_matrix_q(f, vt, t);
    let mut gens: BTreeSet<Vec<Q>> = BTreeSet::new();
    for j in 0..m.c {
        let col: Vec<Q> = (0..m.r).map(|i| m.at(i, j).clone()).collect();
        if col.iter().any(|x| !x.is_zero()) {
            gens.insert(col);
        }
    }
    let rows: Vec<Vec<Q>> = gens.into_iter().collect();
    if rows.is_empty() {
        // Zero function at t (skipped by callers): 0 × 2^{nv(t)} basis
        // (each column vector has `m.r` = 2^{nv(t)} entries).
        return (Mat::zero(0, m.r), Vec::new());
    }
    Mat::from_rows(rows).rref()
}

/// Canonical ATDD data at every vtree node (indexed by node id), port of
/// `atdd_toy.reference_canonical` (371–385). Each node's basis is computed once
/// and memoized. For a leaf, the entry is `(piv, Leaf(e))` with `e` the `d×2`
/// RREF basis. For an internal node with children `l, r`, slice `i` is the
/// `d(l)×d(r)` matrix `[cj][ck] = e[i][p1[cj]·n2 + p2[ck]]` where
/// `n2 = 2^{nv(r)}` and `p1, p2` are the children's pivots.
pub fn reference_canonical(f: &[Q], vt: &Vtree) -> Vec<(Vec<usize>, NodeData)> {
    let nn = vt.num_nodes();
    let bases: Vec<(Mat, Vec<usize>)> = (0..nn).map(|t| ref_subspace_basis(f, vt, t)).collect();
    (0..nn)
        .map(|t| {
            let node = vt.node(t);
            let (e, piv) = &bases[t];
            if node.is_leaf() {
                (piv.clone(), NodeData::Leaf(e.clone()))
            } else {
                let (l, r) = (node.left.unwrap(), node.right.unwrap());
                let p1 = &bases[l].1;
                let p2 = &bases[r].1;
                let n2 = 1usize << vt.node(r).nv();
                let slices: Vec<Mat> = (0..e.r)
                    .map(|i| {
                        Mat::from_fn(p1.len(), p2.len(), |cj, ck| {
                            e.at(i, p1[cj] * n2 + p2[ck]).clone()
                        })
                    })
                    .collect();
                (piv.clone(), NodeData::Internal(slices))
            }
        })
        .collect()
}

/// Build the canonical ATDD directly from a truth table over ℚ (prop
/// realization(ii)), port of `atdd_toy.build_from_truthtable` (390–396).
pub fn build_from_truthtable(f: &[Q], vt: &Vtree) -> Atdd {
    Atdd {
        node: reference_canonical(f, vt)
            .into_iter()
            .map(|(_, d)| d)
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::atdd::func;
    use crate::instances::{random_kcnf, tt_hwb, tt_parity};
    use crate::rng::Rng;
    use crate::truthtable::{cnf_truth_table, factor_width};
    use crate::vtree::Vtree;

    /// (a) Random small CNFs on three vtree shapes: exact reconstruction,
    /// dims == brute_ranks, the sandwich ρ ≤ S ≤ 2^ρ−1, and S == factor_width.
    #[test]
    fn random_cnf_reconstruct_dims_sandwich() {
        let mut rng = Rng::new(0x0A7DD);
        let mut tested = 0;
        let mut attempt = 0;
        while tested < 30 && attempt < 400 {
            attempt += 1;
            let n = 3 + rng.below(4); // 3..=6
            let m = 1 + rng.below(2 * n);
            let cnf = random_kcnf(n, m, 3, &mut rng);
            // Build on a fixed vtree just to get a boolean table.
            let vt0 = Vtree::right_linear(n);
            let bf = cnf_truth_table(&cnf, &vt0);
            if !bf.iter().any(|&b| b) {
                continue; // skip UNSAT (all-zero) tables
            }
            tested += 1;
            let vtrees = [
                Vtree::right_linear(n),
                Vtree::balanced(n),
                Vtree::random(n, &mut rng),
            ];
            for vt in &vtrees {
                let bf = cnf_truth_table(&cnf, vt);
                let qf = to_q(&bf);
                let a = build_from_truthtable(&qf, vt);
                assert!(a.check(vt).is_ok(), "structural invariants (n={n})");
                assert_eq!(func(&a, vt), qf, "exact reconstruction (n={n})");
                let ranks = brute_ranks(&qf, vt);
                assert_eq!(a.dims(), ranks, "dims == brute_ranks (n={n})");
                for (id, &rho) in ranks.iter().enumerate() {
                    let s = subfunction_count_q(&qf, vt, id);
                    assert_eq!(s, factor_width(&bf, vt, id), "S == factor_width");
                    if rho > 0 {
                        assert!(rho <= s, "ρ ≤ S at node {id} (ρ={rho}, S={s})");
                        assert!(s < 1usize << rho, "S ≤ 2^ρ−1 at node {id} (ρ={rho}, S={s})");
                    } else {
                        assert_eq!(s, 0, "ρ=0 ⇒ S=0 at node {id}");
                    }
                }
            }
        }
        assert!(tested >= 30, "too few satisfiable instances: {tested}");
    }

    /// (b) PARITY_6 on a balanced vtree: every internal non-root node has ρ = 2.
    #[test]
    fn parity6_internal_rank_two() {
        let n = 6;
        let vt = Vtree::balanced(n);
        let qf = to_q(&tt_parity(n));
        for id in vt.postorder() {
            let node = vt.node(id);
            if !node.is_leaf() && id != vt.root() {
                assert_eq!(brute_rank(&qf, &vt, id), 2, "node {id}");
            }
        }
    }

    /// (c) `ref_subspace_basis` structure: pivots strictly ascending, one row
    /// per pivot, and the identity pattern R[i][piv[j]] == δ_ij.
    #[test]
    fn ref_basis_pivot_structure() {
        let n = 5;
        let vt = Vtree::balanced(n);
        let qf = to_q(&tt_hwb(n, &vt));
        for id in vt.postorder() {
            let (r, piv) = ref_subspace_basis(&qf, &vt, id);
            assert!(
                piv.windows(2).all(|w| w[0] < w[1]),
                "pivots strictly ascending at node {id}"
            );
            assert_eq!(r.r, piv.len(), "one row per pivot at node {id}");
            for i in 0..r.r {
                for (j, &p) in piv.iter().enumerate() {
                    let want = if i == j { Q::one() } else { Q::zero() };
                    assert_eq!(*r.at(i, p), want, "δ pattern at node {id} ({i},{j})");
                }
            }
        }
    }

    /// (d) HWB_7 on a balanced vtree: the max factor rank is ≤ n+2 = 9.
    #[test]
    fn hwb7_max_rank_bound() {
        let n = 7;
        let vt = Vtree::balanced(n);
        let qf = to_q(&tt_hwb(n, &vt));
        let max = brute_ranks(&qf, &vt).into_iter().max().unwrap();
        assert!(max <= n + 2, "max rank {max} > {}", n + 2);
    }
}
