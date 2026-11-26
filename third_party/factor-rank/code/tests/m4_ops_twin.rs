//! M4 twin cross-check: run the SAME operations on the SAME instances with
//! both backends and verify they agree — model counts of negation,
//! disjunction, and forgetting; entailment verdicts; and the per-node
//! sandwich `ρ_t ≤ S_t` on the operation RESULTS (minimized both sides,
//! same vtrees, incl. the induced vtree after forgetting).

use atddc::atdd::{self, CompiledAtdd, contract, minimize::minimize as amin, ops as aops};
use atddc::instances::random_kcnf;
use atddc::rng::Rng;
use atddc::tdd::{Compiled, compile, minimize as tmin, ops as tops};
use atddc::vtree::Vtree;
use num_traits::ToPrimitive;

fn count_tdd(t: &atddc::tdd::Tdd, vt: &Vtree) -> u128 {
    t.model_count(vt)
}

fn count_atdd(a: &atddc::atdd::Atdd, vt: &Vtree) -> u128 {
    let mc = contract::model_count(a, vt);
    assert!(mc.is_integer(), "Boolean model count must be integral");
    mc.to_integer().to_u128().expect("fits u128")
}

fn sandwich(t: &atddc::tdd::Tdd, a: &atddc::atdd::Atdd, vt: &Vtree) {
    let widths = t.widths();
    let dims = a.dims();
    for id in vt.postorder() {
        let (s, rho) = (widths[id], dims[id]);
        assert!(rho <= s, "rho={rho} > S={s} at node {id}");
        if rho > 0 {
            assert!(s < (1usize << rho), "S={s} > 2^rho-1 (rho={rho})");
        }
    }
}

#[test]
fn operations_agree_across_backends() {
    let mut rng = Rng::new(20260707);
    let mut checked = 0;
    while checked < 20 {
        let n = 3 + rng.below(4); // 3..=6
        let m = 2 + rng.below(6);
        let k = 1 + rng.below(n.min(3));
        let cnf = random_kcnf(n, m, k, &mut rng);
        let vt = match rng.below(3) {
            0 => Vtree::right_linear(n),
            1 => Vtree::balanced(n),
            _ => Vtree::random(n, &mut rng),
        };
        let (Compiled::Tdd(td), (CompiledAtdd::Atdd(ad), _, _)) =
            (compile(&cnf, &vt), atdd::pipeline::compile_cnf(&cnf, &vt))
        else {
            continue; // UNSAT agreement is covered by the M3 twin test
        };

        // Negation: counts complement; sandwich on the results.
        match tops::negate(&td, &vt) {
            None => assert_eq!(count_tdd(&td, &vt), 1 << n, "None ⇒ f ≡ 1"),
            Some(tneg) => {
                let tneg = tmin(&tneg, &vt);
                let mut aneg = aops::negate(&ad, &vt);
                amin(&mut aneg, &vt);
                assert_eq!(
                    count_tdd(&tneg, &vt),
                    (1u128 << n) - count_tdd(&td, &vt),
                    "TDD ¬f count"
                );
                assert_eq!(count_tdd(&tneg, &vt), count_atdd(&aneg, &vt), "¬f counts");
                sandwich(&tneg, &aneg, &vt);
            }
        }

        // Disjunction with a second function on the same vtree.
        let cnf_b = random_kcnf(n, 2 + rng.below(6), k, &mut rng);
        if let (Compiled::Tdd(tb), (CompiledAtdd::Atdd(ab), _, _)) = (
            compile(&cnf_b, &vt),
            atdd::pipeline::compile_cnf(&cnf_b, &vt),
        ) {
            let tor = tmin(&tops::disjoin(&td, &tb, &vt), &vt);
            let mut aor = aops::disjoin(&ad, &ab, &vt);
            amin(&mut aor, &vt);
            assert_eq!(count_tdd(&tor, &vt), count_atdd(&aor, &vt), "f ∨ g counts");
            sandwich(&tor, &aor, &vt);
            // Entailment verdicts agree.
            assert_eq!(
                tops::entails(&td, &tb, &vt),
                aops::entails(&ad, &ab, &vt),
                "f ⊨ g verdicts"
            );
            assert!(tops::entails(&td, &tor, &vt) && aops::entails(&ad, &aor, &vt));
        }

        // Forgetting on the shared induced vtree.
        let x = rng.below(n);
        let (tvt, tex) = tops::forget(&td, &vt, x);
        let tex = tmin(&tex, &tvt);
        let (avt, mut aex) = aops::forget(&ad, &vt, x);
        amin(&mut aex, &avt);
        assert_eq!(tvt.leaf_order(), avt.leaf_order(), "same induced vtree");
        assert_eq!(count_tdd(&tex, &tvt), count_atdd(&aex, &avt), "∃x f counts");
        sandwich(&tex, &aex, &tvt);

        checked += 1;
    }
    assert!(checked >= 20);
}
