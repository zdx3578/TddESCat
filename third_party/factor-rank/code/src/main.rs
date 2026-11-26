//! `atddc` command-line entry point.
//!
//! Compile a DIMACS CNF with BOTH backends on the same vtree and report the
//! twin statistics side by side: per-node TDD factor width `S_t` vs ATDD
//! factor rank `ρ_t` (the sandwich `ρ_t ≤ S_t ≤ 2^{ρ_t}−1`), sizes, exact
//! model counts, and the ATDD canonical bit statistic. Optionally dump the
//! ATDD canonical form as `atdd-canon-v1` JSON for the Python cross-check
//! (`reference/compare_canon.py`).

use atddc::atdd::canonical::max_bits;
use atddc::atdd::pipeline::compile_cnf;
use atddc::atdd::{CompiledAtdd, interchange};
use atddc::cnf::Cnf;
use atddc::tdd::{Compiled, compile};
use atddc::vtree::Vtree;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!(
            "usage: {} <file.cnf> [right|balanced] [--emit-canon <out.json>]",
            args[0]
        );
        eprintln!("  compiles with both backends (TDD and ATDD) and reports S_t vs rho_t");
        return ExitCode::FAILURE;
    }

    let text = match std::fs::read_to_string(&args[1]) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("error reading {}: {e}", args[1]);
            return ExitCode::FAILURE;
        }
    };
    let cnf = match Cnf::parse_dimacs(&text) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("parse error: {e}");
            return ExitCode::FAILURE;
        }
    };
    if cnf.n_vars == 0 {
        eprintln!("empty variable set");
        return ExitCode::FAILURE;
    }

    let mut kind = "right".to_string();
    let mut emit_canon: Option<String> = None;
    let mut i = 2;
    while i < args.len() {
        match args[i].as_str() {
            "--emit-canon" => {
                let Some(path) = args.get(i + 1) else {
                    eprintln!("--emit-canon needs a path");
                    return ExitCode::FAILURE;
                };
                emit_canon = Some(path.clone());
                i += 2;
            }
            k @ ("right" | "balanced") => {
                kind = k.to_string();
                i += 1;
            }
            other => {
                eprintln!("unknown argument {other:?}");
                return ExitCode::FAILURE;
            }
        }
    }
    let vtree = if kind == "right" {
        Vtree::right_linear(cnf.n_vars)
    } else {
        Vtree::balanced(cnf.n_vars)
    };

    println!(
        "n={} clauses={} vtree={kind}",
        cnf.n_vars,
        cnf.clauses.len()
    );

    // TDD backend.
    let t0 = std::time::Instant::now();
    let tdd = compile(&cnf, &vtree);
    let t_tdd = t0.elapsed();
    // ATDD backend.
    let t1 = std::time::Instant::now();
    let (atdd, canon, steps) = compile_cnf(&cnf, &vtree);
    let t_atdd = t1.elapsed();

    match (&tdd, &atdd) {
        (Compiled::Unsat, CompiledAtdd::Unsat) => {
            println!("UNSAT (both backends agree)  tdd={t_tdd:?} atdd={t_atdd:?}");
            ExitCode::SUCCESS
        }
        (Compiled::Tdd(t), CompiledAtdd::Atdd(a)) => {
            let widths = t.widths();
            let dims = a.dims();
            println!("node  S_t  rho_t   (vtree-node id: leaf var or children)");
            for id in vtree.postorder() {
                let node = vtree.node(id);
                let desc = node.var.map_or_else(
                    || format!("({}, {})", node.left.unwrap(), node.right.unwrap()),
                    |v| format!("x{v}"),
                );
                println!("{id:>4}  {:>3}  {:>5}   {desc}", widths[id], dims[id]);
            }
            let bits = canon.as_ref().map_or(0, max_bits);
            println!(
                "TDD : width={} size={} models={} time={t_tdd:?}",
                t.width(),
                t.size(),
                t.model_count(&vtree)
            );
            println!(
                "ATDD: width={} size={} models={} max_bits={bits} steps={} time={t_atdd:?}",
                a.width(),
                a.size(),
                a.model_count(&vtree),
                steps.len()
            );
            if let (Some(path), Some(c)) = (emit_canon, canon.as_ref()) {
                let json = interchange::to_canon_json(&cnf, &vtree, a, c);
                if let Err(e) = std::fs::write(&path, json) {
                    eprintln!("error writing {path}: {e}");
                    return ExitCode::FAILURE;
                }
                println!("canonical form written to {path}");
            }
            ExitCode::SUCCESS
        }
        _ => {
            eprintln!("BACKEND DISAGREEMENT on SAT/UNSAT — this is a bug");
            ExitCode::FAILURE
        }
    }
}
