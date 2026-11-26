//! JSON interchange (`atdd-canon-v1`) for the Rust↔Python differential
//! cross-check (`FABLE_NOTES/02` §7.4). The Rust side emits a self-contained
//! document — vtree shape, clauses, canonical certificate, and summary stats —
//! that `reference/compare_canon.py` rebuilds via the `atdd_toy.py` oracle and
//! diffs node-by-node (pivots and every rational).
//!
//! The document travels Rust→Python only: the vtree is serialized as an
//! explicit recursive shape so Python never has to match a Rust RNG. Nodes in
//! `canonical` are in `vt.postorder()` order (children before parents), the
//! same order `atdd_toy.postorder(root)` produces.
//!
//! Rationals are serialized manually from `numer()`/`denom()` as `"p"` (when
//! the denominator is 1) or `"p/q"` — reduced, positive denominator, matching
//! Python `str(Fraction)`. `Display` of `BigRational` is *not* trusted here.

use super::canonical::{CanonicalForm, Pivot, max_bits, max_bits_atdd};
use super::contract::model_count;
use super::rotate::Rotation;
use super::{Atdd, NodeData};
use crate::cnf::Cnf;
use crate::vtree::Vtree;
use num_traits::One;
use serde::Serialize;

/// Serialize one exact rational as `"p"` or `"p/q"` (reduced, positive
/// denominator by the (Q-INV) invariant — matches `str(Fraction)`).
fn q_to_string(x: &super::linalg::Q) -> String {
    if x.denom().is_one() {
        format!("{}", x.numer())
    } else {
        format!("{}/{}", x.numer(), x.denom())
    }
}

/// Recursive vtree shape: `{"leaf": var}` or `{"l": …, "r": …}`.
#[derive(Serialize)]
#[serde(untagged)]
enum VtreeJson {
    Leaf {
        leaf: usize,
    },
    Internal {
        l: Box<VtreeJson>,
        r: Box<VtreeJson>,
    },
}

fn vtree_json(vt: &Vtree, t: usize) -> VtreeJson {
    let node = vt.node(t);
    if let Some(v) = node.var {
        VtreeJson::Leaf { leaf: v }
    } else {
        VtreeJson::Internal {
            l: Box::new(vtree_json(vt, node.left.unwrap())),
            r: Box::new(vtree_json(vt, node.right.unwrap())),
        }
    }
}

/// One canonical node in the document. Tagged by `kind`; leaves carry `var`.
#[derive(Serialize)]
#[serde(tag = "kind")]
enum CanonNode {
    #[serde(rename = "leaf")]
    Leaf {
        var: usize,
        pivots: Vec<String>,
        /// `d × 2`: one `[u_i(x=0), u_i(x=1)]` pair per bond.
        data: Vec<Vec<String>>,
    },
    #[serde(rename = "internal")]
    Internal {
        pivots: Vec<String>,
        /// `d` slices, each a `d(t1) × d(t2)` list of rows.
        data: Vec<Vec<Vec<String>>>,
    },
}

/// Summary statistics (spec §7.3): headline width, size, canonical bit size,
/// and the exact model count as a rational string.
#[derive(Serialize)]
struct Stats {
    width: usize,
    size: usize,
    max_entry_bits: u64,
    model_count: String,
}

/// The full `atdd-canon-v1` document.
#[derive(Serialize)]
struct CanonDoc {
    format: &'static str,
    n: usize,
    vtree: VtreeJson,
    clauses: Vec<Vec<i64>>,
    canonical: Vec<CanonNode>,
    stats: Stats,
}

/// Build the `canonical` node list (in `vt.postorder()`) from raw node data and
/// per-node canonical tests — shared by the canon and rotate documents.
fn canon_nodes(vt: &Vtree, data: &[NodeData], pivots: &[Vec<Pivot>]) -> Vec<CanonNode> {
    vt.postorder()
        .into_iter()
        .map(|t| {
            let pv: Vec<String> = pivots[t].iter().map(ToString::to_string).collect();
            match &data[t] {
                NodeData::Leaf(m) => CanonNode::Leaf {
                    var: vt.node(t).var.expect("leaf node has a variable"),
                    pivots: pv,
                    data: (0..m.r)
                        .map(|i| (0..m.c).map(|j| q_to_string(m.at(i, j))).collect())
                        .collect(),
                },
                NodeData::Internal(w) => CanonNode::Internal {
                    pivots: pv,
                    data: w
                        .iter()
                        .map(|wi| {
                            (0..wi.r)
                                .map(|i| (0..wi.c).map(|j| q_to_string(wi.at(i, j))).collect())
                                .collect()
                        })
                        .collect(),
                },
            }
        })
        .collect()
}

/// 1-based signed DIMACS clauses.
fn clauses_json(cnf: &Cnf) -> Vec<Vec<i64>> {
    cnf.clauses
        .iter()
        .map(|c| c.lits.iter().map(crate::cnf::Lit::to_dimacs).collect())
        .collect()
}

/// Serialize a compiled canonical ATDD (with its certificate) as an
/// `atdd-canon-v1` JSON string. `canon` must be the certificate of `atdd`
/// (same vtree). Nodes are emitted in `vt.postorder()`.
pub fn to_canon_json(cnf: &Cnf, vt: &Vtree, atdd: &Atdd, canon: &CanonicalForm) -> String {
    let doc = CanonDoc {
        format: "atdd-canon-v1",
        n: vt.n_vars(),
        vtree: vtree_json(vt, vt.root()),
        clauses: clauses_json(cnf),
        canonical: canon_nodes(vt, &canon.data, &canon.pivots),
        stats: Stats {
            width: atdd.width(),
            size: atdd.size(),
            max_entry_bits: max_bits(canon),
            model_count: q_to_string(&model_count(atdd, vt)),
        },
    };
    serde_json::to_string(&doc).expect("serde_json serialization of a plain document")
}

/// The rotation spec inside an `atdd-rotate-v1` document.
#[derive(Serialize)]
struct RotationSpec {
    dir: &'static str,
    /// The rotation site `v`, identified by its (sorted) variable set.
    node_vars: Vec<usize>,
}

/// The full `atdd-rotate-v1` document: the canonical input over `vtree`, a
/// rotation to apply, and the resulting canonical ATDD over `out_vtree`.
/// `reference/compare_rotate.py` re-runs `rotation_alg_toy.py`'s surgery from
/// `vtree` + `clauses` + `rotation` and diffs `out_canonical` node-by-node.
#[derive(Serialize)]
struct RotateDoc {
    format: &'static str,
    n: usize,
    vtree: VtreeJson,
    clauses: Vec<Vec<i64>>,
    rotation: RotationSpec,
    out_vtree: VtreeJson,
    out_canonical: Vec<CanonNode>,
    /// The created cut's factor rank `ρ_m = rank R` (Theorem 8(i)).
    rank_r: usize,
    stats: Stats,
}

/// Serialize a rotation of a canonical ATDD as an `atdd-rotate-v1` JSON string.
/// `in_vt` is the input vtree; `rot` the surgery output; `dir` is `"left"` or
/// `"right"`; `node_vars` identifies the rotation site by its variable set.
pub fn to_rotate_json(
    cnf: &Cnf,
    in_vt: &Vtree,
    rot: &Rotation,
    dir: &'static str,
    node_vars: Vec<usize>,
) -> String {
    let doc = RotateDoc {
        format: "atdd-rotate-v1",
        n: in_vt.n_vars(),
        vtree: vtree_json(in_vt, in_vt.root()),
        clauses: clauses_json(cnf),
        rotation: RotationSpec { dir, node_vars },
        out_vtree: vtree_json(&rot.vtree, rot.vtree.root()),
        out_canonical: canon_nodes(&rot.vtree, &rot.atdd.node, &rot.pivots),
        rank_r: rot.rank_r,
        stats: Stats {
            width: rot.atdd.width(),
            size: rot.atdd.size(),
            max_entry_bits: max_bits_atdd(&rot.atdd),
            model_count: q_to_string(&model_count(&rot.atdd, &rot.vtree)),
        },
    };
    serde_json::to_string(&doc).expect("serde_json serialization of a plain document")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::atdd::CompiledAtdd;
    use crate::atdd::linalg::{Q, q};
    use crate::atdd::pipeline::compile_cnf;
    use crate::cnf::{Clause, Cnf, Lit};

    #[test]
    fn rational_string_edge_cases() {
        // integers render without a slash, negatives keep the sign
        assert_eq!(q_to_string(&q(3)), "3");
        assert_eq!(q_to_string(&q(-3)), "-3");
        assert_eq!(q_to_string(&q(0)), "0");
        // halves: positive and negative, reduced, positive denominator
        assert_eq!(q_to_string(&Q::new(1.into(), 2.into())), "1/2");
        assert_eq!(q_to_string(&Q::new((-1).into(), 2.into())), "-1/2");
        // sign normalization: -1/-2 == 1/2 (den > 0 by Q-INV)
        assert_eq!(q_to_string(&Q::new((-1).into(), (-2).into())), "1/2");
        // reduction: 2/4 == 1/2
        assert_eq!(q_to_string(&Q::new(2.into(), 4.into())), "1/2");
    }

    #[test]
    fn tiny_instance_roundtrips_through_serde() {
        // (x0 ∨ x1) ∧ (¬x1 ∨ x2) over a right-linear vtree.
        let mut cnf = Cnf::new(3);
        cnf.add_clause(Clause::new(vec![Lit::positive(0), Lit::positive(1)]));
        cnf.add_clause(Clause::new(vec![Lit::negative(1), Lit::positive(2)]));
        let vt = crate::vtree::Vtree::right_linear(3);
        let (compiled, canon, _) = compile_cnf(&cnf, &vt);
        let CompiledAtdd::Atdd(a) = compiled else {
            panic!("instance is satisfiable");
        };
        let canon = canon.unwrap();
        let json = to_canon_json(&cnf, &vt, &a, &canon);

        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["format"], "atdd-canon-v1");
        assert_eq!(v["n"], 3);
        // one canonical entry per vtree node, in postorder
        let canonical = v["canonical"].as_array().unwrap();
        assert_eq!(canonical.len(), vt.num_nodes());
        // postorder places the first two leaves (x0, then the deeper subtree)
        // before internal nodes; every entry has a "kind" tag and pivots.
        for node in canonical {
            let kind = node["kind"].as_str().unwrap();
            assert!(kind == "leaf" || kind == "internal");
            assert!(node["pivots"].is_array());
            assert!(node["data"].is_array());
            if kind == "leaf" {
                assert!(node["var"].is_number());
            }
        }
        // clauses are 1-based signed DIMACS
        assert_eq!(v["clauses"][0], serde_json::json!([1, 2]));
        assert_eq!(v["clauses"][1], serde_json::json!([-2, 3]));
        // stats present and typed
        assert!(v["stats"]["width"].is_number());
        assert!(v["stats"]["size"].is_number());
        assert!(v["stats"]["max_entry_bits"].is_number());
        assert!(v["stats"]["model_count"].is_string());
    }
}
