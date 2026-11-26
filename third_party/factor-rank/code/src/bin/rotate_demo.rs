//! M7(c) rotation demo: (1) rotation surgery cost vs from-scratch recompile at
//! matched widths, and (2) a greedy dynamic-vtree-search that descends the max
//! factor rank by local rotations (the Choi–Darwiche primitive for ATDDs,
//! Theorem 8 remark). Prints a readable report; no CSV schema to protect.
//!
//! Usage: `cargo run --release --bin rotate_demo`

use atddc::atdd::CompiledAtdd;
use atddc::atdd::canonical::Pivot;
use atddc::atdd::func;
use atddc::atdd::linalg::{Q, q};
use atddc::atdd::pipeline::compile_cnf;
use atddc::atdd::rotate::{Rotation, canonical_and_pivots, left_rotate, right_rotate};
use atddc::atdd::{Atdd, contract::model_count};
use atddc::cnf::Cnf;
use atddc::instances::{mux_cnf, random_kcnf, tt_hwb, tt_mux, tt_parity};
use atddc::rng::Rng;
use atddc::vtree::Vtree;
use std::fmt::Write as _;
use std::fs;
use std::time::{Duration, Instant};

/// Median wall-clock of `f` over `reps` runs (keeps the result live via a
/// side-effect accumulator so the optimizer can't elide it).
fn median<T>(reps: usize, mut f: impl FnMut() -> T) -> (Duration, T) {
    let mut times = Vec::with_capacity(reps);
    let mut last = None;
    for _ in 0..reps {
        let t0 = Instant::now();
        let r = f();
        times.push(t0.elapsed());
        last = Some(r);
    }
    times.sort_unstable();
    (times[reps / 2], last.unwrap())
}

/// Per-call time of `f` in microseconds, floor-robust (the E5 timing-floor fix,
/// mirroring `bench::time_mc`): rerun `f` until the *accumulated* wall clock
/// reaches `FLOOR` (or `max_iters` calls), then report `total / calls`. Calls
/// run in geometrically growing batches so the clock is polled `O(log calls)`
/// times, keeping the polling overhead out of the per-call figure. Returns
/// `(microseconds_per_call, calls)`; `black_box` keeps each result live.
fn time_us<T>(mut f: impl FnMut() -> T, max_iters: u32) -> (f64, u32) {
    const FLOOR: Duration = Duration::from_millis(100);
    let t0 = Instant::now();
    let mut calls: u32 = 0;
    let mut batch: u32 = 1;
    loop {
        for _ in 0..batch {
            std::hint::black_box(f());
        }
        calls += batch;
        if calls >= max_iters || t0.elapsed() >= FLOOR {
            break;
        }
        batch = batch.saturating_mul(2).min(max_iters - calls);
    }
    let per_call = t0.elapsed().as_secs_f64() / f64::from(calls);
    (per_call * 1e6, calls)
}

/// Truth table of `f` over the vtree leaf order.
fn qtt(bits: &[bool]) -> Vec<Q> {
    bits.iter().map(|&b| if b { q(1) } else { q(0) }).collect()
}

/// The left-rotatable node whose local surgery is heaviest (max product of the
/// five local dims) — the most informative timing site.
fn heaviest_left_site(vt: &Vtree, a: &Atdd) -> Option<usize> {
    (0..vt.num_nodes())
        .filter(|&v| vt.is_left_rotatable(v))
        .max_by_key(|&v| {
            let w = vt.node(v).right.unwrap();
            let (b, c) = (vt.node(w).left.unwrap(), vt.node(w).right.unwrap());
            a.dim(v) * a.dim(vt.node(v).left.unwrap()) * a.dim(w) * a.dim(b) * a.dim(c)
        })
}

fn part1_rotation_vs_recompile() {
    println!("=== Part 1: rotation surgery vs from-scratch recompile ===");
    println!(
        "{:<14} {:>3} {:>6} {:>6} {:>5} {:>10} {:>12} {:>12}  {:>8} {:>8}",
        "instance",
        "n",
        "w(T)",
        "w(T')",
        "ρ_m",
        "rot(µs)",
        "recomp(µs)",
        "rebuild(µs)",
        "x_rec",
        "x_reb"
    );
    let mut rng = Rng::new(0x2604_C0DE);
    let mut cases: Vec<(String, Cnf)> =
        vec![("mux_k2".into(), mux_cnf(2)), ("mux_k3".into(), mux_cnf(3))];
    for n in [8usize, 10, 12] {
        cases.push((
            format!("rand3_n{n}"),
            random_kcnf(n, (4.2 * n as f64) as usize, 3, &mut rng),
        ));
    }

    for (name, cnf) in &cases {
        let n = cnf.n_vars;
        let vt = Vtree::balanced(n);
        let (compiled, canon, _) = compile_cnf(cnf, &vt);
        let CompiledAtdd::Atdd(a) = compiled else {
            println!("{name:<14} {n:>3}  UNSAT (skipped)");
            continue;
        };
        let pivots = canon.expect("SAT ⇒ certificate").pivots;
        let Some(v) = heaviest_left_site(&vt, &a) else {
            println!("{name:<14} {n:>3}  no left-rotatable site");
            continue;
        };
        let vt2 = vt.left_rotate(v);
        let f = func(&a, &vt);

        // Time the three routes (a rotation is cheap ⇒ more reps).
        let (t_rot, rot) = median(200, || left_rotate(&vt, &a, &pivots, v));
        let (t_rec, _) = median(5, || compile_cnf(cnf, &vt2));
        let (t_reb, _) = median(5, || canonical_and_pivots(&f, &vt2));

        // Correctness under timing: the rotation equals a from-scratch recompile.
        let (recompiled, rcanon, _) = compile_cnf(cnf, &rot.vtree);
        let CompiledAtdd::Atdd(ra) = recompiled else {
            unreachable!("same function is SAT");
        };
        assert_eq!(
            rot.atdd.node, ra.node,
            "{name}: rotation != recompiled data"
        );
        assert_eq!(rot.pivots, rcanon.unwrap().pivots, "{name}: pivots differ");

        let us = |d: Duration| d.as_secs_f64() * 1e6;
        println!(
            "{:<14} {:>3} {:>6} {:>6} {:>5} {:>10.2} {:>12.1} {:>12.1}  {:>7.1}x {:>7.1}x",
            name,
            n,
            a.width(),
            rot.atdd.width(),
            rot.rank_r,
            us(t_rot),
            us(t_rec),
            us(t_reb),
            us(t_rec) / us(t_rot),
            us(t_reb) / us(t_rot),
        );
    }
    println!(
        "  rot = local Theorem-8 surgery (reuses canon over T); recomp = compile_cnf over T'\n  \
         from scratch; rebuild = truth-table canonical over T'. All three yield the identical\n  \
         canonical ATDD (asserted). x_rec/x_reb = speedup of the rotation.\n"
    );
}

/// One greedy-search state: the canonical ATDD, its tests, and its vtree.
struct State {
    vt: Vtree,
    a: Atdd,
    pivots: Vec<Vec<Pivot>>,
}

impl State {
    fn from(f: &[Q], vt: Vtree) -> State {
        let (a, pivots) = canonical_and_pivots(f, &vt);
        State { vt, a, pivots }
    }
    /// Search cost: total representation size (the quantity dynamic vtree
    /// minimization actually reduces); the max factor rank plateaus too easily.
    fn cost(&self) -> usize {
        self.a.size()
    }
    fn width(&self) -> usize {
        self.a.width()
    }
    fn apply(self, rot: Rotation) -> State {
        State {
            vt: rot.vtree,
            a: rot.atdd,
            pivots: rot.pivots,
        }
    }
}

/// All legal rotations from a state, each as a fresh `Rotation`.
fn candidates(s: &State) -> Vec<Rotation> {
    let mut out = Vec::new();
    for v in 0..s.vt.num_nodes() {
        if s.vt.is_left_rotatable(v) {
            out.push(left_rotate(&s.vt, &s.a, &s.pivots, v));
        }
        if s.vt.is_right_rotatable(v) {
            out.push(right_rotate(&s.vt, &s.a, &s.pivots, v));
        }
    }
    out
}

/// The (size, width) profiles of a greedy descent.
struct Descent {
    size: Vec<usize>,
    width: Vec<usize>,
    moves: usize,
}

/// Greedy descent: repeatedly take the rotation that most reduces the total
/// size (tie-break: smaller max width), stopping at a local minimum. Each move
/// is an exact local Theorem-8 surgery; the function is invariant throughout.
fn greedy_descent(f: &[Q], start: Vtree, cap: usize) -> Descent {
    let mut s = State::from(f, start);
    let mc0 = model_count(&s.a, &s.vt);
    let mut size = vec![s.cost()];
    let mut width = vec![s.width()];
    let mut moves = 0;
    for _ in 0..cap {
        let cur = s.cost();
        // Best strict size reduction (tie-break: smaller width); size()/width()
        // are computed once per candidate.
        let best = candidates(&s)
            .into_iter()
            .filter_map(|r| {
                let sz = r.atdd.size();
                (sz < cur).then(|| (sz, r.atdd.width(), r))
            })
            .min_by_key(|t| (t.0, t.1));
        let Some((_, _, rot)) = best else { break };
        s = s.apply(rot);
        size.push(s.cost());
        width.push(s.width());
        moves += 1;
    }
    // Safety: the descent preserves the function (compare without cloning f).
    assert_eq!(
        model_count(&s.a, &s.vt),
        mc0,
        "descent changed the model count"
    );
    assert_eq!(
        func(&s.a, &s.vt).as_slice(),
        f,
        "descent changed the function"
    );
    Descent { size, width, moves }
}

/// The EQ_n truth table over `2n` variables y_0..y_{n-1}, z_0..z_{n-1} in the
/// vtree's leaf order (MSB first): 1 iff y_i = z_i for all i.
fn eq_tt(n: usize, vt: &Vtree) -> Vec<Q> {
    let order = vt.leaf_order();
    let total = 2 * n;
    let mut f = vec![q(0); 1 << total];
    for x in 0..(1u64 << total) {
        // bit at leaf position p (MSB first) is variable order[p].
        let val = |var: usize| -> u64 {
            let p = order.iter().position(|&v| v == var).unwrap();
            (x >> (total - 1 - p)) & 1
        };
        if (0..n).all(|i| val(i) == val(n + i)) {
            f[x as usize] = q(1);
        }
    }
    f
}

fn part2_greedy_search() {
    println!("=== Part 2: greedy dynamic-vtree-search (local rotations) ===");
    println!(
        "  move = the local rotation that most reduces total size (the max factor\n  \
         rank plateaus too easily to steer on directly); function invariant throughout.\n"
    );
    println!(
        "{:<14} {:>4} {:>13} {:>13} {:>6}   width profile",
        "family(start)", "n", "size↓", "width↓", "#rot"
    );

    // MUX from bal_id (already near-optimal) AND from mux_data (the width-8/16
    // gap vtree — a bad start the search should escape).
    for k in [2usize, 3] {
        let n = k + (1 << k);
        let bal = Vtree::balanced(n);
        run(
            &format!("mux_k{k}(bal)"),
            n,
            qtt(&tt_mux(k, &bal)),
            bal,
            4 * n * n,
        );
        let md = Vtree::mux_data(k);
        run(
            &format!("mux_k{k}(data)"),
            n,
            qtt(&tt_mux(k, &md)),
            md,
            4 * n * n,
        );
    }
    // HWB from bal_id: fr ≤ n+2 on *every* vtree (lem:hwb) ⇒ vtree-insensitive,
    // so the search finds little to do — the empirical confirmation.
    for n in [6usize, 8] {
        let bal = Vtree::balanced(n);
        run(
            &format!("hwb_{n}(bal)"),
            n,
            qtt(&tt_hwb(n, &bal)),
            bal,
            4 * n * n,
        );
    }
    // EQ_n from a *separated* start (all y's, then all z's): the Theorem 7
    // witness (fr = 2^n separated, 2 interleaved) — the search must interleave.
    for n in [2usize, 3] {
        let total = 2 * n;
        let mut order = Vec::new();
        order.extend(0..n); // y…
        order.extend(n..total); // z…
        let sep = Vtree::balanced_order(&order);
        run(
            &format!("eq_{n}(sep)"),
            total,
            eq_tt(n, &sep),
            sep,
            8 * total * total,
        );
    }
    // A random 3-CNF from bal_id.
    let mut rng = Rng::new(0x05EA_2604);
    for n in [8usize, 10] {
        let cnf = random_kcnf(n, (4.2 * n as f64) as usize, 3, &mut rng);
        let bal = Vtree::balanced(n);
        let (compiled, _, _) = compile_cnf(&cnf, &bal);
        let CompiledAtdd::Atdd(a) = compiled else {
            continue;
        };
        run(
            &format!("rand3_n{n}(bal)"),
            n,
            func(&a, &bal),
            bal,
            4 * n * n,
        );
    }
}

fn run(label: &str, n: usize, f: Vec<Q>, start: Vtree, cap: usize) {
    let d = greedy_descent(&f, start, cap);
    let arrow = |v: &[usize]| format!("{}→{}", v.first().unwrap(), v.last().unwrap());
    let prof: Vec<String> = d.width.iter().map(ToString::to_string).collect();
    let shown = if prof.len() > 10 {
        format!(
            "{} … {}",
            prof[..5].join("→"),
            prof[prof.len() - 2..].join("→")
        )
    } else {
        prof.join("→")
    };
    println!(
        "{:<14} {:>4} {:>13} {:>13} {:>6}   {}",
        label,
        n,
        arrow(&d.size),
        arrow(&d.width),
        d.moves,
        shown
    );
}

/// Part 3 (E5 data): rotation surgery vs from-scratch recompile as `n` grows on
/// the PARITY family. Parity's cut ranks are the constant 2, so the LOCAL width
/// at the rotation site stays fixed while `n` scales — this isolates Theorem
/// 11's `O(w^6)`, `n`-independent rotation cost against the single honest
/// baseline: the from-scratch canonical ATDD on the *rotated* vtree (built from
/// the same source function; no second truth-table baseline). One CSV row per
/// `n`, columns `family,n,w,rho_local,t_rotate_us,t_recompile_us,repeats`; the
/// `repeats` column is the rotation's floor-accumulation call count. Both µs
/// figures use `time_us` so the sub-microsecond rotation is measured above the
/// timing floor.
fn part3_parity_csv(path: &str) {
    const MAX_ITERS: u32 = 1_000_000;
    println!("=== Part 3: PARITY rotation-vs-recompile sweep (E5 CSV) ===");
    println!(
        "  w and rho_local are the LOCAL width/rank at the rotated node (constant in n\n  \
         for PARITY); t_recompile = from-scratch canonical ATDD on the rotated vtree.\n"
    );
    println!(
        "{:<8} {:>3} {:>3} {:>10} {:>13} {:>15} {:>10}",
        "family", "n", "w", "rho_local", "t_rotate(µs)", "t_recompile(µs)", "repeats"
    );
    let mut csv = String::from("family,n,w,rho_local,t_rotate_us,t_recompile_us,repeats\n");
    for n in [4usize, 6, 8, 10, 12, 14] {
        // Right-linear vtree: every interior node has an internal right child,
        // so a left-rotatable site with constant (=2) local ranks exists.
        let vt = Vtree::right_linear(n);
        let f = qtt(&tt_parity(n));
        let (a, pivots) = canonical_and_pivots(&f, &vt);
        let Some(v) = heaviest_left_site(&vt, &a) else {
            continue;
        };
        let vt2 = vt.left_rotate(v);

        // Local site metadata (untimed): the created cut's rank and the local
        // width = max of the five involved bond dims and that rank.
        let w_node = vt.node(v).right.unwrap();
        let b_id = vt.node(w_node).left.unwrap();
        let c_id = vt.node(w_node).right.unwrap();
        let rho_local = left_rotate(&vt, &a, &pivots, v).rank_r;
        let w = [
            a.dim(v),
            a.dim(vt.node(v).left.unwrap()),
            a.dim(w_node),
            a.dim(b_id),
            a.dim(c_id),
            rho_local,
        ]
        .into_iter()
        .max()
        .unwrap();

        // Timing-floor accumulation for both microsecond figures.
        let (t_rotate_us, repeats) = time_us(|| left_rotate(&vt, &a, &pivots, v), MAX_ITERS);
        let (t_recompile_us, _) = time_us(|| canonical_and_pivots(&f, &vt2), MAX_ITERS);

        let _ = writeln!(
            csv,
            "parity,{n},{w},{rho_local},{t_rotate_us:.4},{t_recompile_us:.4},{repeats}"
        );
        println!(
            "{:<8} {:>3} {:>3} {:>10} {:>13.4} {:>15.2} {:>10}",
            "parity", n, w, rho_local, t_rotate_us, t_recompile_us, repeats
        );
    }
    fs::write(path, &csv).expect("write E5 parity CSV");
    println!("  wrote {path}\n");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut csv_path: Option<String> = None;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--csv" => {
                csv_path = Some(args[i + 1].clone());
                i += 2;
            }
            other => {
                eprintln!("unknown argument {other}");
                std::process::exit(2);
            }
        }
    }
    part1_rotation_vs_recompile();
    part2_greedy_search();
    if let Some(path) = &csv_path {
        part3_parity_csv(path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mux_search_descends_from_the_gap_vtree() {
        // MUX_3 on mux_data starts at the width-8 data cut; local rotations must
        // strictly shrink the representation while preserving the function.
        let k = 3;
        let n = k + (1 << k);
        let md = Vtree::mux_data(k);
        let f = qtt(&tt_mux(k, &md));
        let d = greedy_descent(&f, md, 4 * n * n);
        assert!(d.moves > 0, "expected the search to make progress");
        assert!(
            d.size.last().unwrap() < d.size.first().unwrap(),
            "size must strictly decrease"
        );
        assert!(
            d.width.last().unwrap() < d.width.first().unwrap(),
            "width must decrease off the gap vtree"
        );
        // greedy_descent already asserts model-count and function invariance.
    }

    #[test]
    fn rotation_equals_recompile_under_the_bench_path() {
        // The Part-1 correctness assertion, as a test: a rotation of the MUX_2
        // canonical equals compiling the CNF from scratch over the rotated vtree.
        let cnf = mux_cnf(2);
        let vt = Vtree::balanced(cnf.n_vars);
        let (compiled, canon, _) = compile_cnf(&cnf, &vt);
        let CompiledAtdd::Atdd(a) = compiled else {
            panic!("MUX is SAT");
        };
        let pivots = canon.unwrap().pivots;
        let v = heaviest_left_site(&vt, &a).expect("a left-rotatable site");
        let rot = left_rotate(&vt, &a, &pivots, v);
        let (recompiled, rcanon, _) = compile_cnf(&cnf, &rot.vtree);
        let CompiledAtdd::Atdd(ra) = recompiled else {
            panic!("still SAT");
        };
        assert_eq!(rot.atdd.node, ra.node);
        assert_eq!(rot.pivots, rcanon.unwrap().pivots);
    }
}
