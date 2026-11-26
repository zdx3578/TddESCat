//! Golden-fingerprint differential guard for the ATDD compile arithmetic work.
//!
//! The per-node integer-shadow optimization must keep the canonical form
//! byte-identical. MUX has 0/1 canonical entries (denominators = 1), so it does
//! NOT exercise the denominator-clearing / scale-tracking paths. This battery
//! pins the canonical form of FRACTIONAL families (HWB, THRESHOLD — halves and
//! quarters) plus random CNFs and MUX, at sizes (n ≤ 14) beyond the in-crate
//! brute-force tests, to a golden hash captured from the reference ℚ pipeline.
//! Any drift in the exact canonical rationals changes the hash and fails here.
//!
//! Regenerate goldens (only when the canonical form legitimately changes):
//!   GOLDEN_PRINT=1 cargo test --release --test golden_canonical -- --nocapture

use atddc::atdd::canonical::canonicalize;
use atddc::atdd::minimize::minimize;
use atddc::atdd::oracle::{build_from_truthtable, to_q};
use atddc::atdd::pipeline::compile_cnf;
use atddc::atdd::{Atdd, CompiledAtdd, NodeData};
use atddc::instances::{mux_cnf, random_kcnf, tt_hwb, tt_mux, tt_threshold};
use atddc::rng::Rng;
use atddc::vtree::Vtree;

/// Stable FNV-1a fingerprint of the canonical tensor data (postorder, row-major,
/// each entry as `numer/denom`). Byte-identical canonical form ⇒ same hash.
fn fingerprint(a: &Atdd, vt: &Vtree) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    let mut mix = |s: &str| {
        for &b in s.as_bytes() {
            h ^= u64::from(b);
            h = h.wrapping_mul(0x100000001b3);
        }
    };
    for t in vt.postorder() {
        match &a.node[t] {
            NodeData::Leaf(m) => {
                for e in m.entries() {
                    mix(&e.numer().to_string());
                    mix("/");
                    mix(&e.denom().to_string());
                    mix(";");
                }
            }
            NodeData::Internal(w) => {
                for wi in w {
                    for e in wi.entries() {
                        mix(&e.numer().to_string());
                        mix("/");
                        mix(&e.denom().to_string());
                        mix(";");
                    }
                    mix("|");
                }
            }
        }
        mix("#");
    }
    h
}

/// Compile a truth-table family through minimize+canonicalize (the tt route).
fn tt_fp(f_bool: Vec<bool>, vt: &Vtree) -> u64 {
    let mut a = build_from_truthtable(&to_q(&f_bool), vt);
    minimize(&mut a, vt);
    canonicalize(&mut a, vt);
    fingerprint(&a, vt)
}

/// Compile a CNF through the full pipeline (the apply route).
fn cnf_fp(cnf: &atddc::cnf::Cnf, vt: &Vtree) -> u64 {
    match compile_cnf(cnf, vt).0 {
        CompiledAtdd::Atdd(a) => fingerprint(&a, vt),
        CompiledAtdd::Unsat => 0,
    }
}

/// The battery, as `(label, fingerprint)`. Deterministic (fixed seeds / vtrees).
fn battery() -> Vec<(String, u64)> {
    let mut out = Vec::new();
    // HWB — fractional interpolators (halves/quarters). rl_id + balanced.
    for n in [8usize, 10, 12] {
        for (vt, tag) in [(Vtree::right_linear(n), "rl"), (Vtree::balanced(n), "bal")] {
            out.push((format!("hwb{n}_{tag}"), tt_fp(tt_hwb(n, &vt), &vt)));
        }
    }
    // THRESHOLD (majority) — fractional.
    for n in [8usize, 10] {
        let vt = Vtree::balanced(n);
        out.push((
            format!("thr{n}_bal"),
            tt_fp(tt_threshold(n, n.div_ceil(2)), &vt),
        ));
    }
    // Random CNFs through the apply pipeline (fractional along the way). Same
    // rng stream regardless of the n-set (drawn low-n first), so trimming the
    // tail does not perturb the retained instances' goldens.
    let mut rng = Rng::new(0x60D1E);
    for n in [8usize, 10] {
        for kk in [2usize, 3] {
            let cnf = random_kcnf(n, n + 2, kk, &mut rng);
            for (vt, tag) in [(Vtree::right_linear(n), "rl"), (Vtree::balanced(n), "bal")] {
                out.push((format!("r{kk}_n{n}_{tag}"), cnf_fp(&cnf, &vt)));
            }
        }
    }
    // MUX (integer, den=1 — the scale-trivial control) via CNF + tt.
    for k in [2usize, 3] {
        let vd = Vtree::mux_data(k);
        out.push((format!("mux{k}_cnf"), cnf_fp(&mux_cnf(k), &vd)));
        out.push((format!("mux{k}_tt"), tt_fp(tt_mux(k, &vd), &vd)));
    }
    out
}

/// Goldens captured from the reference ℚ pipeline (2026-07-11, pre-optimization).
/// Format: (label, hash). `0` for an unexpectedly-UNSAT random instance.
const GOLDEN: &[(&str, u64)] = &[
    ("hwb8_rl", 0x80e9d754ff464fed),
    ("hwb8_bal", 0x21e9c627a44f9a9a),
    ("hwb10_rl", 0xa46a2003829f544f),
    ("hwb10_bal", 0x030d9d28dd7760f0),
    ("hwb12_rl", 0x3d4ed30bba5c4ef3),
    ("hwb12_bal", 0xec207e497f49aa5a),
    ("thr8_bal", 0x38cac4934d840104),
    ("thr10_bal", 0x2e63339aba4bdd1b),
    ("r2_n8_rl", 0x6629f95fdcbd0202),
    ("r2_n8_bal", 0x295308e6d647e2f4),
    ("r3_n8_rl", 0xa784648b7a51a697),
    ("r3_n8_bal", 0x1e5c6e8607cb302c),
    ("r2_n10_rl", 0x8e7a68e117331163),
    ("r2_n10_bal", 0xf41c53daf52a839f),
    ("r3_n10_rl", 0x1c689f7b02123ed3),
    ("r3_n10_bal", 0x6ad120127b6f5863),
    ("mux2_cnf", 0x7782ca2ca12cbf78),
    ("mux2_tt", 0x7782ca2ca12cbf78),
    ("mux3_cnf", 0x829c2b326b0d41e6),
    ("mux3_tt", 0x829c2b326b0d41e6),
];

#[test]
fn canonical_form_matches_golden() {
    let got = battery();
    if std::env::var("GOLDEN_PRINT").is_ok() {
        println!("const GOLDEN: &[(&str, u64)] = &[");
        for (label, fp) in &got {
            println!("    (\"{label}\", 0x{fp:016x}),");
        }
        println!("];");
        return; // capture mode: don't assert
    }
    assert_eq!(
        got.len(),
        GOLDEN.len(),
        "battery size changed — regenerate goldens"
    );
    for ((label, fp), (glabel, gfp)) in got.iter().zip(GOLDEN) {
        assert_eq!(label, glabel, "battery order changed");
        assert_eq!(
            fp, gfp,
            "canonical form of {label} changed (fp {fp:016x} != golden {gfp:016x})"
        );
    }
}
