//! The shared compile harness: ONE bottom-up clause-by-clause loop,
//! parametrized over the backend (`ARCHITECTURE.md`; CLAUDE.md "same
//! harness, two backends"). Only the node representation and the
//! conjoin/reduce steps differ — which is precisely what the [`Backend`]
//! trait abstracts:
//!
//! * `TddBackend`: conjoin = product `apply_and`; reduce = partition-
//!   refinement `minimize` (canonical by construction).
//! * `AtddBackend`: conjoin = Hadamard product + exact `⟨f,f⟩ = 0` UNSAT
//!   test; reduce = two-phase `minimize` + lex-RREF `canonicalize`
//!   (cor:pipeline discipline).
//!
//! The generic loop is the benchmark entry point (M5): both backends run on
//! the SAME vtrees with the SAME clause schedule, and the per-step records
//! carry the comparable statistics (widths = `S_t` vs `ρ_t`, sizes, times,
//! and the ATDD-only canonical bit size).

use crate::atdd::{self, Atdd};
use crate::cnf::Cnf;
use crate::tdd::{self, NormalizedClause, Tdd, normalize_clause};
use crate::vtree::Vtree;
use std::time::{Duration, Instant};

/// What one reduce step reports (backend-specific fields are `Option`).
#[derive(Clone, Debug, Default)]
pub struct ReduceInfo {
    /// Max canonical entry bits (ATDD only).
    pub bits: Option<u64>,
    /// Minimization phase counters `(p1, p2)` (ATDD only).
    pub phases: Option<(u64, u64)>,
    /// Time spent in minimize.
    pub t_minimize: Duration,
    /// Time spent in canonicalize (ATDD only).
    pub t_canonicalize: Option<Duration>,
}

/// One conjoin+reduce step of the generic loop.
#[derive(Clone, Debug)]
pub struct StepRecord {
    pub step: usize,
    /// Max width right after the conjoin (before reduce).
    pub width_conjoined: usize,
    /// Max width after reduce (`max_t S_t` resp. `max_t ρ_t`).
    pub width_reduced: usize,
    /// Size after reduce (edge count resp. rational-entry count).
    pub size_reduced: usize,
    pub t_conjoin: Duration,
    pub reduce: ReduceInfo,
}

/// A knowledge-compiler backend pluggable into [`compile`].
pub trait Backend {
    type Diagram;
    const NAME: &'static str;

    /// The canonical constant-1 diagram (empty-CNF result).
    fn constant_true(vt: &Vtree) -> Self::Diagram;
    /// The (raw) diagram of one non-trivial clause.
    fn from_clause(vt: &Vtree, lits: &[(usize, bool)]) -> Self::Diagram;
    /// Conjunction; `None` means the result is identically false.
    fn conjoin(a: &Self::Diagram, b: &Self::Diagram, vt: &Vtree) -> Option<Self::Diagram>;
    /// Normalize to the backend's canonical form, reporting what happened.
    fn reduce(d: Self::Diagram, vt: &Vtree) -> (Self::Diagram, ReduceInfo);
    /// Per-vtree-node width statistic (`S_t` resp. `ρ_t`), by node id.
    fn widths(d: &Self::Diagram) -> Vec<usize>;
    /// Total size (edges resp. rational entries).
    fn size(d: &Self::Diagram) -> usize;
}

/// Compilation outcome of the generic loop.
pub enum Outcome<B: Backend> {
    Unsat,
    Compiled(B::Diagram, Vec<StepRecord>),
}

/// The shared bottom-up compile loop (paper Algorithm 1 / toy T3): seed with
/// the first clause, then conjoin + reduce per clause. Tautologies are
/// skipped; an empty clause or a conjunction that collapses to 0 yields
/// `Unsat`; an empty (or all-tautology) CNF yields the constant-1 diagram.
pub fn compile<B: Backend>(cnf: &Cnf, vt: &Vtree) -> Outcome<B> {
    let mut steps: Vec<StepRecord> = Vec::new();
    let mut acc: Option<B::Diagram> = None;
    for clause in &cnf.clauses {
        let lits = match normalize_clause(clause) {
            NormalizedClause::Empty => return Outcome::Unsat,
            NormalizedClause::Tautology => continue,
            NormalizedClause::Lits(ls) => ls,
        };
        let seed = B::from_clause(vt, &lits);
        acc = Some(match acc.take() {
            None => B::reduce(seed, vt).0,
            Some(prev) => {
                let t0 = Instant::now();
                let Some(conjoined) = B::conjoin(&prev, &seed, vt) else {
                    return Outcome::Unsat;
                };
                let t_conjoin = t0.elapsed();
                let width_conjoined = B::widths(&conjoined).into_iter().max().unwrap_or(0);
                let (reduced, info) = B::reduce(conjoined, vt);
                steps.push(StepRecord {
                    step: steps.len(),
                    width_conjoined,
                    width_reduced: B::widths(&reduced).into_iter().max().unwrap_or(0),
                    size_reduced: B::size(&reduced),
                    t_conjoin,
                    reduce: info,
                });
                reduced
            }
        });
    }
    match acc {
        Some(d) => Outcome::Compiled(d, steps),
        None => Outcome::Compiled(B::reduce(B::constant_true(vt), vt).0, steps),
    }
}

/// The deterministic TDD backend.
pub struct TddBackend;

impl Backend for TddBackend {
    type Diagram = Tdd;
    const NAME: &'static str = "tdd";

    fn constant_true(vt: &Vtree) -> Tdd {
        Tdd::constant_true(vt)
    }

    fn from_clause(vt: &Vtree, lits: &[(usize, bool)]) -> Tdd {
        Tdd::clause(vt, lits)
    }

    fn conjoin(a: &Tdd, b: &Tdd, vt: &Vtree) -> Option<Tdd> {
        tdd::apply_and(a, b, vt)
    }

    fn reduce(d: Tdd, vt: &Vtree) -> (Tdd, ReduceInfo) {
        let t0 = Instant::now();
        let reduced = tdd::minimize(&d, vt);
        (
            reduced,
            ReduceInfo {
                t_minimize: t0.elapsed(),
                ..ReduceInfo::default()
            },
        )
    }

    fn widths(d: &Tdd) -> Vec<usize> {
        d.widths()
    }

    fn size(d: &Tdd) -> usize {
        d.size()
    }
}

/// The exact-rational ATDD backend.
pub struct AtddBackend;

impl Backend for AtddBackend {
    type Diagram = Atdd;
    const NAME: &'static str = "atdd";

    fn constant_true(vt: &Vtree) -> Atdd {
        atdd::combine::constant_one(vt)
    }

    fn from_clause(vt: &Vtree, lits: &[(usize, bool)]) -> Atdd {
        atdd::combine::clause(vt, lits)
    }

    fn conjoin(a: &Atdd, b: &Atdd, vt: &Vtree) -> Option<Atdd> {
        let h = atdd::combine::hadamard(a, b, vt);
        // UNSAT test BEFORE minimize (⟨f,f⟩ = 0 ⇔ f ≡ 0); minimize on f ≡ 0
        // legally drives dimensions to 0 and canonicalize is undefined.
        if h.is_zero_function(vt) {
            None
        } else {
            Some(h)
        }
    }

    fn reduce(mut d: Atdd, vt: &Vtree) -> (Atdd, ReduceInfo) {
        let t0 = Instant::now();
        let stats = atdd::minimize::minimize(&mut d, vt);
        let t_minimize = t0.elapsed();
        let t1 = Instant::now();
        atdd::canonical::canonicalize(&mut d, vt);
        let t_canonicalize = t1.elapsed();
        let bits = atdd::canonical::max_bits_atdd(&d);
        (
            d,
            ReduceInfo {
                bits: Some(bits),
                phases: Some((stats.p1, stats.p2)),
                t_minimize,
                t_canonicalize: Some(t_canonicalize),
            },
        )
    }

    fn widths(d: &Atdd) -> Vec<usize> {
        d.dims()
    }

    fn size(d: &Atdd) -> usize {
        d.size()
    }
}

/// Read a (deterministic) TDD verbatim as a 0/1 ATDD (lem:simulation(i)):
/// leaf labels become `[satisfied_by(0), satisfied_by(1)]` rows, input sets
/// become Iverson transfer tensors (`W_i[u][v] = 1 ⟺ (u,v) ∈ E(g_i)`). The
/// bond functions are the node indicator functions, so the embedded ATDD
/// computes the same Boolean function with `d(t) = |N_t|`; `minimize` on it
/// recovers the native factor rank `ρ_t`. This is the T-cross equivalence
/// bridge (`FABLE_NOTES/04` §2.1): TDD ⟷ ATDD equality checked by the exact
/// `Σ(f−g)² = 0` contraction, no `2^n` anywhere.
pub fn embed_tdd(t: &Tdd, vt: &Vtree) -> Atdd {
    use crate::atdd::NodeData;
    use crate::atdd::linalg::{Mat, Q};
    use crate::tdd::Level;
    use num_traits::{One, Zero};
    let node = (0..vt.num_nodes())
        .map(|id| match &t.levels[id] {
            Level::Leaf(labels) => NodeData::Leaf(Mat::from_fn(labels.len(), 2, |i, b| {
                if labels[i].satisfied_by(b == 1) {
                    Q::one()
                } else {
                    Q::zero()
                }
            })),
            Level::Internal(nodes) => {
                let vn = vt.node(id);
                let (dl, dr) = (
                    t.levels[vn.left.unwrap()].len(),
                    t.levels[vn.right.unwrap()].len(),
                );
                NodeData::Internal(
                    nodes
                        .iter()
                        .map(|e| {
                            let mut w = Mat::zero(dl, dr);
                            for &(u, v) in e.iter() {
                                *w.at_mut(u as usize, v as usize) = Q::one();
                            }
                            w
                        })
                        .collect(),
                )
            }
        })
        .collect();
    Atdd { node }
}

/// Exact cross-backend equivalence: does the TDD compute the same function
/// as the ATDD? Via [`embed_tdd`] + the `Σ(f−g)² = 0` zero test
/// (thm:queries(ii)) — polynomial in the diagram sizes.
pub fn tdd_equals_atdd(t: &Tdd, a: &Atdd, vt: &Vtree) -> bool {
    crate::atdd::contract::equal_funcs(&embed_tdd(t, vt), a, vt)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::instances::random_kcnf;
    use crate::rng::Rng;

    #[test]
    fn generic_loop_reproduces_native_compilers() {
        // The trait harness must produce byte-identical canonical diagrams
        // to the per-backend compile functions on the same inputs.
        let mut rng = Rng::new(20260707);
        let (mut sat, mut unsat) = (0, 0);
        for _ in 0..40 {
            let n = 3 + rng.below(4);
            let m = 2 + rng.below(6);
            let k = 1 + rng.below(n.min(3));
            let cnf = random_kcnf(n, m, k, &mut rng);
            let vt = match rng.below(3) {
                0 => Vtree::right_linear(n),
                1 => Vtree::balanced(n),
                _ => Vtree::random(n, &mut rng),
            };
            // TDD: generic vs native.
            let native_t = crate::tdd::compile(&cnf, &vt);
            match (compile::<TddBackend>(&cnf, &vt), native_t) {
                (Outcome::Unsat, crate::tdd::Compiled::Unsat) => unsat += 1,
                (Outcome::Compiled(d, steps), crate::tdd::Compiled::Tdd(t)) => {
                    assert_eq!(d, t, "TDD generic == native");
                    for s in &steps {
                        assert!(s.width_reduced <= s.width_conjoined);
                    }
                    sat += 1;
                }
                _ => panic!("TDD generic/native verdict mismatch"),
            }
            // ATDD: generic vs native pipeline.
            let (native_a, _, _) = crate::atdd::pipeline::compile_cnf(&cnf, &vt);
            match (compile::<AtddBackend>(&cnf, &vt), native_a) {
                (Outcome::Unsat, crate::atdd::CompiledAtdd::Unsat) => {}
                (Outcome::Compiled(d, steps), crate::atdd::CompiledAtdd::Atdd(a)) => {
                    assert_eq!(d, a, "ATDD generic == native");
                    for s in &steps {
                        let bits = s.reduce.bits.expect("ATDD reports bits");
                        let bound = crate::atdd::canonical::hadamard_bit_bound(s.width_reduced);
                        assert!(bits <= bound, "bits {bits} > bound {bound}");
                    }
                }
                _ => panic!("ATDD generic/native verdict mismatch"),
            }
        }
        assert!(sat > 10 && unsat > 2, "poor mix: sat={sat} unsat={unsat}");
    }

    #[test]
    fn embedding_bridges_the_backends() {
        // lem:simulation(i): the verbatim embedding computes the same
        // function (checked exactly via Σ(f−g)² = 0 against the native ATDD
        // — the T-cross protocol), and minimize on it recovers ρ_t.
        let mut rng = Rng::new(0x51A);
        let mut checked = 0;
        while checked < 25 {
            let n = 3 + rng.below(4);
            let m = 2 + rng.below(6);
            let k = 1 + rng.below(n.min(3));
            let cnf = random_kcnf(n, m, k, &mut rng);
            let vt = match rng.below(3) {
                0 => Vtree::right_linear(n),
                1 => Vtree::balanced(n),
                _ => Vtree::random(n, &mut rng),
            };
            let (Outcome::Compiled(t, _), Outcome::Compiled(a, _)) = (
                compile::<TddBackend>(&cnf, &vt),
                compile::<AtddBackend>(&cnf, &vt),
            ) else {
                continue;
            };
            // Embedded width == TDD width (verbatim), and exact equality.
            let e = embed_tdd(&t, &vt);
            e.check(&vt).unwrap();
            assert_eq!(e.dims(), t.widths(), "embedding is verbatim");
            assert!(tdd_equals_atdd(&t, &a, &vt), "cross-backend equality");
            // minimize on the embedding recovers the native factor rank.
            let mut em = e;
            crate::atdd::minimize::minimize(&mut em, &vt);
            assert_eq!(em.dims(), a.dims(), "minimize(embed) recovers rho_t");
            // Negative control: flip the ATDD to a different function.
            let other = crate::atdd::ops::negate(&a, &vt);
            assert!(!tdd_equals_atdd(&t, &other, &vt), "detects inequality");
            checked += 1;
        }
    }

    #[test]
    fn counting_coincidence_on_parity() {
        // prop:counting / rem:tddcoincide: on a counting function (S_t = ρ_t
        // everywhere) the canonicalized embedded TDD is byte-identical to
        // the native canonical ATDD.
        use crate::atdd::canonical::{CanonicalForm, canonicalize};
        for vt in [Vtree::balanced(5), Vtree::right_linear(4)] {
            let n = vt.n_vars();
            // Odd parity as CNF: forbid every even-weight assignment.
            let mut cnf = Cnf::new(n);
            for bits in 0..(1u32 << n) {
                if bits.count_ones() % 2 == 0 {
                    let lits = (0..n)
                        .map(|i| crate::cnf::Lit::new(i, (bits >> i) & 1 == 0))
                        .collect();
                    cnf.add_clause(crate::cnf::Clause::new(lits));
                }
            }
            let (Outcome::Compiled(t, _), Outcome::Compiled(a, _)) = (
                compile::<TddBackend>(&cnf, &vt),
                compile::<AtddBackend>(&cnf, &vt),
            ) else {
                panic!("parity is satisfiable");
            };
            assert_eq!(t.widths(), a.dims(), "counting: S_t == rho_t");
            let mut em = embed_tdd(&t, &vt);
            crate::atdd::minimize::minimize(&mut em, &vt);
            let ep = canonicalize(&mut em, &vt);
            let ec = CanonicalForm::snapshot(&em, ep);
            let mut ac = a.clone();
            let ap = canonicalize(&mut ac, &vt);
            let nc = CanonicalForm::snapshot(&ac, ap);
            assert_eq!(ec, nc, "canonical(embed(TDD)) == canonical ATDD");
        }
    }

    #[test]
    fn empty_and_tautology_cnfs() {
        let vt = Vtree::balanced(3);
        // Empty CNF: constant true from both backends via the generic loop.
        let Outcome::Compiled(t, steps) = compile::<TddBackend>(&Cnf::new(3), &vt) else {
            panic!("empty CNF is satisfiable");
        };
        assert!(steps.is_empty());
        assert_eq!(t.model_count(&vt), 8);
        let Outcome::Compiled(a, _) = compile::<AtddBackend>(&Cnf::new(3), &vt) else {
            panic!("empty CNF is satisfiable");
        };
        assert_eq!(
            crate::atdd::contract::model_count(&a, &vt),
            crate::atdd::linalg::q(8)
        );
    }
}
