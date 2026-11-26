//! Instance generators: seeded random CNFs and crafted benchmark families.
//!
//! The crafted families (`HWB`, `MUX`, `PARITY`, single clause) are produced as
//! truth tables (matching `reference/atdd_toy.py`) since they are Boolean
//! functions, not naturally CNFs; both backends can build a diagram from a
//! truth table. Random `k`-CNFs are produced as `Cnf` for the bottom-up
//! compile loop.

use crate::assign::index_to_assignment_into;
use crate::cnf::{Clause, Cnf, Lit};
use crate::rng::Rng;
use crate::vtree::Vtree;

/// A random `k`-CNF: `m` clauses, each with `k` distinct variables and uniform
/// random polarities. Requires `k <= n_vars`.
pub fn random_kcnf(n_vars: usize, m_clauses: usize, k: usize, rng: &mut Rng) -> Cnf {
    assert!(
        k <= n_vars,
        "clause width {k} exceeds variable count {n_vars}"
    );
    let mut cnf = Cnf::new(n_vars);
    for _ in 0..m_clauses {
        let vars = rng.sample_distinct(n_vars, k);
        let lits = vars
            .into_iter()
            .map(|v| Lit::new(v, rng.next_bool()))
            .collect();
        cnf.add_clause(Clause::new(lits));
    }
    cnf
}

/// A random CNF with clause widths drawn uniformly from `1..=max_k`.
pub fn random_cnf_mixed(n_vars: usize, m_clauses: usize, max_k: usize, rng: &mut Rng) -> Cnf {
    let max_k = max_k.min(n_vars);
    let mut cnf = Cnf::new(n_vars);
    for _ in 0..m_clauses {
        let k = 1 + rng.below(max_k);
        let vars = rng.sample_distinct(n_vars, k);
        let lits = vars
            .into_iter()
            .map(|v| Lit::new(v, rng.next_bool()))
            .collect();
        cnf.add_clause(Clause::new(lits));
    }
    cnf
}

/// PARITY over `n` variables: `1` iff an odd number of variables are set.
/// (Independent of the vtree, since it depends only on the popcount.)
pub fn tt_parity(n: usize) -> Vec<bool> {
    (0..(1usize << n))
        .map(|i| i.count_ones() & 1 == 1)
        .collect()
}

/// Hidden-Weighted-Bit over `n` variables (var ids `0..n` as `x_1..x_n`):
/// `HWB(τ) = τ(x_w)` where `w = weight(τ)`, and `0` when `w = 0`.
/// Matches `atdd_toy.tt_hwb`.
pub fn tt_hwb(n: usize, vtree: &Vtree) -> Vec<bool> {
    let mut a = vec![false; vtree.var_space()];
    let mut out = Vec::with_capacity(1usize << n);
    for idx in 0..(1usize << n) {
        index_to_assignment_into(idx, vtree, &mut a);
        let w: usize = a.iter().filter(|&&b| b).count();
        out.push(if w >= 1 { a[w - 1] } else { false });
    }
    out
}

/// Multiplexer `MUX_k`: `k` address variables (`0..k`) select one of the
/// `2^k` data variables (`k..k+2^k`). Matches `atdd_toy.tt_mux`.
pub fn tt_mux(k: usize, vtree: &Vtree) -> Vec<bool> {
    let n = k + (1 << k);
    assert_eq!(vtree.n_vars(), n, "MUX_{k} needs {n} variables");
    let mut a = vec![false; vtree.var_space()];
    let mut out = Vec::with_capacity(1usize << n);
    for idx in 0..(1usize << n) {
        index_to_assignment_into(idx, vtree, &mut a);
        let addr: usize = (0..k).map(|j| usize::from(a[j]) << j).sum();
        out.push(a[k + addr]);
    }
    out
}

/// Truth table of a single clause given as `(var, positive)` literals.
pub fn tt_clause(lits: &[(usize, bool)], vtree: &Vtree) -> Vec<bool> {
    let clause = Clause::new(lits.iter().map(|&(v, p)| Lit::new(v, p)).collect());
    crate::truthtable::clause_truth_table(&clause, vtree)
}

/// THRESHOLD (majority-style): `1` iff at least `k` variables are set.
/// Weight-symmetric, hence independent of the vtree (like PARITY).
/// `FABLE_NOTES/04`: counting family at nontrivial (linear) width.
pub fn tt_threshold(n: usize, k: usize) -> Vec<bool> {
    (0..(1usize << n))
        .map(|i| (i.count_ones() as usize) >= k)
        .collect()
}

/// A random nonzero 0/1 truth table with density `num/den` (toy `tt_random`).
pub fn tt_random(n: usize, num: u64, den: u64, rng: &mut Rng) -> Vec<bool> {
    loop {
        let f: Vec<bool> = (0..(1usize << n)).map(|_| rng.chance(num, den)).collect();
        if f.iter().any(|&b| b) {
            return f;
        }
    }
}

/// Pigeonhole principle PHP(m, n): `m` pigeons into `n` holes. Variable
/// `p_{i,j}` ("pigeon i sits in hole j") has id `i·n + j`. Clauses in fixed
/// order: per-pigeon at-least-one-hole (i ascending), then per-hole
/// at-most-one-pigeon pairs (j ascending, pigeon pairs lex). Satisfiable iff
/// `m ≤ n`; PHP(n, n) has exactly `n!` models (each pigeon takes exactly one
/// hole, holes distinct).
pub fn php(m: usize, n: usize) -> Cnf {
    let mut cnf = Cnf::new(m * n);
    let p = |i: usize, j: usize| i * n + j;
    for i in 0..m {
        cnf.add_clause(Clause::new(
            (0..n).map(|j| Lit::positive(p(i, j))).collect(),
        ));
    }
    for j in 0..n {
        for i1 in 0..m {
            for i2 in (i1 + 1)..m {
                cnf.add_clause(Clause::new(vec![
                    Lit::negative(p(i1, j)),
                    Lit::negative(p(i2, j)),
                ]));
            }
        }
    }
    cnf
}

/// MUX_k as a CNF (`FABLE_NOTES/04` §1): one clause per address value `a`,
/// `(¬pattern(a) ∨ y_a)` — satisfied iff `addr ≠ a` or the selected data bit
/// is 1. The conjunction over all `a` is exactly `MUX_k` (address bit `j` of
/// `a` is its j-th LSB, matching `tt_mux`). `2^k` clauses of width `k + 1`.
pub fn mux_cnf(k: usize) -> Cnf {
    let n = k + (1 << k);
    let mut cnf = Cnf::new(n);
    for a in 0..(1usize << k) {
        let mut lits: Vec<Lit> = (0..k)
            .map(|j| Lit::new(j, (a >> j) & 1 == 0)) // positive iff bit j of a is 0
            .collect();
        lits.push(Lit::positive(k + a));
        cnf.add_clause(Clause::new(lits));
    }
    cnf
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::assign::index_to_assignment;

    #[test]
    fn random_kcnf_wellformed() {
        let mut rng = Rng::new(101);
        let cnf = random_kcnf(8, 20, 3, &mut rng);
        assert_eq!(cnf.n_vars, 8);
        assert_eq!(cnf.clauses.len(), 20);
        for c in &cnf.clauses {
            assert_eq!(c.len(), 3);
            let mut vs: Vec<usize> = c.vars().collect();
            vs.sort_unstable();
            vs.dedup();
            assert_eq!(vs.len(), 3, "clause vars must be distinct");
            assert!(vs.iter().all(|&v| v < 8));
        }
    }

    #[test]
    fn parity_table() {
        // n=2: idx 00->false, 01->true, 10->true, 11->false
        assert_eq!(tt_parity(2), vec![false, true, true, false]);
    }

    #[test]
    fn mux_selects_data_bit() {
        // MUX_1: 1 address var (id 0), 2 data vars (ids 1,2). n=3.
        let k = 1;
        let t = Vtree::right_linear(k + (1 << k));
        let tt = tt_mux(k, &t);
        // Check a few assignments directly.
        for (idx, &tv) in tt.iter().enumerate() {
            let a = index_to_assignment(idx, &t);
            let addr = a[0] as usize; // 1 address bit
            let expected = a[1 + addr];
            assert_eq!(tv, expected, "idx {idx}");
        }
    }

    #[test]
    fn mux_cnf_matches_tt_mux() {
        // The CNF identity (FABLE_NOTES/04): conjunction of the 2^k address
        // clauses IS the multiplexer function. Oracle-box check for k ≤ 3.
        for k in [1usize, 2, 3] {
            let n = k + (1 << k);
            let cnf = mux_cnf(k);
            assert_eq!(cnf.clauses.len(), 1 << k);
            for vt in [Vtree::right_linear(n), Vtree::mux_data(k)] {
                assert_eq!(
                    crate::truthtable::cnf_truth_table(&cnf, &vt),
                    tt_mux(k, &vt),
                    "k={k}"
                );
            }
        }
    }

    #[test]
    fn php_model_counts() {
        // PHP(n, n) has n! models; PHP(m, n) with m > n is unsatisfiable.
        for (m, n, expect) in [
            (2, 2, Some(2u128)),
            (3, 3, Some(6)),
            (3, 2, None),
            (4, 3, None),
        ] {
            let cnf = php(m, n);
            let vt = Vtree::balanced(m * n);
            let f = crate::truthtable::cnf_truth_table(&cnf, &vt);
            let models = f.iter().filter(|&&b| b).count() as u128;
            match expect {
                Some(e) => assert_eq!(models, e, "PHP({m},{n})"),
                None => assert_eq!(models, 0, "PHP({m},{n}) unsat"),
            }
        }
    }

    #[test]
    fn threshold_is_counting_everywhere() {
        // FABLE_NOTES/04 §1: THRESHOLD is predicted counting (S_t == rho_t)
        // at every node — asserted here at small n on several vtrees.
        use crate::atdd::oracle::{brute_rank, to_q};
        use crate::truthtable::factor_width;
        let mut rng = Rng::new(4);
        for n in [4usize, 6] {
            let f = tt_threshold(n, n.div_ceil(2));
            let qf = to_q(&f);
            for vt in [
                Vtree::right_linear(n),
                Vtree::balanced(n),
                Vtree::random(n, &mut rng),
            ] {
                for t in vt.postorder() {
                    assert_eq!(
                        factor_width(&f, &vt, t),
                        brute_rank(&qf, &vt, t),
                        "S_t == rho_t at node {t}, n={n}"
                    );
                }
            }
        }
    }

    #[test]
    fn hwb_small() {
        // n=3. HWB(τ)=τ(x_w), w=weight, 0 if w=0.
        let t = Vtree::right_linear(3);
        let tt = tt_hwb(3, &t);
        for (idx, &tv) in tt.iter().enumerate() {
            let a = index_to_assignment(idx, &t);
            let w = a.iter().filter(|&&b| b).count();
            let expected = if w >= 1 { a[w - 1] } else { false };
            assert_eq!(tv, expected);
        }
    }
}
