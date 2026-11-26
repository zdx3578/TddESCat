//! Combination networks (`FABLE_NOTES/02` §3; toy 291–320; thm:operations):
//! the Hadamard (pointwise-product) apply, direct sum, and the `O(n)` seed
//! networks (constant-1, term, clause) the compiler conjoins.
//!
//! The clause seed is the one deliberate extension beyond the toy (which
//! builds clause networks from truth tables): `f_C = 1 − T_{¬l_1 ∧ … ∧ ¬l_k}`
//! realized as a direct sum with the term block negated at the root. All
//! entries lie in `{−1, 0, 1}` and `d(t) ≤ 2` everywhere. It is
//! differential-tested against `oracle::build_from_truthtable` below.

use super::linalg::{Mat, Q};
use super::{Atdd, NodeData};
use crate::vtree::Vtree;
use num_traits::{One, Zero};

/// Pointwise-product network (toy `hadamard`; conjunction on Boolean inputs).
/// Both operands must live on the same vtree. Dimensions multiply:
/// `d(t) = d_A(t) · d_B(t)`; pair index is A-major (`pair(i,i') = i·d_B + i'`).
pub fn hadamard(a: &Atdd, b: &Atdd, vt: &Vtree) -> Atdd {
    let mut node = Vec::with_capacity(vt.num_nodes());
    for t in 0..vt.num_nodes() {
        match (&a.node[t], &b.node[t]) {
            (NodeData::Leaf(la), NodeData::Leaf(lb)) => {
                let mut rows = Vec::with_capacity(la.r * lb.r);
                for i in 0..la.r {
                    for ib in 0..lb.r {
                        rows.push(vec![la.at(i, 0) * lb.at(ib, 0), la.at(i, 1) * lb.at(ib, 1)]);
                    }
                }
                node.push(NodeData::Leaf(Mat::from_rows(rows)));
            }
            (NodeData::Internal(wa), NodeData::Internal(wb)) => {
                let vn = vt.node(t);
                let (l, r) = (vn.left.unwrap(), vn.right.unwrap());
                let (r1a, r1b) = (a.dim(l), b.dim(l));
                let (r2a, r2b) = (a.dim(r), b.dim(r));
                let mut mats = Vec::with_capacity(wa.len() * wb.len());
                for wai in wa {
                    for wbi in wb {
                        // kron(Wa_i, Wb_ib), zero-skipped.
                        let mut m = Mat::zero(r1a * r1b, r2a * r2b);
                        for j1 in 0..r1a {
                            for k1 in 0..r2a {
                                let c1 = wai.at(j1, k1);
                                if c1.is_zero() {
                                    continue;
                                }
                                for j2 in 0..r1b {
                                    for k2 in 0..r2b {
                                        let c2 = wbi.at(j2, k2);
                                        if !c2.is_zero() {
                                            *m.at_mut(j1 * r1b + j2, k1 * r2b + k2) = c1 * c2;
                                        }
                                    }
                                }
                            }
                        }
                        mats.push(m);
                    }
                }
                node.push(NodeData::Internal(mats));
            }
            _ => unreachable!("operands disagree on leaf/internal at node {t}"),
        }
    }
    Atdd { node }
}

/// The constant-1 network: leaf rows `[1,1]`, every slice `[[1]]`.
pub fn constant_one(vt: &Vtree) -> Atdd {
    let node = (0..vt.num_nodes())
        .map(|t| {
            if vt.node(t).is_leaf() {
                NodeData::Leaf(Mat::from_rows(vec![vec![Q::one(), Q::one()]]))
            } else {
                NodeData::Internal(vec![Mat::from_scalar(Q::one())])
            }
        })
        .collect();
    Atdd { node }
}

/// The term network `T_L` for a literal conjunction `L` (all dims 1): the
/// indicator of "all literals in `L` are satisfied". `lits` has ≤ 1 literal
/// per variable.
pub fn term(vt: &Vtree, lits: &[(usize, bool)]) -> Atdd {
    let node = (0..vt.num_nodes())
        .map(|t| {
            let vn = vt.node(t);
            if let Some(x) = vn.var {
                let row = match lits.iter().find(|(v, _)| *v == x) {
                    Some(&(_, true)) => vec![Q::zero(), Q::one()], // x ∈ L
                    Some(&(_, false)) => vec![Q::one(), Q::zero()], // ¬x ∈ L
                    None => vec![Q::one(), Q::one()],
                };
                NodeData::Leaf(Mat::from_rows(vec![row]))
            } else {
                NodeData::Internal(vec![Mat::from_scalar(Q::one())])
            }
        })
        .collect();
    Atdd { node }
}

/// Scale the represented function by `c` (root slice / root leaf row scaled).
pub fn scale_root(a: &mut Atdd, vt: &Vtree, c: &Q) {
    let root = vt.root();
    match &a.node[root] {
        NodeData::Leaf(m) => {
            a.node[root] = NodeData::Leaf(Mat::from_fn(m.r, m.c, |i, j| c * m.at(i, j)));
        }
        NodeData::Internal(w) => {
            let scaled = w
                .iter()
                .map(|wi| Mat::from_fn(wi.r, wi.c, |i, j| c * wi.at(i, j)))
                .collect();
            a.node[root] = NodeData::Internal(scaled);
        }
    }
}

/// Direct sum: computes `f + g` with `d(t) = d_A(t) + d_B(t)` at non-root
/// nodes (stacked leaf rows / per-slice block diagonals) and `d(root) = 1`
/// (single slice, `W^A_root` top-left, `W^B_root` bottom-right — or added
/// leaf rows when the root is a leaf, i.e. `n = 1`).
pub fn direct_sum(a: &Atdd, b: &Atdd, vt: &Vtree) -> Atdd {
    let root = vt.root();
    let mut node = Vec::with_capacity(vt.num_nodes());
    for t in 0..vt.num_nodes() {
        let data = match (&a.node[t], &b.node[t]) {
            (NodeData::Leaf(la), NodeData::Leaf(lb)) => {
                if t == root {
                    // n = 1: f + g pointwise on the single variable.
                    NodeData::Leaf(Mat::from_fn(1, 2, |_, j| la.at(0, j) + lb.at(0, j)))
                } else {
                    let rows = (0..la.r)
                        .map(|i| la.row(i).to_vec())
                        .chain((0..lb.r).map(|i| lb.row(i).to_vec()))
                        .collect();
                    NodeData::Leaf(Mat::from_rows(rows))
                }
            }
            (NodeData::Internal(wa), NodeData::Internal(wb)) => {
                let vn = vt.node(t);
                let (l, r) = (vn.left.unwrap(), vn.right.unwrap());
                let (d1a, d2a) = (a.dim(l), a.dim(r));
                let (d1b, d2b) = (b.dim(l), b.dim(r));
                let block = |wi: &Mat, top_left: bool| {
                    Mat::from_fn(d1a + d1b, d2a + d2b, |x, y| {
                        if top_left {
                            if x < d1a && y < d2a {
                                wi.at(x, y).clone()
                            } else {
                                Q::zero()
                            }
                        } else if x >= d1a && y >= d2a {
                            wi.at(x - d1a, y - d2a).clone()
                        } else {
                            Q::zero()
                        }
                    })
                };
                if t == root {
                    // Single slice: W^A_root ⊕ W^B_root, written directly
                    // (no add — the blocks are disjoint).
                    let m = Mat::from_fn(d1a + d1b, d2a + d2b, |x, y| {
                        if x < d1a && y < d2a {
                            wa[0].at(x, y).clone()
                        } else if x >= d1a && y >= d2a {
                            wb[0].at(x - d1a, y - d2a).clone()
                        } else {
                            Q::zero()
                        }
                    });
                    NodeData::Internal(vec![m])
                } else {
                    let slices = wa
                        .iter()
                        .map(|wi| block(wi, true))
                        .chain(wb.iter().map(|wi| block(wi, false)))
                        .collect();
                    NodeData::Internal(slices)
                }
            }
            _ => unreachable!("operands disagree on leaf/internal at node {t}"),
        };
        node.push(data);
    }
    Atdd { node }
}

/// The clause seed network for a non-empty, non-tautological clause
/// `C = l_1 ∨ … ∨ l_k` given as `(variable, positive)` literals:
/// `f_C = 1 − T_{¬l_1 ∧ … ∧ ¬l_k}` (spec §3.3). Entries in `{−1,0,1}`,
/// `d(t) ≤ 2` everywhere (matching "clause factor rank ≤ 2").
pub fn clause(vt: &Vtree, lits: &[(usize, bool)]) -> Atdd {
    assert!(!lits.is_empty(), "clause() needs a non-empty clause");
    let negated: Vec<(usize, bool)> = lits.iter().map(|&(v, s)| (v, !s)).collect();
    let mut t = term(vt, &negated);
    scale_root(&mut t, vt, &-Q::one());
    direct_sum(&constant_one(vt), &t, vt)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::atdd::func;
    use crate::atdd::linalg::q;
    use crate::atdd::oracle::{build_from_truthtable, to_q};
    use crate::cnf::Clause;
    use crate::instances::{random_kcnf, tt_clause};
    use crate::rng::Rng;
    use crate::vtree::Vtree;

    fn lits_of(clause: &Clause) -> Option<Vec<(usize, bool)>> {
        match crate::tdd::normalize_clause(clause) {
            crate::tdd::NormalizedClause::Lits(v) => Some(v),
            _ => None,
        }
    }

    fn random_nonzero_tt(n: usize, rng: &mut Rng) -> Vec<crate::atdd::linalg::Q> {
        loop {
            let f: Vec<bool> = (0..(1usize << n)).map(|_| rng.chance(2, 5)).collect();
            if f.iter().any(|&b| b) {
                return to_q(&f);
            }
        }
    }

    #[test]
    fn hadamard_is_pointwise_product() {
        let mut rng = Rng::new(0xADDA);
        for trial in 0..25 {
            let n = 2 + rng.below(4); // 2..=5
            let vt = if trial % 2 == 0 {
                Vtree::balanced(n)
            } else {
                Vtree::random(n, &mut rng)
            };
            let fa = random_nonzero_tt(n, &mut rng);
            let fb = random_nonzero_tt(n, &mut rng);
            let a = build_from_truthtable(&fa, &vt);
            let b = build_from_truthtable(&fb, &vt);
            let h = hadamard(&a, &b, &vt);
            h.check(&vt).unwrap();
            let expect: Vec<_> = fa.iter().zip(&fb).map(|(x, y)| x * y).collect();
            assert_eq!(func(&h, &vt), expect, "n={n}");
            // dims multiply
            for t in vt.postorder() {
                assert_eq!(h.dim(t), a.dim(t) * b.dim(t));
            }
        }
    }

    #[test]
    fn clause_seed_matches_truthtable_oracle() {
        // The §3.3 mandatory differential test: the derived clause network vs
        // build_from_truthtable on random clauses and vtrees.
        let mut rng = Rng::new(20260707);
        let mut checked = 0;
        for _ in 0..150 {
            let n = 1 + rng.below(6); // 1..=6
            let k = 1 + rng.below(n.min(4));
            let cnf = random_kcnf(n, 1, k, &mut rng);
            let Some(ls) = lits_of(&cnf.clauses[0]) else {
                continue;
            };
            let vt = match rng.below(3) {
                0 => Vtree::right_linear(n),
                1 => Vtree::balanced(n),
                _ => Vtree::random(n, &mut rng),
            };
            let c = clause(&vt, &ls);
            c.check(&vt).unwrap();
            let expect = to_q(&tt_clause(&ls, &vt));
            assert_eq!(func(&c, &vt), expect, "clause {ls:?} on n={n}");
            assert_eq!(
                func(&build_from_truthtable(&expect, &vt), &vt),
                expect,
                "oracle self-check"
            );
            // width ≤ 2 raw (before any minimization)
            assert!(c.width() <= 2, "clause width {} > 2", c.width());
            checked += 1;
        }
        assert!(checked > 100, "too few clauses checked: {checked}");
    }

    #[test]
    fn term_and_constant_and_direct_sum() {
        let mut rng = Rng::new(42);
        let n = 4;
        let vt = Vtree::balanced(n);
        // constant 1
        let one = constant_one(&vt);
        assert!(func(&one, &vt).iter().all(num_traits::One::is_one));
        // term = indicator of the literal conjunction
        let ls = vec![(0usize, true), (2usize, false)];
        let tm = term(&vt, &ls);
        let expect: Vec<_> = (0..(1usize << n))
            .map(|idx| {
                let a = crate::assign::index_to_assignment(idx, &vt);
                if a[0] && !a[2] { q(1) } else { q(0) }
            })
            .collect();
        assert_eq!(func(&tm, &vt), expect);
        // direct sum computes f + g on random functions
        for _ in 0..10 {
            let fa = random_nonzero_tt(n, &mut rng);
            let fb = random_nonzero_tt(n, &mut rng);
            let a = build_from_truthtable(&fa, &vt);
            let b = build_from_truthtable(&fb, &vt);
            let s = direct_sum(&a, &b, &vt);
            s.check(&vt).unwrap();
            let expect: Vec<_> = fa.iter().zip(&fb).map(|(x, y)| x + y).collect();
            assert_eq!(func(&s, &vt), expect);
        }
    }

    #[test]
    fn clause_seed_n1() {
        // n = 1: the vtree root is a leaf; both polarities.
        let vt = Vtree::right_linear(1);
        for positive in [true, false] {
            let c = clause(&vt, &[(0, positive)]);
            c.check(&vt).unwrap();
            let expect = if positive {
                vec![q(0), q(1)]
            } else {
                vec![q(1), q(0)]
            };
            assert_eq!(func(&c, &vt), expect);
        }
    }
}
