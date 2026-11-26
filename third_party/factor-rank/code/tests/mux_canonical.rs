//! MUX-scale canonical-form regression guard for the ATDD compile.
//!
//! The in-crate pipeline tests brute-force only n ≤ 6. MUX_3 (n = 11) is still
//! brute-forceable (2^11 truth table) yet exercises the full exponential-gap
//! data cut (`S = 2^(2^k)−1` vs `ρ = 2^k`) that carries the separation story.
//! This test pins the CNF-compiled canonical ATDD to the brute-force reference
//! canonical form node-by-node — a correctness anchor for the performance work
//! (any change to the compile arithmetic must keep this byte-identical).

use atddc::atdd::CompiledAtdd;
use atddc::atdd::canonical::Pivot;
use atddc::atdd::func;
use atddc::atdd::oracle::{reference_canonical, to_q};
use atddc::atdd::pipeline::compile_cnf;
use atddc::instances::{mux_cnf, tt_mux};
use atddc::vtree::Vtree;

#[test]
fn mux3_cnf_compile_matches_reference_canonical() {
    let k = 3;
    let vt = Vtree::mux_data(k);
    assert_eq!(vt.n_vars(), k + (1 << k), "MUX_3 has n = 11 vars");
    let cnf = mux_cnf(k);

    let (compiled, canon, _steps) = compile_cnf(&cnf, &vt);
    let CompiledAtdd::Atdd(a) = compiled else {
        panic!("MUX is satisfiable");
    };
    let canon = canon.expect("SAT ⇒ canonical form exists");

    // Function correctness at n = 11 (2048-entry truth table).
    let f = to_q(&tt_mux(k, &vt));
    assert_eq!(func(&a, &vt), f, "MUX_3 function");

    // Model count = 2^(n-1).
    let mc: atddc::atdd::linalg::Q = f.iter().sum();
    assert_eq!(atddc::atdd::contract::model_count(&a, &vt), mc);

    // Canonical form == brute-force reference (pivots AND every tensor entry).
    let reference = reference_canonical(&f, &vt);
    for t in vt.postorder() {
        let (ref_piv, ref_data) = &reference[t];
        let got_piv: Vec<usize> = canon.pivots[t].iter().map(Pivot::to_local_index).collect();
        assert_eq!(&got_piv, ref_piv, "pivots at node {t}");
        assert_eq!(&canon.data[t], ref_data, "canonical tensor at node {t}");
    }

    // The headline gap: at the data node ρ = 2^k while S = 2^(2^k)−1.
    assert_eq!(a.width(), 1 << k, "MUX_3 factor width ρ = 2^k = 8");
}
