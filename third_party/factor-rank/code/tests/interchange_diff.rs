//! Rust↔Python differential cross-check of the ATDD canonical form via the
//! `atdd-canon-v1` JSON interchange (`FABLE_NOTES/02` §7.4).
//!
//! Compiles a batch of random satisfiable CNFs across all three vtree shapes,
//! serializes each canonical ATDD with `to_canon_json`, and hands the whole
//! batch to `reference/compare_canon.py`, which rebuilds the function from the
//! toy oracle and diffs pivots + every rational node-by-node. If Python is not
//! available at all the test skips (no failure); if the comparator runs but
//! reports any mismatch, the test fails with its output.

use atddc::atdd::CompiledAtdd;
use atddc::atdd::interchange::to_canon_json;
use atddc::atdd::pipeline::compile_cnf;
use atddc::instances::random_kcnf;
use atddc::rng::Rng;
use atddc::vtree::Vtree;
use std::path::PathBuf;
use std::process::Command;

/// Compile ~15 random SAT instances across the three vtree families, emit one
/// `atdd-canon-v1` JSON file each, and return the file paths (plus the SAT
/// count).
fn emit_instances(dir: &std::path::Path) -> Vec<PathBuf> {
    let mut rng = Rng::new(0x1234_5678_9abc_def0);
    let mut files = Vec::new();
    let mut idx = 0usize;
    // Try enough instances to comfortably clear the 15-file / 10-SAT targets.
    let mut attempts = 0;
    while files.len() < 15 && attempts < 200 {
        attempts += 1;
        let n = 3 + rng.below(4); // 3..=6
        let m = 2 + rng.below(7); // 2..=8
        let k = 1 + rng.below(n.min(3)); // <= 3, <= n
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
        let canon = canon.expect("SAT compile yields a certificate");
        let json = to_canon_json(&cnf, &vt, &a, &canon);
        let path = dir.join(format!("inst_{idx:03}.json"));
        std::fs::write(&path, json).expect("write interchange JSON");
        files.push(path);
        idx += 1;
    }
    files
}

/// Spawn the comparator, preferring `uv run python` and falling back to
/// `python3`. Returns `None` if neither interpreter can be spawned at all.
fn run_comparator(repo: &std::path::Path, files: &[PathBuf]) -> Option<std::process::Output> {
    let script = repo.join("reference/compare_canon.py");
    let refdir = repo.join("reference");

    // Attempt 1: `uv run python compare_canon.py <files...>`
    let mut uv = Command::new("uv");
    uv.arg("run")
        .arg("python")
        .arg(&script)
        .args(files)
        .current_dir(&refdir);
    if let Ok(out) = uv.output() {
        return Some(out);
    }

    // Attempt 2: plain `python3` (atdd_toy.py is pure stdlib).
    let mut py = Command::new("python3");
    py.arg(&script).args(files).current_dir(&refdir);
    py.output().ok()
}

#[test]
fn canonical_form_matches_python_oracle() {
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let dir = std::env::temp_dir().join(format!("atddc_interchange_{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("create scratch dir");

    let files = emit_instances(&dir);
    assert!(
        files.len() >= 10,
        "expected >= 10 SAT instances, emitted {}",
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
    // Every emitted file should have produced an OK line.
    let ok_lines = stdout.lines().filter(|l| l.starts_with("OK ")).count();
    assert_eq!(
        ok_lines,
        files.len(),
        "expected one OK line per file; got {ok_lines} for {} files",
        files.len()
    );

    let _ = std::fs::remove_dir_all(&dir);
}
