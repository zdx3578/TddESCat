//! Brute-force truth-table oracle: the semantic ground truth for differential
//! testing, plus the cut matrix and the factor-width statistic `S_t`.
//!
//! A truth table is a `Vec<bool>` of length `2^n` indexed by the global
//! assignment index (MSB-first vtree leaf order). This is the same layout the
//! cut matrix and both backends use, so tables compare directly.

use crate::assign::index_to_assignment_into;
use crate::cnf::{Clause, Cnf};
use crate::vtree::Vtree;
use std::collections::HashSet;

/// Truth table of a CNF over `2^n` assignments in vtree leaf order.
pub fn cnf_truth_table(cnf: &Cnf, vtree: &Vtree) -> Vec<bool> {
    let n = vtree.n_vars();
    let mut a = vec![false; vtree.var_space()];
    let mut out = Vec::with_capacity(1usize << n);
    for idx in 0..(1usize << n) {
        index_to_assignment_into(idx, vtree, &mut a);
        out.push(cnf.eval(&a));
    }
    out
}

/// Truth table of a single clause over `2^n` assignments in vtree leaf order.
pub fn clause_truth_table(clause: &Clause, vtree: &Vtree) -> Vec<bool> {
    let n = vtree.n_vars();
    let mut a = vec![false; vtree.var_space()];
    let mut out = Vec::with_capacity(1usize << n);
    for idx in 0..(1usize << n) {
        index_to_assignment_into(idx, vtree, &mut a);
        out.push(clause.eval(&a));
    }
    out
}

/// The cut matrix `M_t(f)`: rows indexed by the local assignment `τ ∈ 2^{X_t}`,
/// columns by the outside assignment. Layout matches `atdd_toy.cut_matrix`:
/// the global index splits as `[prefix | subtree | suffix]` (prefix most
/// significant), and the subtree block is contiguous because leaf order places
/// `X_t` at positions `[off, off + nv)`.
pub fn cut_matrix(f: &[bool], vtree: &Vtree, node_id: usize) -> Vec<Vec<bool>> {
    let root_nv = vtree.n_vars();
    let node = vtree.node(node_id);
    let nt = node.nv();
    let np = node.off;
    let ns = root_nv - nt - np;
    let mut m = vec![vec![false; 1 << (np + ns)]; 1 << nt];
    for ip in 0..(1usize << np) {
        for (itau, row) in m.iter_mut().enumerate() {
            let base = (ip << (nt + ns)) | (itau << ns);
            for isuf in 0..(1usize << ns) {
                row[(ip << ns) | isuf] = f[base | isuf];
            }
        }
    }
    m
}

/// Factor width `S_t(f)`: the number of distinct nonzero rows of the cut matrix
/// (the number of distinct nonzero `X_t`-subfunctions of `f`). This equals the
/// width of the canonical minimal TDD at `t`.
pub fn factor_width(f: &[bool], vtree: &Vtree, node_id: usize) -> usize {
    let m = cut_matrix(f, vtree, node_id);
    let mut seen: HashSet<Vec<bool>> = HashSet::new();
    for row in m {
        if row.iter().any(|&b| b) {
            seen.insert(row);
        }
    }
    seen.len()
}

/// `S_t(f)` at every vtree node, indexed by node id.
pub fn factor_widths(f: &[bool], vtree: &Vtree) -> Vec<usize> {
    (0..vtree.num_nodes())
        .map(|id| factor_width(f, vtree, id))
        .collect()
}

/// Reference construction of the canonical minimal TDD from a truth table
/// (the tt-channel constructor, `FABLE_NOTES/04` D2): one node per distinct
/// nonzero row of the cut matrix at every vtree node, input sets from the
/// row classes of combined assignments, then `minimize` for the canonical
/// numbering. Exponential (`2^n` per node) — oracle/benchmark-tt use only.
/// Returns `None` iff `f ≡ 0`.
pub fn tdd_from_truth_table(f: &[bool], vtree: &Vtree) -> Option<crate::tdd::Tdd> {
    use crate::tdd::{LeafLabel, Level, Tdd};
    use std::collections::HashMap;
    if f.iter().all(|&b| !b) {
        return None;
    }
    let n = vtree.num_nodes();
    // Per node: class id of each local assignment τ (None = zero row).
    let mut class_of: Vec<Vec<Option<u32>>> = vec![Vec::new(); n];
    let mut levels: Vec<Level> = vec![Level::Leaf(Vec::new()); n];
    for t in vtree.postorder() {
        let node = vtree.node(t);
        let m = cut_matrix(f, vtree, t);
        let mut ids: HashMap<Vec<bool>, u32> = HashMap::new();
        let mut classes: Vec<Option<u32>> = Vec::with_capacity(m.len());
        let mut n_classes = 0u32;
        for row in &m {
            if row.iter().any(|&b| b) {
                let id = *ids.entry(row.clone()).or_insert_with(|| {
                    let id = n_classes;
                    n_classes += 1;
                    id
                });
                classes.push(Some(id));
            } else {
                classes.push(None);
            }
        }
        let k = n_classes as usize;
        if node.is_leaf() {
            // Class of value b nonzero ⇒ that value satisfies the node.
            let labels: Vec<LeafLabel> = (0..k)
                .map(|c| {
                    let sat0 = classes[0] == Some(c as u32);
                    let sat1 = classes[1] == Some(c as u32);
                    match (sat0, sat1) {
                        (true, true) => LeafLabel::One,
                        (true, false) => LeafLabel::Neg,
                        (false, true) => LeafLabel::Pos,
                        (false, false) => unreachable!("class has a representative"),
                    }
                })
                .collect();
            levels[t] = Level::Leaf(labels);
        } else {
            let (l, r) = (node.left.unwrap(), node.right.unwrap());
            let n2 = vtree.node(r).nv();
            let mut pairs: Vec<Vec<(u32, u32)>> = vec![Vec::new(); k];
            for (tau, class) in classes.iter().enumerate() {
                let Some(c) = class else { continue };
                let (t1, t2) = (tau >> n2, tau & ((1 << n2) - 1));
                let u = class_of[l][t1].expect("nonzero combined => nonzero left part");
                let v = class_of[r][t2].expect("nonzero combined => nonzero right part");
                pairs[*c as usize].push((u, v));
            }
            let nodes = pairs
                .into_iter()
                .map(|mut e| {
                    e.sort_unstable();
                    e.dedup();
                    e.into_boxed_slice()
                })
                .collect();
            levels[t] = Level::Internal(nodes);
        }
        class_of[t] = classes;
    }
    // f ≢ 0: the root has exactly one nonzero row class. Canonical numbering
    // via minimize (the construction is already minimal; this only renumbers).
    let raw = Tdd { levels };
    Some(crate::tdd::minimize(&raw, vtree))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cnf::Lit;

    #[test]
    fn cnf_and_clause_tables_agree() {
        // F = (x0 ∨ x1) with one clause; table equals the clause table.
        let mut cnf = Cnf::new(2);
        let clause = Clause::new(vec![Lit::positive(0), Lit::positive(1)]);
        cnf.add_clause(clause.clone());
        let t = Vtree::right_linear(2);
        let ct = cnf_truth_table(&cnf, &t);
        // leaf order 0,1: idx 0b00 => x0=0,x1=0 => false; others true
        assert_eq!(ct, vec![false, true, true, true]);
        assert_eq!(clause_truth_table(&clause, &t), ct);
    }

    #[test]
    fn cut_matrix_reconstructs_function() {
        // For every node, M_t[τ][outside] must equal f at the recombined index.
        let mut cnf = Cnf::new(4);
        cnf.add_clause(Clause::new(vec![Lit::positive(0), Lit::negative(2)]));
        cnf.add_clause(Clause::new(vec![Lit::positive(1), Lit::positive(3)]));
        let t = Vtree::balanced(4);
        let f = cnf_truth_table(&cnf, &t);
        for id in t.postorder() {
            let node = t.node(id);
            let (nt, np) = (node.nv(), node.off);
            let ns = 4 - nt - np;
            let m = cut_matrix(&f, &t, id);
            for ip in 0..(1usize << np) {
                for (itau, mrow) in m.iter().enumerate() {
                    for isuf in 0..(1usize << ns) {
                        let g = (ip << (nt + ns)) | (itau << ns) | isuf;
                        assert_eq!(mrow[(ip << ns) | isuf], f[g]);
                    }
                }
            }
        }
    }

    #[test]
    fn parity_factor_width_is_two() {
        // PARITY over n vars: every internal node (∅ ⊊ X_t ⊊ X) has S_t = 2.
        let n = 5;
        let t = Vtree::balanced(n);
        let f: Vec<bool> = (0..(1usize << n))
            .map(|i| i.count_ones() & 1 == 1)
            .collect();
        for id in t.postorder() {
            let node = t.node(id);
            if node.nv() < n {
                // ∅ ⊊ X_t ⊊ X
                assert_eq!(factor_width(&f, &t, id), 2, "node {id}");
            } else {
                // root: single nonzero row-class (whole function)
                assert_eq!(factor_width(&f, &t, id), 1);
            }
        }
    }

    #[test]
    fn tdd_from_truth_table_is_canonical() {
        // The tt-channel constructor must agree with the CNF compiler's
        // canonical output on shared instances, and with the S_t oracle on
        // arbitrary truth tables (incl. non-CNF-generated ones).
        use crate::instances::{random_kcnf, tt_random};
        use crate::rng::Rng;
        let mut rng = Rng::new(0x77);
        let mut checked = 0;
        while checked < 25 {
            let n = 2 + rng.below(5);
            let vt = match rng.below(3) {
                0 => Vtree::right_linear(n),
                1 => Vtree::balanced(n),
                _ => Vtree::random(n, &mut rng),
            };
            // (a) vs the compiler on CNF instances.
            let cnf = random_kcnf(n, 2 + rng.below(6), 1 + rng.below(n.min(3)), &mut rng);
            let f = cnf_truth_table(&cnf, &vt);
            match (
                tdd_from_truth_table(&f, &vt),
                crate::tdd::compile(&cnf, &vt),
            ) {
                (None, crate::tdd::Compiled::Unsat) => {}
                (Some(t), crate::tdd::Compiled::Tdd(c)) => {
                    assert_eq!(t, c, "tt constructor == compiled canonical");
                }
                _ => panic!("verdict mismatch"),
            }
            // (b) vs the width oracle on a random function.
            let g = tt_random(n, 2, 5, &mut rng);
            let t = tdd_from_truth_table(&g, &vt).expect("nonzero");
            assert_eq!(t.to_truth_table(&vt), g);
            for id in vt.postorder() {
                assert_eq!(t.widths()[id], factor_width(&g, &vt, id));
            }
            checked += 1;
        }
    }

    #[test]
    fn constant_and_root_widths() {
        // A satisfiable function has S_root = 1 (one nonzero row at the root:
        // the whole 1x1 "outside" is empty, the single row is f itself).
        let mut cnf = Cnf::new(3);
        cnf.add_clause(Clause::new(vec![Lit::positive(0)]));
        let t = Vtree::right_linear(3);
        let f = cnf_truth_table(&cnf, &t);
        assert_eq!(factor_width(&f, &t, t.root()), 1);
    }
}
