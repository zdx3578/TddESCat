//! `profile_atdd` — ATDD compile profiler for the performance effort.
//!
//! Compiles MUX_k via the CNF apply loop on the `mux_data` vtree (the slow
//! path from the scaling experiment) and reports the phase breakdown from the
//! pipeline's per-step timing: Hadamard conjoin vs two-phase minimize vs
//! lex-RREF canonicalize, plus per-step widths so we can see where the width
//! (hence the arithmetic) blows up.
//!
//! Usage: profile_atdd [k]        (default k = 4)
//!        profile_atdd [k] loop   (compile forever — attach `/usr/bin/sample`)

use atddc::atdd::pipeline::{StepStats, compile_cnf};
use atddc::atdd::{Atdd, CompiledAtdd, NodeData};
use atddc::instances::mux_cnf;
use atddc::vtree::Vtree;
use std::time::{Duration, Instant};

fn dur_ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1e3
}

/// A stable 64-bit FNV-1a fingerprint of the canonical tensor data, folding
/// every entry's (numer, denom) in postorder / row-major. Byte-identical
/// canonical forms ⇒ identical fingerprint — a MUX-scale correctness guard the
/// brute-force tests (n ≤ 6) cannot reach.
fn fingerprint(a: &Atdd, vt: &Vtree) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    let mut mix = |x: &[u8]| {
        for &b in x {
            h ^= u64::from(b);
            h = h.wrapping_mul(0x100000001b3);
        }
    };
    for t in vt.postorder() {
        let feed = |m: &atddc::atdd::linalg::Mat, mix: &mut dyn FnMut(&[u8])| {
            for e in m.entries() {
                mix(e.numer().to_string().as_bytes());
                mix(b"/");
                mix(e.denom().to_string().as_bytes());
                mix(b";");
            }
        };
        match &a.node[t] {
            NodeData::Leaf(m) => feed(m, &mut mix),
            NodeData::Internal(w) => {
                for wi in w {
                    feed(wi, &mut mix);
                    mix(b"|");
                }
            }
        }
        mix(b"#");
    }
    h
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let k: usize = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(4);
    let mode = args.get(2).map(String::as_str).unwrap_or("");
    let loop_mode = mode == "loop";
    let n = k + (1 << k);
    let (cnf, vt) = (mux_cnf(k), Vtree::mux_data(k));

    // Fingerprint mode: compile once, print count/size/width/hash, exit. Used
    // to prove the optimization keeps the MUX canonical form byte-identical.
    if mode == "fp" || mode == "fingerprint" {
        let t0 = Instant::now();
        let (compiled, _c, _s) = compile_cnf(&cnf, &vt);
        let CompiledAtdd::Atdd(a) = compiled else {
            panic!("MUX is satisfiable");
        };
        let mc = atddc::atdd::contract::model_count(&a, &vt);
        println!(
            "MUX k={k} n={n}: count={mc} size={} width={} fp={:016x} ({:.1}ms)",
            a.size(),
            a.width(),
            fingerprint(&a, &vt),
            dur_ms(t0.elapsed()),
        );
        return;
    }
    eprintln!(
        "MUX k={k} (n={n}, {} clauses) on mux_data vtree{}",
        cnf.clauses.len(),
        if loop_mode { " [loop mode]" } else { "" }
    );

    loop {
        let t0 = Instant::now();
        let (compiled, _canon, steps) = compile_cnf(&cnf, &vt);
        let total = t0.elapsed();
        let CompiledAtdd::Atdd(a) = compiled else {
            panic!("MUX is satisfiable");
        };

        let sum =
            |f: fn(&StepStats) -> Duration| -> Duration { steps.iter().map(f).sum::<Duration>() };
        let th: Duration = sum(|s| s.t_hadamard);
        let tm: Duration = sum(|s| s.t_minimize);
        let tc: Duration = sum(|s| s.t_canonicalize);
        let accounted = th + tm + tc;

        if !loop_mode {
            println!(
                "\n=== MUX k={k} (n={n}) — final width {} size {} ===",
                a.width(),
                a.size()
            );
            println!("total compile:        {:>12.3} ms", dur_ms(total));
            println!(
                "  Σ hadamard:         {:>12.3} ms  ({:>5.1}%)",
                dur_ms(th),
                100.0 * th.as_secs_f64() / total.as_secs_f64()
            );
            println!(
                "  Σ minimize:         {:>12.3} ms  ({:>5.1}%)",
                dur_ms(tm),
                100.0 * tm.as_secs_f64() / total.as_secs_f64()
            );
            println!(
                "  Σ canonicalize:     {:>12.3} ms  ({:>5.1}%)",
                dur_ms(tc),
                100.0 * tc.as_secs_f64() / total.as_secs_f64()
            );
            println!(
                "  unaccounted (seed): {:>12.3} ms  ({:>5.1}%)",
                dur_ms(total - accounted),
                100.0 * (total - accounted).as_secs_f64() / total.as_secs_f64()
            );

            println!("\nper-step (step: w_hadamard -> w_min | t_had  t_min  t_canon  ms):");
            for s in &steps {
                println!(
                    "  {:>3}: {:>6} -> {:>4} | {:>10.3} {:>10.3} {:>10.3}",
                    s.step,
                    s.width_after_hadamard,
                    s.width_min,
                    dur_ms(s.t_hadamard),
                    dur_ms(s.t_minimize),
                    dur_ms(s.t_canonicalize),
                );
            }
            // Which single step dominated each phase.
            if let Some(s) = steps.iter().max_by_key(|s| s.t_minimize) {
                println!(
                    "\ndominant minimize step: {} ({:.1} ms, w {}->{})",
                    s.step,
                    dur_ms(s.t_minimize),
                    s.width_after_hadamard,
                    s.width_min
                );
            }
            if let Some(s) = steps.iter().max_by_key(|s| s.t_canonicalize) {
                println!(
                    "dominant canonicalize step: {} ({:.1} ms, w_min {})",
                    s.step,
                    dur_ms(s.t_canonicalize),
                    s.width_min
                );
            }
            break;
        }
    }
}
