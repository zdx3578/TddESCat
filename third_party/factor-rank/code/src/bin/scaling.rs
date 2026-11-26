//! `scaling` — large-`n` asymptotic-separation experiment (paper
//! `thm:separation`). Compiles ONE (family, size, backend) cell per process
//! invocation and appends ONE row to a scaling CSV. Isolating each cell in its
//! own process is the robustness design for an unattended multi-hour sweep: a
//! TDD compile at the exponential wall may exhaust memory and be killed by the
//! OS, but that kills only this process, never a sibling backend and never the
//! driver. On success or in-process timeout the binary writes its own row and
//! exits 0; on a crash (OOM/abort) it writes nothing, so the driver
//! (`run_scaling.sh`) records `status=oom` for that cell.
//!
//! Two families, two channels:
//!   * MUX_k via CNF (`mux_cnf`, the bottom-up apply loop) on the `mux_data`
//!     vtree — NO 2^n materialization, so `k` reaches 5,6,7 (n = 37,70,135).
//!     Data-cut S = 2^(2^k) (TDD, blows up at k≥5) vs ρ = 2^k (ATDD, ≈ n).
//!   * HWB_n via truth table on the right-linear vtree. The reference
//!     constructor itself is 2^n, so BOTH backends cap at n ≈ 20–22 by memory;
//!     HWB corroborates the width/size divergence but MUX carries the "ATDD
//!     survives past the TDD wall" story.
//!
//! Closed-form model count for both families is 2^(n-1); the binary asserts the
//! computed count matches it (as a BigInt, so it is correct up to k=7 where the
//! count is 2^134). Cross-backend agreement is checked in post-analysis by
//! comparing the `model_count` column across the two backend rows of a cell.
//!
//! Usage (one cell):
//!   scaling --family mux --size 3 --backend tdd  --out bench_out_scaling/runs.csv
//!   scaling --family hwb --size 8 --backend atdd --out bench_out_scaling/runs.csv \
//!           --timeout-s 1800
//! Flags: `--family <mux|hwb>`, `--size <k|n>`, `--backend <tdd|atdd>`,
//! `--out <csv>`, `--timeout-s <s>` (per-compile wall clock; 0 = off).

use atddc::atdd::Atdd;
use atddc::atdd::canonical::canonicalize;
use atddc::atdd::intcount::IntKernel;
use atddc::atdd::minimize::minimize;
use atddc::atdd::oracle::{build_from_truthtable, to_q};
use atddc::backend::{self, AtddBackend, Outcome, TddBackend};
use atddc::instances::{mux_cnf, tt_hwb};
use atddc::tdd::Tdd;
use atddc::truthtable::tdd_from_truth_table;
use atddc::vtree::Vtree;
use num_bigint::BigInt;
use std::fmt::Write as _;
use std::fs;
use std::io::Write as _;
use std::path::Path;
use std::time::{Duration, Instant};

const CSV_HEADER: &str = "family,size_param,n_vars,n_clauses,backend,vtree,status,t_compile_ms,size_final,width_max_final,model_count,t_mc_us,mc_matches_closed_form";

/// One completed cell (everything a row needs beyond the fixed cell key).
struct Summary {
    t_compile_ms: f64,
    size_final: usize,
    width_final: usize,
    model_count: String,
    t_mc_us: f64,
}

/// Per-call time of `f` in microseconds: repeat until 50 ms accumulate (or a
/// cap), report total/calls. Query-time counting on a small diagram is far
/// below the timer resolution, so a single call measures only noise.
fn time_mc(mut f: impl FnMut(), max_reps: u32) -> f64 {
    const FLOOR: Duration = Duration::from_millis(50);
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
        batch = batch
            .saturating_mul(2)
            .min(max_reps.saturating_sub(calls).max(1));
    }
    t0.elapsed().as_secs_f64() / f64::from(calls) * 1e6
}

fn summarize_tdd(t: &Tdd, vt: &Vtree, t_compile: Duration) -> Summary {
    let mc = t.model_count(vt);
    let t_mc_us = time_mc(
        || {
            std::hint::black_box(t.model_count(vt));
        },
        1_000_000,
    );
    Summary {
        t_compile_ms: t_compile.as_secs_f64() * 1e3,
        size_final: t.size(),
        width_final: t.widths().into_iter().max().unwrap_or(0),
        model_count: mc.to_string(),
        t_mc_us,
    }
}

fn summarize_atdd(a: &Atdd, vt: &Vtree, t_compile: Duration) -> Summary {
    // Integer kernel is the fair ATDD query-time measure (the ℚ kernel is
    // 20–40× slower and unrepresentative; CLAUDE.md constraint).
    let kernel = IntKernel::build(a, vt);
    let mc = kernel.count(vt);
    let t_mc_us = time_mc(
        || {
            std::hint::black_box(kernel.count(vt));
        },
        1_000_000,
    );
    Summary {
        t_compile_ms: t_compile.as_secs_f64() * 1e3,
        size_final: a.size(),
        width_final: a.dims().into_iter().max().unwrap_or(0),
        model_count: mc.to_string(),
        t_mc_us,
    }
}

/// Compile + count the requested cell. Runs inside the timeout worker thread,
/// so it owns 'static clones of its inputs and returns a small `Summary`.
fn run_cell(family: &str, size: usize, backend: &str) -> Summary {
    match (family, backend) {
        // MUX via the shared bottom-up CNF apply loop on the good vtree.
        ("mux", "tdd") => {
            let (cnf, vt) = (mux_cnf(size), Vtree::mux_data(size));
            let t0 = Instant::now();
            match backend::compile::<TddBackend>(&cnf, &vt) {
                Outcome::Compiled(d, _) => summarize_tdd(&d, &vt, t0.elapsed()),
                Outcome::Unsat => unreachable!("MUX is satisfiable"),
            }
        }
        ("mux", "atdd") => {
            let (cnf, vt) = (mux_cnf(size), Vtree::mux_data(size));
            let t0 = Instant::now();
            match backend::compile::<AtddBackend>(&cnf, &vt) {
                Outcome::Compiled(d, _) => summarize_atdd(&d, &vt, t0.elapsed()),
                Outcome::Unsat => unreachable!("MUX is satisfiable"),
            }
        }
        // HWB via the truth-table reference constructor (2^n route).
        ("hwb", "tdd") => {
            let vt = Vtree::right_linear(size);
            let f = tt_hwb(size, &vt);
            let t0 = Instant::now();
            let t = tdd_from_truth_table(&f, &vt).expect("HWB is nonzero");
            summarize_tdd(&t, &vt, t0.elapsed())
        }
        ("hwb", "atdd") => {
            let vt = Vtree::right_linear(size);
            let qf = to_q(&tt_hwb(size, &vt));
            let t0 = Instant::now();
            let mut a = build_from_truthtable(&qf, &vt);
            minimize(&mut a, &vt);
            canonicalize(&mut a, &vt);
            summarize_atdd(&a, &vt, t0.elapsed())
        }
        _ => {
            eprintln!("unknown family/backend: {family}/{backend}");
            std::process::exit(2);
        }
    }
}

fn n_vars(family: &str, size: usize) -> usize {
    match family {
        "mux" => size + (1 << size),
        "hwb" => size,
        _ => size,
    }
}

fn n_clauses(family: &str, size: usize) -> usize {
    match family {
        "mux" => 1 << size, // mux_cnf: one clause per address value
        _ => 0,             // hwb uses the tt channel
    }
}

fn vtree_name(family: &str) -> &'static str {
    match family {
        "mux" => "mux_data",
        _ => "rl_id",
    }
}

/// Append one row; write the header first if the file is new.
fn append_row(out: &str, row: &str) {
    let path = Path::new(out);
    if let Some(dir) = path.parent()
        && !dir.as_os_str().is_empty()
    {
        fs::create_dir_all(dir).expect("create out dir");
    }
    let need_header = !path.exists();
    let mut f = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .expect("open csv");
    if need_header {
        writeln!(f, "{CSV_HEADER}").expect("write header");
    }
    writeln!(f, "{row}").expect("write row");
    f.flush().expect("flush csv");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut family = String::new();
    let mut size: Option<usize> = None;
    let mut backend = String::new();
    let mut out = "bench_out_scaling/runs.csv".to_string();
    let mut timeout: Option<Duration> = None;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--family" => {
                family = args[i + 1].clone();
                i += 2;
            }
            "--size" => {
                size = Some(args[i + 1].parse().expect("size"));
                i += 2;
            }
            "--backend" => {
                backend = args[i + 1].clone();
                i += 2;
            }
            "--out" => {
                out = args[i + 1].clone();
                i += 2;
            }
            "--timeout-s" => {
                let s: u64 = args[i + 1].parse().expect("timeout seconds");
                timeout = (s > 0).then(|| Duration::from_secs(s));
                i += 2;
            }
            other => {
                eprintln!("unknown argument {other}");
                std::process::exit(2);
            }
        }
    }
    let size = size.expect("--size required");
    assert!(
        family == "mux" || family == "hwb",
        "--family must be mux or hwb"
    );
    assert!(
        backend == "tdd" || backend == "atdd",
        "--backend must be tdd or atdd"
    );

    let n = n_vars(&family, size);
    let nc = n_clauses(&family, size);
    let vt_name = vtree_name(&family);
    // Closed-form model count for both families is 2^(n-1) (as a BigInt, so it
    // stays exact for MUX k=7 where 2^134 overflows every fixed-width integer).
    let closed = (BigInt::from(1) << (n - 1)).to_string();
    let cell_key = format!("{family},{size},{n},{nc},{backend},{vt_name}");

    eprintln!("cell {cell_key}: compiling (timeout {timeout:?})...");

    // In-process compile timeout: a worker thread computes the summary; on
    // expiry we record status=timeout and exit(0) IMMEDIATELY, so the orphaned
    // worker cannot go on to OOM the process after the row is already banked.
    let (fam_w, be_w) = (family.clone(), backend.clone());
    let summary = match timeout {
        None => Some(run_cell(&family, size, &backend)),
        Some(d) => {
            let (tx, rx) = std::sync::mpsc::channel();
            std::thread::spawn(move || {
                let _ = tx.send(run_cell(&fam_w, size, &be_w));
            });
            rx.recv_timeout(d).ok()
        }
    };

    let row = match summary {
        Some(s) => {
            let mc_ok = s.model_count == closed;
            let mut r = String::new();
            let _ = write!(
                r,
                "{cell_key},ok,{:.3},{},{},{},{:.3},{mc_ok}",
                s.t_compile_ms, s.size_final, s.width_final, s.model_count, s.t_mc_us,
            );
            eprintln!(
                "ok {cell_key}: size={} width={} mc_ok={mc_ok} ({:.0}ms)",
                s.size_final, s.width_final, s.t_compile_ms
            );
            r
        }
        None => {
            let secs = timeout.map(|d| d.as_secs_f64() * 1e3).unwrap_or(0.0);
            eprintln!("TIMEOUT {cell_key}");
            format!("{cell_key},timeout,{secs:.3},0,0,,,")
        }
    };
    append_row(&out, &row);
    // Exit now (do not fall through and let the orphaned worker keep running).
    std::process::exit(0);
}
