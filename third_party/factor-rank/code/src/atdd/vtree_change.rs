//! Direct output-sensitive vtree change for the ATDD backend (M7; Theorem 10
//! of `FABLE_NOTES/05_vtree_rotation.md`; the truth-table Gram route validated
//! by `reference/rotation_alg_toy.py` item E).
//!
//! Given `f` (as a truth table) and any target vtree `T2`, this computes the
//! canonical ATDD of `f` w.r.t. `T2` bottom-up, *without* enumerating the
//! `2^{|Y|}` rows at each node `Y`. Instead it uses the candidate-containment
//! theorem (Step 1): the canonical tests of `Y` are a subset of the products
//! `p^{Y1}_j × p^{Y2}_k` of the children's tests. A restricted greedy over
//! those `ρ(Y1)·ρ(Y2)` candidates recovers exactly the canonical tests `P_Y`
//! (Step 2), and the canonical tensor entries are the interpolation-basis
//! evaluations `e^Y_i(q)` at the candidates, obtained from the Gram system
//! `N·e(q) = b(q)` over the test rows (Step 4). All row access is through the
//! truth table (the "truth-table Gram route"); the conditioning route is a
//! stretch item.
//!
//! The output is byte-identical to `oracle::reference_canonical` (which instead
//! RREFs all `2^{|Y|}` columns) — a cross-check of the whole Theorem 10
//! mechanism, discovery and assembly alike.

use super::canonical::Pivot;
use super::linalg::{Mat, Q};
use super::oracle::cut_matrix_q;
use super::{Atdd, NodeData};
use crate::vtree::Vtree;
use num_traits::Zero;

/// The result of a Theorem 10 vtree change, with the diagnostics that make the
/// candidate restriction observable.
pub struct Change {
    /// The canonical ATDD of `f` w.r.t. the target vtree.
    pub atdd: Atdd,
    /// Canonical tests per node id.
    pub pivots: Vec<Vec<Pivot>>,
    /// Per node id: `(#candidates examined, #tests found)`; candidates ≥ tests,
    /// and the gap is the whole point (far fewer than `2^{nv}` rows examined).
    pub candidate_counts: Vec<(usize, usize)>,
    /// The largest Gram value `⟨f[q], f[q']⟩` seen — an integer in `[0, 2^n]`
    /// for Boolean `f` (Step 3).
    pub max_gram: Q,
}

/// Inner product `Σ_σ a[σ]·b[σ]` of two cut-matrix rows (zero-skipped).
fn inner(a: &[Q], b: &[Q]) -> Q {
    let mut s = Q::zero();
    for (x, y) in a.iter().zip(b) {
        if !x.is_zero() && !y.is_zero() {
            s += x * y;
        }
    }
    s
}

/// Local indices of the child-test products `p1_j × p2_k = j·n2 + k`
/// (`n2 = 2^{nv(right child)}`), in `(j,k)`-lex order — the single place the
/// product convention lives (Theorem 10 Step 1). Since each `k < n2`, the
/// result is already ascending.
fn product_indices(t1: &[usize], t2: &[usize], n2: usize) -> Vec<usize> {
    let mut out = Vec::with_capacity(t1.len() * t2.len());
    for &j in t1 {
        for &k in t2 {
            out.push(j * n2 + k);
        }
    }
    out
}

/// A reduced spanning set of rows: each stored row has a distinct leading
/// nonzero column, so membership is an exact echelon reduction.
struct Span {
    rows: Vec<(usize, Vec<Q>)>, // (leading column, reduced row)
}

impl Span {
    fn new() -> Span {
        Span { rows: Vec::new() }
    }

    /// If `v` is already spanned, return `false` (unchanged); otherwise insert
    /// its reduced residual and return `true`.
    fn insert_if_new(&mut self, v: &[Q]) -> bool {
        let mut r = v.to_vec();
        for (lead, row) in &self.rows {
            if !r[*lead].is_zero() {
                let c = &r[*lead] / &row[*lead];
                for (x, y) in r.iter_mut().zip(row) {
                    if !y.is_zero() {
                        *x -= &c * y;
                    }
                }
            }
        }
        match r.iter().position(|x| !x.is_zero()) {
            Some(lead) => {
                self.rows.push((lead, r));
                true
            }
            None => false,
        }
    }
}

/// The canonical ATDD of `f` (a `2^n` truth table over ℚ, `f ≢ 0`) w.r.t.
/// `vt` via Theorem 10 (candidate products + restricted greedy + Gram-solved
/// interpolation entries).
pub fn theorem10_canonical(f: &[Q], vt: &Vtree) -> Change {
    let nn = vt.num_nodes();
    let mut tests: Vec<Vec<usize>> = vec![Vec::new(); nn]; // local test indices
    let mut node_data: Vec<Option<NodeData>> = vec![None; nn];
    let mut counts = vec![(0usize, 0usize); nn];
    let mut max_gram = Q::zero();

    for t in vt.postorder() {
        let node = vt.node(t);
        let m = cut_matrix_q(f, vt, t);

        // --- Step 1: candidate local indices (products of children tests). ---
        let candidates: Vec<usize> = if node.is_leaf() {
            vec![0, 1]
        } else {
            let r = node.right.unwrap();
            let n2 = 1usize << vt.node(r).nv();
            product_indices(&tests[node.left.unwrap()], &tests[r], n2)
        };

        // --- Step 2: restricted greedy = the canonical tests P_Y. -----------
        let mut span = Span::new();
        let mut kept: Vec<usize> = Vec::with_capacity(candidates.len());
        for &q in &candidates {
            if span.insert_if_new(m.row(q)) {
                kept.push(q);
            }
        }
        counts[t] = (candidates.len(), kept.len());

        // --- Steps 3–4: Gram system N·e(q) = b(q) for the interpolation. ----
        // N is symmetric, so fill the upper triangle once (rows are 2^{n−nv}
        // long) and mirror; fold the max Gram value in the same pass.
        let r = kept.len();
        let mut n_gram = Mat::zero(r, r);
        for a in 0..r {
            for b in a..r {
                let g = inner(m.row(kept[a]), m.row(kept[b]));
                if g > max_gram {
                    max_gram = g.clone();
                }
                if a != b {
                    *n_gram.at_mut(b, a) = g.clone();
                }
                *n_gram.at_mut(a, b) = g;
            }
        }
        let n_inv = n_gram
            .inv()
            .expect("Gram of the canonical test rows is invertible over ℚ");
        // e(q) = N⁻¹ b(q): the coefficients of row q in the test-row basis, which
        // equal the interpolation-basis values e^Y_i(q) (Theorem 10 Step 4).
        let e_at = |q: usize| -> Vec<Q> {
            let b: Vec<Q> = kept.iter().map(|&p| inner(m.row(q), m.row(p))).collect();
            n_inv.mul_vec(&b)
        };

        node_data[t] = Some(if node.is_leaf() {
            // Leaf: row i = [e_i(x=0), e_i(x=1)].
            let e0 = e_at(0);
            let e1 = e_at(1);
            NodeData::Leaf(Mat::from_fn(r, 2, |i, x| {
                if x == 0 { e0[i].clone() } else { e1[i].clone() }
            }))
        } else {
            // Internal: slice i is ρ(Y1)×ρ(Y2), W_i[jo][ko] = e_i(c1_jo × c2_ko).
            let (l, rr) = (node.left.unwrap(), node.right.unwrap());
            let n2 = 1usize << vt.node(rr).nv();
            let (t1, t2) = (&tests[l], &tests[rr]);
            let evals: Vec<Vec<Q>> = product_indices(t1, t2, n2).into_iter().map(&e_at).collect();
            let slices: Vec<Mat> = (0..r)
                .map(|i| {
                    Mat::from_fn(t1.len(), t2.len(), |jo, ko| {
                        evals[jo * t2.len() + ko][i].clone()
                    })
                })
                .collect();
            NodeData::Internal(slices)
        });
        tests[t] = kept;
    }

    let pivots: Vec<Vec<Pivot>> = (0..nn)
        .map(|t| {
            let nb = vt.node(t).nv();
            tests[t]
                .iter()
                .map(|&idx| Pivot::from_local_index(idx, nb))
                .collect()
        })
        .collect();
    Change {
        atdd: Atdd {
            node: node_data.into_iter().map(Option::unwrap).collect(),
        },
        pivots,
        candidate_counts: counts,
        max_gram,
    }
}

/// Change the vtree of an ATDD: recover the canonical ATDD of the same function
/// w.r.t. `to`. The truth-table route — evaluates `from`'s function to a `2^n`
/// table (exponential; validation/demo scale) and runs [`theorem10_canonical`].
pub fn vtree_change(a: &Atdd, from: &Vtree, to: &Vtree) -> Change {
    let f = super::func(a, from);
    theorem10_canonical(&f, to)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::atdd::func;
    use crate::atdd::oracle::{brute_ranks, reference_canonical, to_q};
    use crate::atdd::rotate::canonical_and_pivots;
    use crate::instances::{random_kcnf, tt_hwb, tt_mux, tt_parity};
    use crate::rng::Rng;
    use crate::truthtable::cnf_truth_table;

    /// Assert the Theorem 10 output equals from-scratch `reference_canonical`
    /// (data + pivots), computes `f`, has dims == ρ_t, and — the point of the
    /// theorem — that candidate containment holds and some node examined more
    /// candidates than it kept (nontrivial restriction). Returns #gap nodes.
    fn assert_change(ch: &Change, f: &[Q], vt: &Vtree) -> usize {
        let refs = reference_canonical(f, vt);
        for (t, (ref_piv, ref_data)) in refs.iter().enumerate() {
            assert_eq!(ch.atdd.node[t], *ref_data, "data mismatch at node {t}");
            let got: Vec<usize> = ch.pivots[t].iter().map(Pivot::to_local_index).collect();
            assert_eq!(&got, ref_piv, "pivot mismatch at node {t}");
        }
        ch.atdd.check(vt).unwrap();
        assert_eq!(func(&ch.atdd, vt), f, "vtree change preserves f");
        assert_eq!(ch.atdd.dims(), brute_ranks(f, vt), "dims == ρ_t");
        // Containment + the candidate>tests gap.
        let mut gaps = 0;
        for (cand, kept) in &ch.candidate_counts {
            assert!(cand >= kept, "candidates < tests");
            if cand > kept {
                gaps += 1;
            }
        }
        // Gram values are integers in [0, 2^n] for Boolean f (Step 3).
        assert!(ch.max_gram.is_integer(), "Gram value not integer");
        assert!(
            ch.max_gram <= Q::from_integer((1i64 << vt.n_vars()).into()),
            "Gram value exceeds 2^n"
        );
        gaps
    }

    #[test]
    fn theorem10_matches_reference_on_random_cnf() {
        let mut rng = Rng::new(0x7ED1_02604);
        let mut tested = 0;
        let mut attempt = 0;
        let mut total_gaps = 0;
        while tested < 30 && attempt < 500 {
            attempt += 1;
            let n = 3 + rng.below(4); // 3..=6
            let m = 1 + rng.below(2 * n);
            let cnf = random_kcnf(n, m, 3, &mut rng);
            let vt0 = Vtree::right_linear(n);
            if !cnf_truth_table(&cnf, &vt0).iter().any(|&b| b) {
                continue; // UNSAT
            }
            tested += 1;
            for vt in [
                Vtree::right_linear(n),
                Vtree::balanced(n),
                Vtree::random(n, &mut rng),
            ] {
                let f = to_q(&cnf_truth_table(&cnf, &vt));
                let ch = theorem10_canonical(&f, &vt);
                total_gaps += assert_change(&ch, &f, &vt);
            }
        }
        assert!(tested >= 30, "too few SAT instances: {tested}");
        assert!(
            total_gaps > 0,
            "candidate restriction never exceeded the tests"
        );
    }

    #[test]
    fn theorem10_matches_reference_on_structured() {
        let mut rng = Rng::new(0x0051_4710);
        let mut gaps = 0;
        for n in [4usize, 5, 6] {
            for vt in [Vtree::balanced(n), Vtree::random(n, &mut rng)] {
                gaps += assert_change(
                    &theorem10_canonical(&to_q(&tt_parity(n)), &vt),
                    &to_q(&tt_parity(n)),
                    &vt,
                );
                let hwb = to_q(&tt_hwb(n, &vt));
                gaps += assert_change(&theorem10_canonical(&hwb, &vt), &hwb, &vt);
            }
        }
        // MUX_2 changed onto a balanced vtree — the S = 2^ρ − 1 gap witness
        // discovered bottom-up on the target.
        let dst = Vtree::balanced(6);
        let mux_dst = to_q(&tt_mux(2, &dst));
        let ch = theorem10_canonical(&mux_dst, &dst);
        gaps += assert_change(&ch, &mux_dst, &dst);
        assert!(gaps > 0);
    }

    #[test]
    fn vtree_change_from_an_atdd() {
        // Build a canonical ATDD on one vtree, change it to another, and confirm
        // the result is the from-scratch canonical over the target. right_linear
        // and balanced share the leaf order 0..n, so the truth table is valid
        // for both.
        let n = 5;
        let src = Vtree::right_linear(n);
        let dst = Vtree::balanced(n);
        let f = to_q(&tt_hwb(n, &src));
        let (a, _) = canonical_and_pivots(&f, &src);
        assert_eq!(func(&a, &src), f, "canonical input computes f");
        let ch = vtree_change(&a, &src, &dst);
        assert_change(&ch, &f, &dst);
    }
}
