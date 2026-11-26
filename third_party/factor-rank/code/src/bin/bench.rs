//! M5 benchmark driver (`FABLE_NOTES/04`): compile BOTH backends per
//! (instance, vtree) pair — the same vtree object, hashed into every row —
//! and emit `runs.csv` / `cuts.csv` / `steps.csv` + `meta.json` under
//! `--out`. Two channels, never mixed: `tt` (reference construction from the
//! truth table) and `cnf` (the shared bottom-up apply loop).
//!
//! Usage:
//!   cargo run --release --bin bench -- --suite smoke --out bench_out
//!   cargo run --release --bin bench -- --suite stretch --only mux_k4 \
//!     --vtrees mux_data --out bench_out_stretch --timeout-s 300
//! Flags: `--suite`, `--out`, `--seed-base`, `--only <name-prefix>`,
//! `--vtrees <csv>` (resume/filter — rows APPEND, so strip an instance's
//! rows before re-running it), `--timeout-s <s>` (per-compile wall-clock
//! cap; 0 = off), `--repeats <n>` (median-of-n timing, fast compiles only).
//! Suites: smoke (tiny, all checks fatal), counting, gap, cnf,
//! full (= counting ∪ gap ∪ cnf, core tiers only), stretch (the expensive
//! tail: MUX k=4, HWB ≥ 12, PHP ≥ (5,5), r3 n = 12 — run one slow treatment
//! per process). CSVs are flushed after every (instance, vtree) pair, so a
//! killed run keeps everything completed so far.
//!
//! M5b closed the v1 deviations: in-process timeout (`--timeout-s`, thread +
//! `recv_timeout`, status `timeout`, worker orphaned on expiry); median-of-n
//! compile timing (`--repeats`, applied only to compiles below
//! `REPEAT_THRESHOLD` so slow runs are timed once); per-node `atdd_bits_max`
//! and `atdd_entries_01` in cuts.csv; and `compile_reps` in runs.csv.
//!
//! Remaining v1 deviations (low value): steps.csv `zero` is always false (an
//! UNSAT step returns early and records no row); no spot-check column
//! (T-oracle covers the grid — every core point has the full 2^n check);
//! random-function family and clause-permutation experiment not yet wired.
//!
//! Schema note: the new columns make this binary's schema a superset of the
//! committed core `bench_out/`; run the new schema into a fresh dir
//! (`bench_out_stretch/`) and concat on shared columns in analysis.

use atddc::atdd::canonical::{
    CanonicalForm, bit_mass_atdd, canonicalize, max_bits_atdd, node_bits, node_entries_01,
    nonzero_entries_atdd,
};
use atddc::atdd::intcount::IntKernel;
use atddc::atdd::linalg::Q;
use atddc::atdd::oracle::{brute_ranks, to_q};
use atddc::atdd::{Atdd, contract, pipeline};
use atddc::backend::{self, AtddBackend, Backend, Outcome, StepRecord, TddBackend};
use atddc::cnf::Cnf;
use atddc::instances::{mux_cnf, php, random_kcnf, tt_hwb, tt_mux, tt_parity, tt_threshold};
use atddc::rng::Rng;
use atddc::tdd::Tdd;
use atddc::truthtable::{cnf_truth_table, factor_widths, tdd_from_truth_table};
use atddc::vtree::{Vtree, min_fill_order};
use std::fmt::Write as _;
use std::fs;
use std::path::Path;
use std::time::{Duration, Instant};

const ORACLE_MAX_N: usize = 14;
const EMBED_EQ_GATE: u128 = 1_000_000_000;
/// Median-of-N compile timing only repeats when the first (measured) compile
/// is below this wall-clock; slow compiles (the stretch tier) are timed once
/// so the extra repeats never multiply an already-expensive run.
const REPEAT_THRESHOLD: Duration = Duration::from_millis(750);

/// Compile-timing controls (shared by both channels).
#[derive(Clone, Copy)]
struct Timing {
    /// Per-compile wall-clock cap; `None` = unbounded.
    timeout: Option<Duration>,
    /// Target repeat count for median timing (applied only to fast compiles).
    repeats: u32,
}

/// Run `f` under an optional wall-clock timeout, returning `None` on timeout.
/// On timeout the worker thread is orphaned — it finishes or dies at process
/// exit. The chunked stretch runs launch one slow treatment per process, so an
/// orphan is reaped promptly and cannot skew a sibling's timing. `f` owns its
/// inputs (`'static`): callers move clones of the cnf / vtree / truth table in.
fn run_timed<T: Send + 'static>(
    timeout: Option<Duration>,
    f: impl FnOnce() -> T + Send + 'static,
) -> Option<T> {
    match timeout {
        None => Some(f()),
        Some(d) => {
            let (tx, rx) = std::sync::mpsc::channel();
            std::thread::spawn(move || {
                let _ = tx.send(f());
            });
            rx.recv_timeout(d).ok()
        }
    }
}

/// Median of the samples, in milliseconds (upper-middle for even counts).
fn median_ms(mut xs: Vec<Duration>) -> f64 {
    xs.sort();
    xs[xs.len() / 2].as_secs_f64() * 1e3
}

/// A run that exceeded the per-compile timeout: `status = "timeout"`, no
/// diagram, `t_compile_ms` records the cap so the row is self-describing.
fn timeout_result(timeout: Option<Duration>) -> RunResult {
    RunResult {
        status: "timeout",
        t_compile_ms: timeout.map(|d| d.as_secs_f64() * 1e3).unwrap_or(0.0),
        t_apply_ms: 0.0,
        t_minimize_ms: 0.0,
        t_canon_ms: 0.0,
        size_final: 0,
        width_final: 0,
        width_peak: 0,
        step_peak: -1,
        model_count: String::new(),
        widths: Vec::new(),
        tdd: None,
        atdd: None,
        steps: Vec::new(),
        compile_reps: 0,
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Channel {
    Tt,
    Cnf,
}

impl Channel {
    fn name(self) -> &'static str {
        match self {
            Channel::Tt => "tt",
            Channel::Cnf => "cnf",
        }
    }
}

/// One benchmark unit: an instance in one channel.
struct Instance {
    family: &'static str,
    name: String,
    channel: Channel,
    n: usize,
    cnf: Option<Cnf>,
    tt: Option<Vec<bool>>,
    /// Closed-form model count, if the family has one.
    mc_closed: Option<u128>,
    /// Family bound on ρ_t (asserted per node), if any.
    rho_bound: Option<usize>,
    alpha: String,
    seed: u64,
}

/// A vtree treatment applied to an instance.
struct Treatment {
    kind: &'static str,
    seed: u64,
    vt: Vtree,
}

fn fnv_vtree_hash(vt: &Vtree) -> String {
    // FNV-1a over preorder structure + leaf order.
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    let mut eat = |x: u64| {
        h ^= x;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    };
    for t in vt.preorder() {
        let node = vt.node(t);
        match node.var {
            Some(v) => {
                eat(1);
                eat(v as u64);
            }
            None => eat(2),
        }
    }
    format!("{h:016x}")
}

fn treatments(inst: &Instance, seed_base: u64) -> Vec<Treatment> {
    let n = inst.n;
    let mut out = vec![
        Treatment {
            kind: "rl_id",
            seed: 0,
            vt: Vtree::right_linear(n),
        },
        Treatment {
            kind: "bal_id",
            seed: 0,
            vt: Vtree::balanced(n),
        },
    ];
    if let Some(cnf) = &inst.cnf {
        let order = min_fill_order(cnf);
        out.push(Treatment {
            kind: "rl_minfill",
            seed: 0,
            vt: Vtree::right_linear_order(&order),
        });
        out.push(Treatment {
            kind: "bal_minfill",
            seed: 0,
            vt: Vtree::balanced_order(&order),
        });
    } else {
        // tt families: random vtrees test vtree-uniformity claims.
        for s in 1..=2u64 {
            let mut rng = Rng::new(seed_base ^ (s << 32) ^ inst.seed);
            out.push(Treatment {
                kind: "rand",
                seed: s,
                vt: Vtree::random(n, &mut rng),
            });
        }
    }
    if inst.family == "mux" {
        let k = (0..).find(|&k| k + (1usize << k) == n).expect("mux n");
        out.push(Treatment {
            kind: "mux_data",
            seed: 0,
            vt: Vtree::mux_data(k),
        });
    }
    out
}

/// Everything one backend produced for one (instance, vtree) run.
struct RunResult {
    status: &'static str,
    t_compile_ms: f64,
    t_apply_ms: f64,
    t_minimize_ms: f64,
    t_canon_ms: f64,
    size_final: usize,
    width_final: usize,
    width_peak: usize,
    step_peak: i64,
    model_count: String,
    widths: Vec<usize>,
    tdd: Option<Tdd>,
    atdd: Option<Atdd>,
    steps: Vec<StepRecord>,
    /// Number of timed compile samples (`t_compile_ms` is their median).
    compile_reps: u32,
}

fn run_backend<B: Backend + 'static>(
    inst: &Instance,
    vt: &Vtree,
    timing: Timing,
    wrap: impl Fn(B::Diagram) -> (Option<Tdd>, Option<Atdd>),
    mc: impl Fn(&B::Diagram) -> String,
) -> RunResult
where
    B::Diagram: Send + 'static,
{
    debug_assert!(inst.channel == Channel::Cnf, "tt channel handled by run_tt");
    let cnf = inst.cnf.clone().unwrap();
    // Clone the `'static` inputs for the timeout worker BEFORE timing, so the
    // clone cost is excluded from t_compile (repeat samples clone nothing).
    let (cnf_t, vt_t) = (cnf.clone(), vt.clone());
    let t0 = Instant::now();
    let first = run_timed(timing.timeout, move || backend::compile::<B>(&cnf_t, &vt_t));
    let t_first = t0.elapsed();
    let outcome = match first {
        Some(o) => o,
        None => return timeout_result(timing.timeout),
    };
    // Median-of-N: repeat only when the first compile was cheap (§P3).
    let mut times = vec![t_first];
    if t_first < REPEAT_THRESHOLD {
        for _ in 1..timing.repeats {
            let t = Instant::now();
            let _ = backend::compile::<B>(&cnf, vt);
            times.push(t.elapsed());
        }
    }
    let compile_reps = times.len() as u32;
    let t_compile = median_ms(times);
    match outcome {
        Outcome::Unsat => RunResult {
            status: "unsat_zero",
            t_compile_ms: t_compile,
            t_apply_ms: 0.0,
            t_minimize_ms: 0.0,
            t_canon_ms: 0.0,
            size_final: 0,
            width_final: 0,
            width_peak: 0,
            step_peak: -1,
            model_count: "0".into(),
            widths: Vec::new(),
            tdd: None,
            atdd: None,
            steps: Vec::new(),
            compile_reps,
        },
        Outcome::Compiled(d, steps) => {
            let widths = B::widths(&d);
            let (width_peak, step_peak) = steps
                .iter()
                .map(|s| (s.width_reduced, s.step as i64 + 1))
                .chain(std::iter::once((
                    widths.iter().copied().max().unwrap_or(0),
                    -1,
                )))
                .max()
                .unwrap_or((0, -1));
            let t_apply: f64 = steps.iter().map(|s| s.t_conjoin.as_secs_f64()).sum::<f64>() * 1e3;
            let t_min: f64 = steps
                .iter()
                .map(|s| s.reduce.t_minimize.as_secs_f64())
                .sum::<f64>()
                * 1e3;
            let t_canon: f64 = steps
                .iter()
                .filter_map(|s| s.reduce.t_canonicalize)
                .map(|d| d.as_secs_f64())
                .sum::<f64>()
                * 1e3;
            let mc_s = mc(&d);
            let size = B::size(&d);
            let wf = widths.iter().copied().max().unwrap_or(0);
            let (tdd, atdd) = wrap(d);
            RunResult {
                status: "ok",
                t_compile_ms: t_compile,
                t_apply_ms: t_apply,
                t_minimize_ms: t_min,
                t_canon_ms: t_canon,
                size_final: size,
                width_final: wf,
                width_peak,
                step_peak,
                model_count: mc_s,
                widths,
                tdd,
                atdd,
                steps,
                compile_reps,
            }
        }
    }
}

/// One tt-channel reference construction (called repeatedly for median timing).
fn tt_build(
    f: &[bool],
    vt: &Vtree,
    is_tdd: bool,
) -> (Option<Tdd>, Option<Atdd>, Vec<usize>, usize, String) {
    if is_tdd {
        let t = tdd_from_truth_table(f, vt).expect("nonzero tt family");
        let mc = t.model_count(vt).to_string();
        let (w, sz) = (t.widths(), t.size());
        (Some(t), None, w, sz, mc)
    } else {
        let qf = to_q(f);
        let mut a = atddc::atdd::oracle::build_from_truthtable(&qf, vt);
        atddc::atdd::minimize::minimize(&mut a, vt);
        canonicalize(&mut a, vt);
        let mc = q_int(&contract::model_count(&a, vt));
        let (w, sz) = (a.dims(), a.size());
        (None, Some(a), w, sz, mc)
    }
}

/// tt-channel: reference constructions from the truth table.
fn run_tt(inst: &Instance, vt: &Vtree, backend: &str, timing: Timing) -> RunResult {
    let f = inst.tt.as_ref().unwrap();
    let is_tdd = backend == "tdd";
    // Clone the `'static` inputs for the timeout worker BEFORE timing (the
    // tt truth table is 2^n bools); repeat samples reuse the borrows.
    let (f_t, vt_t) = (f.clone(), vt.clone());
    let t0 = Instant::now();
    let first = run_timed(timing.timeout, move || tt_build(&f_t, &vt_t, is_tdd));
    let t_first = t0.elapsed();
    let (tdd, atdd, widths, size, mc) = match first {
        Some(r) => r,
        None => return timeout_result(timing.timeout),
    };
    let mut times = vec![t_first];
    if t_first < REPEAT_THRESHOLD {
        for _ in 1..timing.repeats {
            let t = Instant::now();
            let _ = tt_build(f, vt, is_tdd);
            times.push(t.elapsed());
        }
    }
    let compile_reps = times.len() as u32;
    let t_compile = median_ms(times);
    let wf = widths.iter().copied().max().unwrap_or(0);
    RunResult {
        status: "ok",
        t_compile_ms: t_compile,
        t_apply_ms: 0.0,
        t_minimize_ms: 0.0,
        t_canon_ms: 0.0,
        size_final: size,
        width_final: wf,
        width_peak: wf,
        step_peak: -1,
        model_count: mc,
        widths,
        tdd,
        atdd,
        steps: Vec::new(),
        compile_reps,
    }
}

fn q_int(x: &Q) -> String {
    debug_assert!(x.is_integer());
    x.to_integer().to_string()
}

/// Per-call time of `f` in microseconds, floor-robust. Query-time counting on a
/// small diagram runs far below the timer's resolution, so a single call (or a
/// handful) measures only quantization noise — the reviewer's timing-floor
/// concern. We instead repeat `f` until the *accumulated* wall clock reaches
/// `FLOOR` (or `max_reps` calls, whichever comes first) and report
/// `total / calls`. Calls run in geometrically growing batches so the clock is
/// polled `O(log calls)` times rather than once per call — the per-call figure
/// excludes the polling overhead, which would otherwise dominate the fastest
/// kernels. Returns `(microseconds_per_call, calls)`. `black_box` at the call
/// sites keeps the count from being optimized away. Only the repetition count
/// varies with timing; the computed model count itself is unaffected.
/// Benchmark-harness use only.
fn time_mc(mut f: impl FnMut(), max_reps: u32) -> (f64, u32) {
    const FLOOR: Duration = Duration::from_millis(100);
    let t0 = Instant::now();
    let mut calls: u32 = 0;
    let mut batch: u32 = 1;
    loop {
        for _ in 0..batch {
            f();
        }
        calls += batch;
        if calls >= max_reps || t0.elapsed() >= FLOOR {
            break;
        }
        batch = batch.saturating_mul(2).min(max_reps - calls);
    }
    let per_call = t0.elapsed().as_secs_f64() / f64::from(calls);
    (per_call * 1e6, calls)
}

/// Query-time model counting on the compiled artifact, both backends. Returns
/// `(t_mc_us_q, mc_reps, mc_bits, t_mc_us_int, mc_int_fast)`. The ℚ column
/// (`t_mc_us_q`) times the `BigRational` ones-contraction; the integer column
/// (`t_mc_us_int`, ATDD only) times the denominator-cleared integer kernel
/// ([`atddc::atdd::intcount`]) — the C10 follow-up. `mc_int_fast` records
/// whether the `i128` fast path was in force (else the `BigInt` fallback).
/// TDD already counts in register `u128`, so its integer columns stay empty.
fn measure_mc(rr: &RunResult, vt: &Vtree) -> (String, String, String, String, String) {
    // Iteration cap for the timing-floor loop (`time_mc`): with a 100 ms floor
    // this bounds a sub-100 ns query at ~1e6 calls, so the accumulation can
    // reach the floor without runaway. Both the ℚ and integer kernels share it.
    const MAX_REPS: u32 = 1_000_000;
    if let Some(t) = &rr.tdd {
        let (us, reps) = time_mc(
            || {
                std::hint::black_box(t.model_count(vt));
            },
            MAX_REPS,
        );
        let bits = 128 - t.model_count(vt).leading_zeros();
        (
            format!("{us:.3}"),
            reps.to_string(),
            bits.to_string(),
            String::new(),
            String::new(),
        )
    } else if let Some(a) = &rr.atdd {
        let (us, reps) = time_mc(
            || {
                std::hint::black_box(contract::model_count(a, vt));
            },
            MAX_REPS,
        );
        let bits = contract::model_count(a, vt).to_integer().bits();
        // Integer kernel: build once (compile-time step, untimed), then time
        // the contraction only — the fair query-time measure.
        let kernel = IntKernel::build(a, vt);
        let (us_int, _) = time_mc(
            || {
                std::hint::black_box(kernel.count(vt));
            },
            MAX_REPS,
        );
        (
            format!("{us:.3}"),
            reps.to_string(),
            bits.to_string(),
            format!("{us_int:.3}"),
            kernel.is_fast().to_string(),
        )
    } else {
        (
            String::new(),
            String::new(),
            String::new(),
            String::new(),
            String::new(),
        )
    }
}

fn bits_bound_unslacked(rho: usize) -> u64 {
    // lem:bits: ceil((rho/2 + 1) * log2(rho)); 1 for rho <= 1.
    if rho <= 1 {
        1
    } else {
        let r = rho as f64;
        ((r / 2.0 + 1.0) * r.log2()).ceil() as u64
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut suite = "smoke".to_string();
    let mut out_dir = "bench_out".to_string();
    let mut seed_base: u64 = 20260707;
    let mut only: Option<String> = None;
    let mut vtree_filter: Option<Vec<String>> = None;
    let mut timeout: Option<Duration> = None;
    let mut repeats: u32 = 3;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--suite" => {
                suite = args[i + 1].clone();
                i += 2;
            }
            "--out" => {
                out_dir = args[i + 1].clone();
                i += 2;
            }
            "--seed-base" => {
                seed_base = args[i + 1].parse().expect("seed");
                i += 2;
            }
            "--timeout-s" => {
                let s: u64 = args[i + 1].parse().expect("timeout seconds");
                timeout = (s > 0).then(|| Duration::from_secs(s));
                i += 2;
            }
            "--repeats" => {
                repeats = args[i + 1].parse().expect("repeats");
                i += 2;
            }
            "--only" => {
                only = Some(args[i + 1].clone());
                i += 2;
            }
            "--vtrees" => {
                vtree_filter = Some(
                    args[i + 1]
                        .split(',')
                        .map(str::to_string)
                        .collect::<Vec<_>>(),
                );
                i += 2;
            }
            other => {
                eprintln!("unknown argument {other}");
                std::process::exit(2);
            }
        }
    }
    let fatal = suite == "smoke";
    let timing = Timing { timeout, repeats };
    let mut instances = build_suite(&suite, seed_base);
    if let Some(prefix) = &only {
        // Resume helper: run only instances whose name starts with the
        // prefix (rows APPEND to existing CSVs — do not re-run completed
        // instances or they will be duplicated).
        instances.retain(|inst| inst.name.starts_with(prefix.as_str()));
    }
    eprintln!("suite {suite}: {} instances", instances.len());

    fs::create_dir_all(&out_dir).expect("create out dir");
    let bench_id = format!("{:08x}", seed_base ^ instances.len() as u64);
    let timeout_s = timeout.map(|d| d.as_secs()).unwrap_or(0);
    let meta = format!(
        "{{\"bench_id\":\"{bench_id}\",\"suite\":\"{suite}\",\"seed_base\":{seed_base},\"oracle_max_n\":{ORACLE_MAX_N},\"timeout_s\":{timeout_s},\"repeats\":{repeats},\"date\":\"2026-07-07\"}}\n"
    );
    fs::write(Path::new(&out_dir).join("meta.json"), meta).expect("write meta");

    let mut runs = csv_open(&out_dir, "runs.csv", RUNS_HEADER);
    let mut cuts = csv_open(&out_dir, "cuts.csv", CUTS_HEADER);
    let mut steps_csv = csv_open(&out_dir, "steps.csv", STEPS_HEADER);
    let mut failures = 0usize;

    for inst in &instances {
        for tr in treatments(inst, seed_base) {
            if let Some(filter) = &vtree_filter
                && !filter.iter().any(|k| k == tr.kind)
            {
                continue;
            }
            let vt = &tr.vt;
            let vhash = fnv_vtree_hash(vt);
            // --- run both backends on the SAME vtree object.
            let (rt, ra) = match inst.channel {
                Channel::Cnf => (
                    run_backend::<TddBackend>(
                        inst,
                        vt,
                        timing,
                        |d| (Some(d), None),
                        |d| d.model_count(vt).to_string(),
                    ),
                    run_backend::<AtddBackend>(
                        inst,
                        vt,
                        timing,
                        |d| (None, Some(d)),
                        |d| q_int(&contract::model_count(d, vt)),
                    ),
                ),
                Channel::Tt => (
                    run_tt(inst, vt, "tdd", timing),
                    run_tt(inst, vt, "atdd", timing),
                ),
            };

            // --- checks (paired).
            let mut ok = true;
            let timed_out = rt.status == "timeout" || ra.status == "timeout";
            let both_ok = rt.status == "ok" && ra.status == "ok";
            let statuses_match = rt.status == ra.status;
            ok &= statuses_match;
            let mc_cross = rt.model_count == ra.model_count;
            ok &= mc_cross;
            let mc_closed = inst
                .mc_closed
                .map(|e| rt.model_count == e.to_string() && ra.model_count == e.to_string());
            if let Some(c) = mc_closed {
                ok &= c;
            }
            // Oracle tier: full truth-table + width oracles.
            let mut tt_brute = None;
            if inst.n <= ORACLE_MAX_N && both_ok {
                let f: Vec<bool> = match inst.channel {
                    Channel::Tt => inst.tt.clone().unwrap(),
                    Channel::Cnf => cnf_truth_table(inst.cnf.as_ref().unwrap(), vt),
                };
                let sw = factor_widths(&f, vt);
                let rw = brute_ranks(&to_q(&f), vt);
                let t_ok =
                    rt.widths == sw && rt.tdd.as_ref().is_some_and(|t| t.to_truth_table(vt) == f);
                let a_ok = ra.widths == rw
                    && ra
                        .atdd
                        .as_ref()
                        .is_some_and(|a| atddc::atdd::func(a, vt) == to_q(&f));
                tt_brute = Some(t_ok && a_ok);
                ok &= t_ok && a_ok;
            }
            // Cross-backend exact equivalence via the embedding (gated).
            let mut eq_cross = String::new();
            if both_ok {
                let ws = rt.width_final as u128;
                let wr = ra.width_final as u128;
                if ws * ws * wr * wr <= EMBED_EQ_GATE {
                    let e = backend::tdd_equals_atdd(
                        rt.tdd.as_ref().unwrap(),
                        ra.atdd.as_ref().unwrap(),
                        vt,
                    );
                    ok &= e;
                    eq_cross = e.to_string();
                }
            }
            // ATDD invariants: promise + idempotence + bits.
            let (mut promise, mut idem, mut bits_final, mut bits_bound_f) =
                (String::new(), String::new(), String::new(), String::new());
            // Canonical size proxies (ATDD only): total rational bit-mass and
            // the count of nonzero stored entries (C5 bit-bound corroboration).
            let (mut bit_mass, mut nz_entries) = (String::new(), String::new());
            if let Some(a) = &ra.atdd {
                let p = pipeline::is_boolean(a, vt);
                let mut a2 = a.clone();
                let piv = canonicalize(&mut a2, vt);
                let c2 = CanonicalForm::snapshot(&a2, piv);
                let idm = &a2 == a && c2.data == a.node;
                let bits = max_bits_atdd(a);
                let bound = ra
                    .widths
                    .iter()
                    .map(|&r| bits_bound_unslacked(r))
                    .max()
                    .unwrap_or(1);
                // Integer counting kernel agrees with the ℚ ones-contraction.
                let int_ok = IntKernel::build(a, vt).count(vt).to_string() == ra.model_count;
                ok &= p && idm && int_ok;
                promise = p.to_string();
                idem = idm.to_string();
                bits_final = bits.to_string();
                bits_bound_f = bound.to_string();
                bit_mass = bit_mass_atdd(a).to_string();
                nz_entries = nonzero_entries_atdd(a).to_string();
            }
            // Sandwich + per-cut rows.
            if both_ok {
                for id in vt.postorder() {
                    let (s, rho) = (rt.widths[id], ra.widths[id]);
                    let sandwich = rho <= s && (rho == 0 || (rho > 100 || s < (1usize << rho)));
                    ok &= sandwich;
                    if let Some(b) = inst.rho_bound {
                        ok &= rho <= b;
                    }
                    let node = vt.node(id);
                    let kind = if id == vt.root() {
                        "root"
                    } else if node.is_leaf() {
                        "leaf"
                    } else {
                        "internal"
                    };
                    let sat = if rho > 0 {
                        format!("{:.4}", ((s + 1) as f64).log2() / rho as f64)
                    } else {
                        String::new()
                    };
                    let ratio = if rho > 0 {
                        format!("{:.4}", s as f64 / rho as f64)
                    } else {
                        String::new()
                    };
                    // Per-node ATDD bit metrics (empty if no ATDD diagram).
                    let (bmax, e01) = match &ra.atdd {
                        Some(a) => (
                            node_bits(&a.node[id]).to_string(),
                            node_entries_01(&a.node[id]).to_string(),
                        ),
                        None => (String::new(), String::new()),
                    };
                    let mut row = String::new();
                    let _ = write!(
                        row,
                        "{bench_id},{},{},{},{},{},{vhash},{id},{kind},{},{},{},{s},tdd,{rho},atdd,{},{ratio},{sat},{},{},{},{}",
                        inst.family,
                        inst.name,
                        inst.channel.name(),
                        tr.kind,
                        tr.seed,
                        node.nv(),
                        node.nv().min(inst.n - node.nv()),
                        depth_of(vt, id),
                        s == rho,
                        bmax,
                        bits_bound_unslacked(rho),
                        e01,
                        inst.rho_bound.map(|b| b.to_string()).unwrap_or_default(),
                    );
                    cuts.push_str(&row);
                    cuts.push('\n');
                }
            }
            // Per-step rows (cnf channel).
            for (backend_name, rr) in [("tdd", &rt), ("atdd", &ra)] {
                for s in &rr.steps {
                    let bits = s.reduce.bits.map(|b| b.to_string()).unwrap_or_default();
                    let bb = s
                        .reduce
                        .bits
                        .map(|_| bits_bound_unslacked(s.width_reduced).to_string())
                        .unwrap_or_default();
                    let mut row = String::new();
                    let _ = write!(
                        row,
                        "{bench_id},{},{},{},{backend_name},{},{},{},{:.3},{bits},{bb},false",
                        inst.name,
                        tr.kind,
                        tr.seed,
                        s.step + 1,
                        s.width_reduced,
                        s.size_reduced,
                        (s.t_conjoin + s.reduce.t_minimize).as_secs_f64() * 1e3,
                    );
                    steps_csv.push_str(&row);
                    steps_csv.push('\n');
                }
            }
            // Runs rows (one per backend), incl. the query-time measurement
            // (model counting on the compiled artifact — Stefan's C10 study).
            for (backend_name, rr) in [("tdd", &rt), ("atdd", &ra)] {
                let (t_mc_us, mc_reps, mc_bits, t_mc_us_int, mc_int_fast) = measure_mc(rr, vt);
                let mut row = String::new();
                let empty = String::new();
                let _ = write!(
                    row,
                    "{bench_id},{},{},{},{},{},{},{},{},{},{vhash},{backend_name},{},{:.3},{:.3},{:.3},{:.3},{},{},{},{},{},{},{},{},{eq_cross},{},{},{},{},{t_mc_us},{mc_reps},{mc_bits},{},{t_mc_us_int},{mc_int_fast},{},{}",
                    inst.family,
                    inst.name,
                    inst.channel.name(),
                    inst.n,
                    inst.cnf.as_ref().map(|c| c.clauses.len()).unwrap_or(0),
                    inst.alpha,
                    inst.seed,
                    tr.kind,
                    tr.seed,
                    rr.status,
                    rr.t_compile_ms,
                    rr.t_apply_ms,
                    rr.t_minimize_ms,
                    rr.t_canon_ms,
                    rr.size_final,
                    rr.width_final,
                    rr.width_peak,
                    rr.step_peak,
                    rr.model_count,
                    mc_closed.map(|b| b.to_string()).unwrap_or_default(),
                    mc_cross,
                    tt_brute.map(|b| b.to_string()).unwrap_or_default(),
                    if backend_name == "atdd" {
                        &bits_final
                    } else {
                        &empty
                    },
                    if backend_name == "atdd" {
                        &bits_bound_f
                    } else {
                        &empty
                    },
                    if backend_name == "atdd" {
                        &promise
                    } else {
                        &empty
                    },
                    if backend_name == "atdd" {
                        &idem
                    } else {
                        &empty
                    },
                    rr.compile_reps,
                    if backend_name == "atdd" {
                        &bit_mass
                    } else {
                        &empty
                    },
                    if backend_name == "atdd" {
                        &nz_entries
                    } else {
                        &empty
                    },
                );
                runs.push_str(&row);
                runs.push('\n');
            }
            if timed_out {
                eprintln!(
                    "TIMEOUT {} [{}] vtree {}: tdd={} atdd={}",
                    inst.name,
                    inst.channel.name(),
                    tr.kind,
                    rt.status,
                    ra.status
                );
            } else if !ok {
                failures += 1;
                eprintln!(
                    "CHECK FAILED: {} {} vtree {}",
                    inst.name,
                    inst.channel.name(),
                    tr.kind
                );
                if fatal {
                    flush(&out_dir, &runs, &cuts, &steps_csv);
                    std::process::exit(1);
                }
            } else {
                eprintln!(
                    "ok {} [{}] vtree {}: S={} rho={} ({:.0}ms/{:.0}ms)",
                    inst.name,
                    inst.channel.name(),
                    tr.kind,
                    rt.width_final,
                    ra.width_final,
                    rt.t_compile_ms,
                    ra.t_compile_ms
                );
            }
            // Flush after every pair: a killed run keeps completed results.
            flush(&out_dir, &runs, &cuts, &steps_csv);
        }
    }
    flush(&out_dir, &runs, &cuts, &steps_csv);
    eprintln!("done: {failures} failed checks; output in {out_dir}/");
    if failures > 0 {
        std::process::exit(1);
    }
}

fn depth_of(vt: &Vtree, mut id: usize) -> usize {
    let mut d = 0;
    while let Some(p) = vt.node(id).parent {
        id = p;
        d += 1;
    }
    d
}

const RUNS_HEADER: &str = "bench_id,family,instance,channel,n_vars,n_clauses,alpha,seed_instance,vtree_kind,vtree_seed,vtree_hash,backend,status,t_compile_ms,t_apply_ms,t_minimize_ms,t_canon_ms,size_final,width_max_final,width_max_peak,step_peak_index,model_count,mc_matches_closed_form,mc_matches_other_backend,tt_matches_brute,eq_cross_backend,bits_max_final,bits_bound_final,promise_ok,canon_idempotent,t_mc_us_q,mc_reps,mc_bits,compile_reps,t_mc_us_int,mc_int_fast,atdd_bit_mass,atdd_nonzero_entries";
const CUTS_HEADER: &str = "bench_id,family,instance,channel,vtree_kind,vtree_seed,vtree_hash,node_id,node_kind,cut_size,cut_min_side,depth,S_t,s_source,rho_t,rho_source,is_counting,ratio_s_rho,saturation,atdd_bits_max,atdd_bits_bound,atdd_entries_01,family_rho_bound";
const STEPS_HEADER: &str = "bench_id,instance,vtree_kind,vtree_seed,backend,step,width_max_post,size_post,t_step_ms,atdd_bits_max_post,atdd_bits_bound_post,zero";

fn csv_open(dir: &str, name: &str, header: &str) -> String {
    let path = Path::new(dir).join(name);
    if path.exists() {
        fs::read_to_string(&path).expect("read existing csv")
    } else {
        format!("{header}\n")
    }
}

fn flush(dir: &str, runs: &str, cuts: &str, steps: &str) {
    fs::write(Path::new(dir).join("runs.csv"), runs).expect("write runs");
    fs::write(Path::new(dir).join("cuts.csv"), cuts).expect("write cuts");
    fs::write(Path::new(dir).join("steps.csv"), steps).expect("write steps");
}

fn factorial(n: u128) -> u128 {
    (1..=n).product()
}

fn build_suite(suite: &str, seed_base: u64) -> Vec<Instance> {
    let mut out = Vec::new();
    let counting = suite == "counting" || suite == "full" || suite == "smoke";
    let gap = suite == "gap" || suite == "full" || suite == "smoke";
    let cnfs = suite == "cnf" || suite == "full" || suite == "smoke";
    let smoke = suite == "smoke";

    if suite == "stretch" {
        // The expensive tail (T-stretch tier): run under nohup / timeout.
        // MUX k=4 (n=20): the C10 query-time crossover point. At the data
        // node S = 2^16−1 = 65535, ρ = 16 — TDD ≳10^5 edges vs ATDD ~10^3
        // rational entries. Run `--only mux_k4 --vtrees mux_data` first.
        {
            let k = 4usize;
            let n = k + (1 << k);
            let vt = Vtree::right_linear(n);
            out.push(Instance {
                family: "mux",
                name: format!("mux_k{k}"),
                channel: Channel::Tt,
                n,
                cnf: None,
                tt: Some(tt_mux(k, &vt)),
                mc_closed: Some(1 << (n - 1)),
                rho_bound: Some(1 << k),
                alpha: String::new(),
                seed: 0,
            });
        }
        for n in [12usize, 14] {
            let vt = Vtree::right_linear(n);
            out.push(Instance {
                family: "hwb",
                name: format!("hwb_n{n}"),
                channel: Channel::Tt,
                n,
                cnf: None,
                tt: Some(tt_hwb(n, &vt)),
                mc_closed: Some(1 << (n - 1)),
                rho_bound: Some(n + 2),
                alpha: String::new(),
                seed: 0,
            });
        }
        for (m, n) in [(5usize, 5usize), (6, 5)] {
            let mc = match m.cmp(&n) {
                std::cmp::Ordering::Equal => Some(factorial(n as u128)),
                std::cmp::Ordering::Greater => Some(0),
                std::cmp::Ordering::Less => None,
            };
            out.push(Instance {
                family: "php",
                name: format!("php_{m}_{n}"),
                channel: Channel::Cnf,
                n: m * n,
                cnf: Some(php(m, n)),
                tt: None,
                mc_closed: mc,
                rho_bound: None,
                alpha: String::new(),
                seed: 0,
            });
        }
        for (n, alpha, s) in [(12usize, 2.0f64, 1u64), (12, 4.26, 1)] {
            let m = (alpha * n as f64).round() as usize;
            let mut rng = Rng::new(seed_base ^ (s << 16) ^ n as u64);
            out.push(Instance {
                family: "random3",
                name: format!("r3_n{n}_a{alpha}_s{s}"),
                channel: Channel::Cnf,
                n,
                cnf: Some(random_kcnf(n, m, 3, &mut rng)),
                tt: None,
                mc_closed: None,
                rho_bound: None,
                alpha: format!("{alpha}"),
                seed: s,
            });
        }
        return out;
    }

    if counting {
        let parity_ns: &[usize] = if smoke { &[6] } else { &[4, 6, 8, 10, 12] };
        for &n in parity_ns {
            out.push(Instance {
                family: "parity",
                name: format!("parity_n{n}"),
                channel: Channel::Tt,
                n,
                cnf: None,
                tt: Some(tt_parity(n)),
                mc_closed: Some(1 << (n - 1)),
                rho_bound: Some(2),
                alpha: String::new(),
                seed: 0,
            });
        }
        let thr_ns: &[usize] = if smoke { &[6] } else { &[6, 8, 10, 12] };
        for &n in thr_ns {
            let k = n.div_ceil(2);
            let mc = (0..(1u128 << n))
                .filter(|i| (i.count_ones() as usize) >= k)
                .count() as u128;
            out.push(Instance {
                family: "threshold",
                name: format!("thr_n{n}_k{k}"),
                channel: Channel::Tt,
                n,
                cnf: None,
                tt: Some(tt_threshold(n, k)),
                mc_closed: Some(mc),
                rho_bound: None,
                alpha: String::new(),
                seed: 0,
            });
        }
    }
    if gap {
        let hwb_ns: &[usize] = if smoke { &[5] } else { &[4, 5, 6, 8, 10] };
        for &n in hwb_ns {
            // HWB truth table depends only on var ids, not the vtree shape;
            // use the right-linear vtree to materialize it once.
            let vt = Vtree::right_linear(n);
            out.push(Instance {
                family: "hwb",
                name: format!("hwb_n{n}"),
                channel: Channel::Tt,
                n,
                cnf: None,
                tt: Some(tt_hwb(n, &vt)),
                mc_closed: Some(1 << (n - 1)),
                rho_bound: Some(n + 2),
                alpha: String::new(),
                seed: 0,
            });
        }
        let mux_ks: &[usize] = if smoke { &[2] } else { &[2, 3] };
        for &k in mux_ks {
            let n = k + (1 << k);
            let vt = Vtree::right_linear(n);
            out.push(Instance {
                family: "mux",
                name: format!("mux_k{k}"),
                channel: Channel::Tt,
                n,
                cnf: None,
                tt: Some(tt_mux(k, &vt)),
                mc_closed: Some(1 << (n - 1)),
                rho_bound: Some(1 << k),
                alpha: String::new(),
                seed: 0,
            });
            // MUX as CNF: the pipeline separation demonstration.
            out.push(Instance {
                family: "mux",
                name: format!("muxcnf_k{k}"),
                channel: Channel::Cnf,
                n,
                cnf: Some(mux_cnf(k)),
                tt: None,
                mc_closed: Some(1 << (n - 1)),
                rho_bound: Some(1 << k),
                alpha: String::new(),
                seed: 0,
            });
        }
    }
    if cnfs {
        let php_grid: &[(usize, usize)] = if smoke {
            &[(3, 3), (4, 3)]
        } else {
            &[(3, 3), (4, 3), (4, 4), (5, 4)]
        };
        for &(m, n) in php_grid {
            // PHP(n, n) = n!; PHP(m > n) unsatisfiable; m < n has no simple
            // closed form.
            let mc = match m.cmp(&n) {
                std::cmp::Ordering::Equal => Some(factorial(n as u128)),
                std::cmp::Ordering::Greater => Some(0),
                std::cmp::Ordering::Less => None,
            };
            out.push(Instance {
                family: "php",
                name: format!("php_{m}_{n}"),
                channel: Channel::Cnf,
                n: m * n,
                cnf: Some(php(m, n)),
                tt: None,
                mc_closed: mc,
                rho_bound: None,
                alpha: String::new(),
                seed: 0,
            });
        }
        let r3: &[(usize, f64, u64)] = if smoke {
            &[(8, 4.26, 1)]
        } else {
            &[
                (10, 1.0, 1),
                (10, 2.0, 1),
                (10, 4.26, 1),
                (10, 4.26, 2),
                (10, 6.0, 1),
            ]
        };
        for &(n, alpha, s) in r3 {
            let m = (alpha * n as f64).round() as usize;
            let mut rng = Rng::new(seed_base ^ (s << 16) ^ n as u64);
            out.push(Instance {
                family: "random3",
                name: format!("r3_n{n}_a{alpha}_s{s}"),
                channel: Channel::Cnf,
                n,
                cnf: Some(random_kcnf(n, m, 3, &mut rng)),
                tt: None,
                mc_closed: None,
                rho_bound: None,
                alpha: format!("{alpha}"),
                seed: s,
            });
        }
    }
    out
}
