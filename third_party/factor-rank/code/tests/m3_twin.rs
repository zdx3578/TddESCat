//! Twin-backend cross-check: compile the SAME instances on the SAME vtrees
//! with both backends and verify the per-node sandwich
//! `ρ_t ≤ S_t ≤ 2^{ρ_t} − 1` (lem:sandwich) between the ATDD factor rank
//! `ρ_t` (bond dimension after minimize) and the TDD factor width `S_t`
//! (node count after minimize). This is the empirical payload of the whole
//! project (M5); here it doubles as an end-to-end consistency test of the
//! two compilers, including agreeing SAT/UNSAT verdicts and model counts.

use atddc::atdd::oracle::{brute_ranks, subfunction_count_q, to_q};
use atddc::atdd::pipeline::compile_cnf;
use atddc::atdd::{CompiledAtdd, contract};
use atddc::instances::{random_kcnf, tt_mux};
use atddc::rng::Rng;
use atddc::tdd::{Compiled, compile};
use atddc::vtree::Vtree;
use num_traits::ToPrimitive;

#[test]
fn sandwich_between_backends_on_shared_instances() {
    let mut rng = Rng::new(20260707);
    let mut checked_nodes = 0usize;
    let mut coincidences = 0usize;
    for _ in 0..60 {
        let n = 3 + rng.below(4); // 3..=6
        let m = 2 + rng.below(7);
        let k = 1 + rng.below(n.min(3));
        let cnf = random_kcnf(n, m, k, &mut rng);
        for vt in [
            Vtree::right_linear(n),
            Vtree::balanced(n),
            Vtree::random(n, &mut rng),
        ] {
            let tdd = compile(&cnf, &vt);
            let (atdd, _, _) = compile_cnf(&cnf, &vt);
            match (tdd, atdd) {
                (Compiled::Unsat, CompiledAtdd::Unsat) => {}
                (Compiled::Tdd(t), CompiledAtdd::Atdd(a)) => {
                    // Model counts agree (u128 vs exact rational).
                    let mc_t = t.model_count(&vt);
                    let mc_a = contract::model_count(&a, &vt);
                    assert!(mc_a.is_integer(), "ATDD model count not integral");
                    assert_eq!(
                        mc_a.to_integer().to_u128().expect("fits in u128"),
                        mc_t,
                        "model count mismatch, n={n} m={m}"
                    );
                    // Per-node sandwich on the SAME vtree.
                    let widths = t.widths(); // S_t
                    let dims = a.dims(); // rho_t
                    for id in vt.postorder() {
                        let (s, rho) = (widths[id], dims[id]);
                        if rho == 0 {
                            assert_eq!(s, 0, "node {id}");
                        } else {
                            assert!(rho <= s, "rho={rho} > S={s} at node {id}, n={n}");
                            // Upper half of the sandwich: S ≤ 2^rho − 1.
                            assert!(
                                s < (1usize << rho),
                                "S={s} > 2^rho-1 at node {id} (rho={rho}), n={n}"
                            );
                        }
                        if s == rho {
                            coincidences += 1;
                        }
                        checked_nodes += 1;
                    }
                }
                (t, a) => panic!(
                    "verdict mismatch: TDD {:?} vs ATDD {:?} (n={n} m={m} k={k})",
                    matches!(t, Compiled::Unsat),
                    matches!(a, CompiledAtdd::Unsat)
                ),
            }
        }
    }
    assert!(
        checked_nodes > 500,
        "too few nodes checked: {checked_nodes}"
    );
    // Counting-node coincidences (rho == S) must occur but not everywhere.
    assert!(coincidences > 0);
    assert!(
        coincidences < checked_nodes,
        "S_t == rho_t everywhere is suspicious"
    );
}

#[test]
fn mux_data_cut_realizes_the_exponential_gap() {
    // MUX_k on a vtree whose right spine contains the data block: at the
    // node t with X_t = {data vars}, the sandwich is TIGHT at the top —
    // rho_t = 2^k while S_t = 2^{rho_t} - 1 (all nonzero subfunctions
    // distinct). This is the width-vs-rank separation the benchmarks target.
    for k in [2usize] {
        let n = k + (1 << k); // 6 for k=2
        let vt = Vtree::right_linear(n); // suffix subtree = data block
        let f = to_q(&tt_mux(k, &vt));
        let ranks = brute_ranks(&f, &vt);
        assert!(ranks.iter().all(|&r| r <= 1 << k), "rho bound 2^k");
        // Find the node whose vars are exactly the data block {k..n}.
        let mut found = false;
        for t in vt.postorder() {
            let node = vt.node(t);
            if node.vars == (k..n).collect::<Vec<_>>() {
                let rho = ranks[t];
                let s = subfunction_count_q(&f, &vt, t);
                assert_eq!(rho, 1 << k, "data-cut rank");
                assert_eq!(s, (1 << rho) - 1, "S = 2^rho - 1 (tight)");
                found = true;
            }
        }
        assert!(found, "data node present in the right-linear vtree");
    }
}
