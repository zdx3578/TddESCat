//! The bottom-up CNF compile pipeline for the ATDD backend
//! (`FABLE_NOTES/02` §7.2; toy T3, 838–873; cor:pipeline).
//!
//! Discipline: after *every* Hadamard conjunction, run `minimize` then
//! `canonicalize`. Skipping it compounds multiplicatively in both dimensions
//! (`w → w²` per step) and bit sizes; interleaving resets entries to
//! `O(ρ log ρ)` bits and dimensions to `ρ_t` regardless of sequence length.
//! The UNSAT test (`⟨f,f⟩ = 0`) runs *before* minimize — on `f ≡ 0`,
//! minimize legally drives dimensions to 0 and canonicalize is undefined.

use super::canonical::{CanonicalForm, Pivot, canonicalize, hadamard_bit_bound, max_bits_atdd};
use super::combine::{clause, constant_one, hadamard};
use super::contract::equal_funcs;
use super::minimize::minimize;
use super::{Atdd, CompiledAtdd};
use crate::cnf::Cnf;
use crate::tdd::{NormalizedClause, normalize_clause};
use crate::vtree::Vtree;
use std::time::{Duration, Instant};

/// Per-conjunction-step statistics (spec §7.3).
#[derive(Clone, Debug)]
pub struct StepStats {
    pub step: usize,
    /// Width right after the Hadamard product (before minimize).
    pub width_after_hadamard: usize,
    /// Width after minimize (= factor rank `max_t ρ_t` of the accumulator).
    pub width_min: usize,
    /// Max canonical entry bits after canonicalize.
    pub bits_canon: u64,
    /// The `hadamard_bit_bound(width_min)` reference value.
    pub bits_bound: u64,
    pub p1: u64,
    pub p2: u64,
    pub t_hadamard: Duration,
    pub t_minimize: Duration,
    pub t_canonicalize: Duration,
}

/// Compile a CNF into a canonical ATDD respecting `vt` by clause-by-clause
/// Hadamard conjunction with minimize+canonicalize after every step. Returns
/// `Unsat` for unsatisfiable input (for which no canonical ATDD exists). The
/// returned diagram is in canonical form; the accompanying `CanonicalForm`
/// is its certificate (tests + data snapshot).
pub fn compile_cnf(cnf: &Cnf, vt: &Vtree) -> (CompiledAtdd, Option<CanonicalForm>, Vec<StepStats>) {
    let mut steps = Vec::new();
    let mut acc: Option<Atdd> = None;
    // Pivots of the LATEST canonicalize only — the full certificate (with its
    // deep data clone) is assembled once at the end, not per clause (panel
    // finding: the per-step snapshot was a discarded whole-diagram clone).
    let mut pivots: Option<Vec<Vec<Pivot>>> = None;
    for cl in &cnf.clauses {
        let ls = match normalize_clause(cl) {
            NormalizedClause::Empty => return (CompiledAtdd::Unsat, None, steps),
            NormalizedClause::Tautology => continue,
            NormalizedClause::Lits(ls) => ls,
        };
        let seed = clause(vt, &ls);
        match acc.take() {
            None => {
                // First clause: seed is already ≤ width 2; normalize it.
                let mut a = seed;
                minimize(&mut a, vt);
                pivots = Some(canonicalize(&mut a, vt));
                acc = Some(a);
            }
            Some(prev) => {
                let t0 = Instant::now();
                let mut h = hadamard(&prev, &seed, vt);
                let t_hadamard = t0.elapsed();
                if h.is_zero_function(vt) {
                    return (CompiledAtdd::Unsat, None, steps);
                }
                let width_after_hadamard = h.width();
                let t1 = Instant::now();
                let mstats = minimize(&mut h, vt);
                let t_minimize = t1.elapsed();
                let width_min = h.width();
                let t2 = Instant::now();
                pivots = Some(canonicalize(&mut h, vt));
                let t_canonicalize = t2.elapsed();
                let bits_canon = max_bits_atdd(&h);
                steps.push(StepStats {
                    step: steps.len(),
                    width_after_hadamard,
                    width_min,
                    bits_canon,
                    bits_bound: hadamard_bit_bound(width_min),
                    p1: mstats.p1,
                    p2: mstats.p2,
                    t_hadamard,
                    t_minimize,
                    t_canonicalize,
                });
                acc = Some(h);
            }
        }
    }
    let (a, pivots) = match (acc, pivots) {
        (Some(a), Some(p)) => (a, p),
        _ => {
            // Empty CNF (or all tautologies): the constant-1 function.
            let mut a = constant_one(vt);
            minimize(&mut a, vt);
            let p = canonicalize(&mut a, vt);
            (a, p)
        }
    };
    let canon = CanonicalForm::snapshot(&a, pivots);
    (CompiledAtdd::Atdd(a), Some(canon), steps)
}

/// Promise check `Σ(f² − f)² == 0` (toy `is_boolean`; thm:promise). Minimizes
/// the square first — without it the cross-inner runs at width `w²` even when
/// `ρ(f²)` is tiny. The `f ≡ 0` guard is an intentional deviation from the
/// toy (flagged in spec §2.4).
pub fn is_boolean(a: &Atdd, vt: &Vtree) -> bool {
    use super::contract::cross_inner;
    use num_traits::Zero;
    if cross_inner(a, a, vt, vt.root()).at(0, 0).is_zero() {
        return true; // f ≡ 0 is Boolean
    }
    let mut p = hadamard(a, a, vt);
    minimize(&mut p, vt);
    equal_funcs(&p, a, vt)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::atdd::contract::model_count;
    use crate::atdd::func;
    use crate::atdd::linalg::{Q, q};
    use crate::atdd::oracle::{brute_ranks, reference_canonical, to_q};
    use crate::instances::random_kcnf;
    use crate::rng::Rng;
    use crate::truthtable::cnf_truth_table;
    use crate::vtree::Vtree;

    #[test]
    fn compile_matches_brute_force_and_rank_oracle() {
        let mut rng = Rng::new(20260707);
        let (mut sat, mut unsat) = (0, 0);
        for _ in 0..120 {
            let n = 3 + rng.below(4); // 3..=6
            let m = 2 + rng.below(7);
            let k = 1 + rng.below(n.min(3));
            let cnf = random_kcnf(n, m, k, &mut rng);
            for vt in [
                Vtree::right_linear(n),
                Vtree::balanced(n),
                Vtree::random(n, &mut rng),
            ] {
                let f = to_q(&cnf_truth_table(&cnf, &vt));
                let is_sat = f.iter().any(|x| !num_traits::Zero::is_zero(x));
                let (compiled, canon, steps) = compile_cnf(&cnf, &vt);
                match compiled {
                    CompiledAtdd::Unsat => {
                        assert!(!is_sat, "UNSAT verdict for a SAT formula, n={n} m={m}");
                        unsat += 1;
                    }
                    CompiledAtdd::Atdd(a) => {
                        assert!(is_sat, "diagram for an UNSAT formula");
                        a.check(&vt).unwrap();
                        // function correctness
                        assert_eq!(func(&a, &vt), f, "n={n} m={m} k={k}");
                        // V1 on the pipeline output: dims == cut ranks (ρ_t)
                        assert_eq!(a.dims(), brute_ranks(&f, &vt), "rank oracle, n={n}");
                        // model count
                        let mc: Q = f.iter().sum();
                        assert_eq!(model_count(&a, &vt), mc);
                        // the certificate matches a fresh canonicalization
                        assert!(canon.is_some());
                        // per-step bit bound (cor:pipeline / lem:bits)
                        for s in &steps {
                            assert!(
                                s.bits_canon <= s.bits_bound,
                                "step {}: bits {} > bound {}",
                                s.step,
                                s.bits_canon,
                                s.bits_bound
                            );
                            assert!(s.width_min <= s.width_after_hadamard);
                        }
                        sat += 1;
                    }
                }
            }
        }
        assert!(sat > 20 && unsat > 5, "poor mix: sat={sat} unsat={unsat}");
    }

    #[test]
    fn pipeline_canonical_equals_reference_canonical() {
        // V3 on pipeline outputs: network canonical form == brute-force
        // reference (pivots AND all tensor entries), node by node.
        let mut rng = Rng::new(0xC0FFEE);
        let mut checked = 0;
        for _ in 0..60 {
            let n = 3 + rng.below(4); // 3..=6
            let m = 2 + rng.below(6);
            let k = 1 + rng.below(n.min(3));
            let cnf = random_kcnf(n, m, k, &mut rng);
            let vt = match rng.below(3) {
                0 => Vtree::right_linear(n),
                1 => Vtree::balanced(n),
                _ => Vtree::random(n, &mut rng),
            };
            let (compiled, canon, _) = compile_cnf(&cnf, &vt);
            let CompiledAtdd::Atdd(_) = compiled else {
                continue;
            };
            let canon = canon.unwrap();
            let f = to_q(&cnf_truth_table(&cnf, &vt));
            let reference = reference_canonical(&f, &vt);
            for t in vt.postorder() {
                let (ref_piv, ref_data) = &reference[t];
                let got_piv: Vec<usize> =
                    canon.pivots[t].iter().map(Pivot::to_local_index).collect();
                assert_eq!(&got_piv, ref_piv, "pivots at node {t}, n={n}");
                assert_eq!(&canon.data[t], ref_data, "tensor at node {t}, n={n}");
            }
            checked += 1;
        }
        assert!(checked > 20, "too few SAT instances: {checked}");
    }

    #[test]
    fn canonical_form_is_clause_order_invariant() {
        let mut rng = Rng::new(2024);
        for _ in 0..25 {
            let n = 3 + rng.below(4);
            let m = 3 + rng.below(5);
            let k = 1 + rng.below(n.min(3));
            let cnf = random_kcnf(n, m, k, &mut rng);
            let vt = Vtree::balanced(n);
            let (c1, canon1, _) = compile_cnf(&cnf, &vt);
            let mut shuffled = cnf.clone();
            rng.shuffle(&mut shuffled.clauses);
            let (c2, canon2, _) = compile_cnf(&shuffled, &vt);
            match (&c1, &c2) {
                (CompiledAtdd::Unsat, CompiledAtdd::Unsat) => {}
                (CompiledAtdd::Atdd(a1), CompiledAtdd::Atdd(a2)) => {
                    assert_eq!(a1, a2, "canonical diagram changed under permutation");
                    assert_eq!(canon1.unwrap(), canon2.unwrap());
                }
                _ => panic!("SAT/UNSAT verdict changed under clause permutation"),
            }
        }
    }

    #[test]
    fn pipeline_output_is_boolean_and_edge_cases() {
        let mut rng = Rng::new(7);
        // is_boolean accepts pipeline outputs, rejects a scaled network.
        let n = 4;
        let vt = Vtree::balanced(n);
        let cnf = random_kcnf(n, 4, 2, &mut rng);
        if let (CompiledAtdd::Atdd(a), _, _) = compile_cnf(&cnf, &vt) {
            assert!(is_boolean(&a, &vt));
            let mut half = a;
            super::super::combine::scale_root(&mut half, &vt, &Q::new(1.into(), 2.into()));
            assert!(!is_boolean(&half, &vt), "f/2 must be rejected");
        }
        // Empty CNF ⇒ constant 1, canonical.
        let (c, canon, steps) = compile_cnf(&crate::cnf::Cnf::new(3), &Vtree::balanced(3));
        let CompiledAtdd::Atdd(a) = c else {
            panic!("empty CNF is satisfiable");
        };
        assert!(steps.is_empty());
        assert!(canon.is_some());
        assert!(func(&a, &Vtree::balanced(3)).iter().all(|x| *x == q(1)));
        // Empty clause ⇒ Unsat.
        let mut cnf = crate::cnf::Cnf::new(2);
        cnf.add_clause(crate::cnf::Clause::new(vec![]));
        assert!(matches!(
            compile_cnf(&cnf, &Vtree::balanced(2)).0,
            CompiledAtdd::Unsat
        ));
        // Contradiction on one variable (n = 1, root is a leaf).
        let vt1 = Vtree::right_linear(1);
        let mut cnf = crate::cnf::Cnf::new(1);
        cnf.add_clause(crate::cnf::Clause::new(vec![crate::cnf::Lit::positive(0)]));
        cnf.add_clause(crate::cnf::Clause::new(vec![crate::cnf::Lit::negative(0)]));
        assert!(matches!(compile_cnf(&cnf, &vt1).0, CompiledAtdd::Unsat));
        // (x0) on n = 1 compiles.
        let mut cnf = crate::cnf::Cnf::new(1);
        cnf.add_clause(crate::cnf::Clause::new(vec![crate::cnf::Lit::positive(0)]));
        let (c, _, _) = compile_cnf(&cnf, &vt1);
        let CompiledAtdd::Atdd(a) = c else {
            panic!("(x0) is satisfiable");
        };
        assert_eq!(func(&a, &vt1), vec![q(0), q(1)]);
    }

    #[test]
    fn t2b_fractional_canonical_entries() {
        // Toy T2b (826–836): the exact-arithmetic stress instance whose
        // canonical form has denominator-2 entries. Hardcoded expected
        // vectors from FABLE_NOTES/02 §Verification-3 (validated against a
        // passing toy run on this machine).
        let vt = Vtree::balanced(4); // ((x0,x1),(x2,x3))
        let cols = [[1, 1, 0, 1], [1, 0, 1, 1], [0, 1, 1, 1], [0, 0, 0, 0]];
        let mut f = vec![q(0); 16];
        for tau in 0..4 {
            for sig in 0..4 {
                f[tau * 4 + sig] = q(cols[sig][tau]);
            }
        }
        let mut a = crate::atdd::oracle::build_from_truthtable(&f, &vt);
        crate::atdd::minimize::minimize(&mut a, &vt);
        let pivots = canonicalize(&mut a, &vt);
        let canon = CanonicalForm::snapshot(&a, pivots);
        assert_eq!(func(&a, &vt), f);
        let mbits = crate::atdd::canonical::max_bits(&canon);
        assert!(
            mbits > 1,
            "fractional entries must occur (max bits {mbits})"
        );
        // Left internal node: pivots 00 < 01 < 10, slice 0 = [[1,0],[0,1/2]],
        // slice 1 = [[0,1],[0,1/2]], slice 2 = [[0,0],[1,1/2]].
        let root = vt.root();
        let left = vt.node(root).left.unwrap();
        let piv: Vec<usize> = canon.pivots[left]
            .iter()
            .map(Pivot::to_local_index)
            .collect();
        assert_eq!(piv, vec![0, 1, 2]);
        let crate::atdd::NodeData::Internal(w) = &canon.data[left] else {
            panic!("left node is internal");
        };
        let half = Q::new(1.into(), 2.into());
        let expect0 =
            crate::atdd::linalg::Mat::from_rows(vec![vec![q(1), q(0)], vec![q(0), half.clone()]]);
        let expect1 =
            crate::atdd::linalg::Mat::from_rows(vec![vec![q(0), q(1)], vec![q(0), half.clone()]]);
        let expect2 = crate::atdd::linalg::Mat::from_rows(vec![vec![q(0), q(0)], vec![q(1), half]]);
        assert_eq!(w[0], expect0);
        assert_eq!(w[1], expect1);
        assert_eq!(w[2], expect2);
        // Reference-canonical agreement on the whole instance.
        let reference = reference_canonical(&f, &vt);
        for t in vt.postorder() {
            assert_eq!(&canon.data[t], &reference[t].1, "node {t}");
        }
    }
}
