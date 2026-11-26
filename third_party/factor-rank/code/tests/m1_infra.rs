//! M1 integration tests: the shared infrastructure works end-to-end and the
//! sandwich lower bound `ρ_t ≤ S_t` half that needs no rationals holds, i.e.
//! `1 ≤ S_t ≤ 2^{|X_t|}` and every node's cut matrix reconstructs the function.

use atddc::assign::index_to_assignment;
use atddc::cnf::Cnf;
use atddc::instances::{random_kcnf, tt_parity};
use atddc::rng::Rng;
use atddc::truthtable::{cnf_truth_table, cut_matrix, factor_width, factor_widths};
use atddc::vtree::Vtree;

/// Recompute f from any node's cut matrix; must match on all vtrees.
#[test]
fn cut_matrix_reconstructs_on_random_instances() {
    let mut rng = Rng::new(20260707);
    for _ in 0..40 {
        let n = 3 + rng.below(6); // 3..=8
        let m = 2 + rng.below(8);
        let k = 1 + rng.below(3.min(n));
        let cnf = random_kcnf(n, m, k, &mut rng);

        for vtree in [
            Vtree::right_linear(n),
            Vtree::balanced(n),
            Vtree::random(n, &mut rng),
        ] {
            let f = cnf_truth_table(&cnf, &vtree);
            for id in vtree.postorder() {
                let node = vtree.node(id);
                let (nt, np) = (node.nv(), node.off);
                let ns = n - nt - np;
                let mm = cut_matrix(&f, &vtree, id);
                for ip in 0..(1usize << np) {
                    for (itau, mrow) in mm.iter().enumerate() {
                        for isuf in 0..(1usize << ns) {
                            let g = (ip << (nt + ns)) | (itau << ns) | isuf;
                            assert_eq!(mrow[(ip << ns) | isuf], f[g]);
                        }
                    }
                }
            }
        }
    }
}

/// `S_t` is within the trivial bounds and `S_root = 1` for satisfiable f.
#[test]
fn factor_width_bounds() {
    let mut rng = Rng::new(99);
    for _ in 0..60 {
        let n = 3 + rng.below(6);
        let m = 1 + rng.below(6);
        let k = 1 + rng.below(3.min(n));
        let cnf = random_kcnf(n, m, k, &mut rng);
        let vtree = Vtree::random(n, &mut rng);
        let f = cnf_truth_table(&cnf, &vtree);
        let sat = f.iter().any(|&b| b);
        for id in vtree.postorder() {
            let node = vtree.node(id);
            let s = factor_width(&f, &vtree, id);
            assert!(s <= (1usize << node.nv()));
            if sat {
                assert!(s >= 1);
            } else {
                assert_eq!(s, 0, "unsat function has all-zero cut matrices");
            }
        }
        if sat {
            assert_eq!(factor_width(&f, &vtree, vtree.root()), 1);
        }
    }
}

/// PARITY has `S_t = 2` at every proper nonempty cut, on every vtree.
#[test]
fn parity_width_two_everywhere() {
    let mut rng = Rng::new(7);
    for n in 3..=8 {
        let f = tt_parity(n);
        for vtree in [
            Vtree::right_linear(n),
            Vtree::balanced(n),
            Vtree::random(n, &mut rng),
        ] {
            for id in vtree.postorder() {
                let node = vtree.node(id);
                let s = factor_width(&f, &vtree, id);
                if node.nv() == n {
                    assert_eq!(s, 1); // root
                } else {
                    assert_eq!(s, 2, "n={n} node {id}");
                }
            }
        }
    }
}

/// The DIMACS parser and the evaluator agree with a hand-built instance.
#[test]
fn dimacs_end_to_end() {
    let text = "c tiny\np cnf 3 2\n1 2 0\n-2 3 0\n";
    let cnf = Cnf::parse_dimacs(text).unwrap();
    let vtree = Vtree::right_linear(3);
    let f = cnf_truth_table(&cnf, &vtree);
    // (x0 ∨ x1) ∧ (¬x1 ∨ x2)
    for (idx, &fv) in f.iter().enumerate() {
        let a = index_to_assignment(idx, &vtree);
        let expect = (a[0] || a[1]) && (!a[1] || a[2]);
        assert_eq!(fv, expect, "idx {idx}");
    }
    // Sanity: factor widths computed without panic.
    let _ = factor_widths(&f, &vtree);
}
