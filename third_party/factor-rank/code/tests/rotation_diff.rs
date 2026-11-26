//! Rust↔Python differential cross-check of the ATDD rotation surgery via the
//! `atdd-rotate-v1` JSON interchange (M7 / Theorem 8).
//!
//! Compiles random satisfiable CNFs to canonical ATDDs, applies every legal
//! left and right rotation with the Rust surgery, serializes each with
//! `to_rotate_json`, and hands the batch to `reference/compare_rotate.py`,
//! which re-runs `rotation_alg_toy.py`'s OWN surgery on the same input and
//! diffs the result node-by-node (pivots + every rational + rank). Run with
//! `--selftest`, so each OK line also confirms a flipped entry is rejected.
//! If no Python interpreter can be spawned the test skips (no failure).

use atddc::atdd::CompiledAtdd;
use atddc::atdd::interchange::to_rotate_json;
use atddc::atdd::pipeline::compile_cnf;
use atddc::atdd::rotate::{left_rotate, right_rotate};
use atddc::instances::random_kcnf;
use atddc::rng::Rng;
use atddc::vtree::Vtree;
use std::path::PathBuf;
use std::process::Command;

/// Sorted variable set of vtree node `t` (the rotation-site identifier).
fn node_vars(vt: &Vtree, t: usize) -> Vec<usize> {
    let mut v = vt.node(t).vars.clone();
    v.sort_unstable();
    v
}

/// Emit `atdd-rotate-v1` docs for left and right rotations of random SAT CNFs.
fn emit_rotations(dir: &std::path::Path) -> Vec<PathBuf> {
    let mut rng = Rng::new(0x0D15_EA5E_1337_2604);
    let mut files = Vec::new();
    let mut idx = 0usize;
    let mut attempts = 0;
    while files.len() < 40 && attempts < 400 {
        attempts += 1;
        let n = 4 + rng.below(4); // 4..=7
        let m = 2 + rng.below(2 * n);
        let k = 1 + rng.below(n.min(3));
        let cnf = random_kcnf(n, m, k, &mut rng);
        let vt = match rng.below(3) {
            0 => Vtree::right_linear(n),
            1 => Vtree::balanced(n),
            _ => Vtree::random(n, &mut rng),
        };
        let (compiled, canon, _) = compile_cnf(&cnf, &vt);
        let CompiledAtdd::Atdd(a) = compiled else {
            continue; // skip UNSAT
        };
        let pivots = canon.expect("SAT compile yields a certificate").pivots;

        // Up to 3 left rotations and 2 right rotations per instance.
        let mut nleft = 0;
        for v in 0..vt.num_nodes() {
            if nleft >= 3 || files.len() >= 40 {
                break;
            }
            if vt.is_left_rotatable(v) {
                let rot = left_rotate(&vt, &a, &pivots, v);
                let json = to_rotate_json(&cnf, &vt, &rot, "left", node_vars(&vt, v));
                let path = dir.join(format!("rot_{idx:03}.json"));
                std::fs::write(&path, json).expect("write rotate JSON");
                files.push(path);
                idx += 1;
                nleft += 1;
            }
        }
        let mut nright = 0;
        for v in 0..vt.num_nodes() {
            if nright >= 2 || files.len() >= 40 {
                break;
            }
            if vt.is_right_rotatable(v) {
                let rot = right_rotate(&vt, &a, &pivots, v);
                let json = to_rotate_json(&cnf, &vt, &rot, "right", node_vars(&vt, v));
                let path = dir.join(format!("rot_{idx:03}.json"));
                std::fs::write(&path, json).expect("write rotate JSON");
                files.push(path);
                idx += 1;
                nright += 1;
            }
        }
    }
    files
}

/// Spawn the comparator (`uv run python`, then `python3`) with `--selftest`.
fn run_comparator(repo: &std::path::Path, files: &[PathBuf]) -> Option<std::process::Output> {
    let script = repo.join("reference/compare_rotate.py");
    let refdir = repo.join("reference");

    let mut uv = Command::new("uv");
    uv.arg("run")
        .arg("python")
        .arg(&script)
        .arg("--selftest")
        .args(files)
        .current_dir(&refdir);
    if let Ok(out) = uv.output() {
        return Some(out);
    }
    let mut py = Command::new("python3");
    py.arg(&script)
        .arg("--selftest")
        .args(files)
        .current_dir(&refdir);
    py.output().ok()
}

#[test]
fn rotation_surgery_matches_python_reference() {
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let dir = std::env::temp_dir().join(format!("atddc_rotate_{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("create scratch dir");

    let files = emit_rotations(&dir);
    assert!(
        files.len() >= 20,
        "expected >= 20 rotation docs, emitted {}",
        files.len()
    );

    let Some(out) = run_comparator(&repo, &files) else {
        eprintln!("skipping: no python available (neither `uv` nor `python3` spawned)");
        let _ = std::fs::remove_dir_all(&dir);
        return;
    };

    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    println!("comparator stdout:\n{stdout}");
    if !stderr.is_empty() {
        println!("comparator stderr:\n{stderr}");
    }

    assert!(
        out.status.success(),
        "comparator reported a mismatch (exit {:?})\n--- stdout ---\n{stdout}\n--- stderr ---\n{stderr}",
        out.status.code()
    );
    let ok_lines = stdout.lines().filter(|l| l.starts_with("OK ")).count();
    assert_eq!(
        ok_lines,
        files.len(),
        "expected one OK line per file; got {ok_lines} for {} files",
        files.len()
    );

    let _ = std::fs::remove_dir_all(&dir);
}
