//! TDD backend: Tree Decision Diagrams (Capelli–Choi–Mengel–Muñoz–Van den
//! Broeck), a deterministic bottom-up tree automaton over the vtree.
//!
//! Authoritative spec: `FABLE_NOTES/03_tdd_canonicity.md`. This module (M2a)
//! provides the data structures, the width-≤2 clause diagram (paper §6), and
//! evaluation; the product `apply`, the clean→classify→rebuild `minimize`, and
//! the bottom-up compile loop follow in M2b.
//!
//! Representation: a `Tdd` is a `Vec<Level>` indexed by vtree-node id (`VId`).
//! Each level holds the `t`-nodes for that vtree node, addressed by a local
//! `NId` (`u32`). The output node is node `0` of the root level. There is *no*
//! interning: in a deterministic TDD distinct `t`-nodes have disjoint input
//! sets, so a key→id table would never merge (`FABLE_NOTES/03` §0); canonicity
//! comes from a deterministic final numbering during `minimize` (M2b).

use crate::assign::index_to_assignment_into;
use crate::cnf::Clause;
use crate::vtree::Vtree;

mod compile;
pub mod ops;
pub use compile::{apply_and, compile, minimize};

/// Local node index within one vtree level.
pub type NId = u32;

/// A leaf `t`-node's label. `Zero` is never stored (dead nodes are dropped);
/// the ordering `Pos < Neg < One` is the canonical leaf order used by `minimize`.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub enum LeafLabel {
    /// The literal `x` (satisfied when the variable is true).
    Pos,
    /// The literal `¬x` (satisfied when the variable is false).
    Neg,
    /// The constant-1 function (satisfied by both values).
    One,
}

impl LeafLabel {
    /// Is this label satisfied by the given variable value?
    pub fn satisfied_by(self, value: bool) -> bool {
        match self {
            LeafLabel::Pos => value,
            LeafLabel::Neg => !value,
            LeafLabel::One => true,
        }
    }
}

/// The `t`-nodes at one vtree node.
///
/// * `Leaf`: each node is a label; node `i` is `labels[i]`.
/// * `Internal`: each node is its input set `E(g)`, a sorted, duplicate-free set
///   of `(left NId, right NId)` pairs.
#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub enum Level {
    Leaf(Vec<LeafLabel>),
    Internal(Vec<Box<[(NId, NId)]>>),
}

impl Default for Level {
    /// An empty leaf level — the placeholder used while assembling diagrams
    /// level by level (and by `mem::take` when consuming them).
    fn default() -> Self {
        Level::Leaf(Vec::new())
    }
}

impl Level {
    /// Number of `t`-nodes at this level (the width statistic once minimized).
    pub fn len(&self) -> usize {
        match self {
            Level::Leaf(v) => v.len(),
            Level::Internal(v) => v.len(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// A TDD respecting a vtree: one `Level` per vtree node, indexed by vtree-node
/// id. The output node is node `0` of the root level.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Tdd {
    pub levels: Vec<Level>,
}

/// The result of compiling a CNF: either the diagram, or the unsatisfiable
/// (identically-false) verdict for which no canonical diagram exists.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Compiled {
    Unsat,
    Tdd(Tdd),
}

/// A clause normalized for diagram construction.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum NormalizedClause {
    /// A tautology (`x ∨ ¬x ∨ …`): always true, contributes nothing to a
    /// conjunction.
    Tautology,
    /// The empty clause: always false ⇒ the formula is unsatisfiable.
    Empty,
    /// A non-trivial clause as `(variable, positive)` literals, ≤1 per variable.
    Lits(Vec<(usize, bool)>),
}

/// Deduplicate literals and detect tautologies. A variable occurring with both
/// polarities makes the clause a tautology; repeated same-polarity literals are
/// collapsed. Preserves first-occurrence order of variables.
pub fn normalize_clause(clause: &Clause) -> NormalizedClause {
    let mut seen: Vec<(usize, bool)> = Vec::with_capacity(clause.lits.len());
    for lit in &clause.lits {
        if let Some(&(_, pos)) = seen.iter().find(|(v, _)| *v == lit.var) {
            if pos != lit.positive {
                return NormalizedClause::Tautology;
            }
            // same polarity: skip the duplicate
        } else {
            seen.push((lit.var, lit.positive));
        }
    }
    if seen.is_empty() {
        NormalizedClause::Empty
    } else {
        NormalizedClause::Lits(seen)
    }
}

impl Tdd {
    /// The canonical constant-`1` diagram: every leaf level `[One]`, every
    /// internal level a single node with input `{(0,0)}`.
    pub fn constant_true(vtree: &Vtree) -> Tdd {
        let mut levels = vec![Level::Leaf(Vec::new()); vtree.num_nodes()];
        for (vid, lvl) in levels.iter_mut().enumerate() {
            *lvl = if vtree.node(vid).is_leaf() {
                Level::Leaf(vec![LeafLabel::One])
            } else {
                Level::Internal(vec![vec![(0, 0)].into_boxed_slice()])
            };
        }
        Tdd { levels }
    }

    /// Build the width-≤2 diagram for a single non-empty, non-tautological
    /// clause given as `(variable, positive)` literals (≤1 per variable), per
    /// paper §6. Each vtree node carries `d_t = (¬c)|X_t` (always) and
    /// `c_t = c|X_t` (iff the clause touches `X_t`); the root emits only `c_t`.
    pub fn clause(vtree: &Vtree, lits: &[(usize, bool)]) -> Tdd {
        assert!(!lits.is_empty(), "clause() needs a non-empty clause");
        let n = vtree.num_nodes();
        let root = vtree.root();
        let mut levels: Vec<Level> = vec![Level::Leaf(Vec::new()); n];
        // Per vtree node: (NId of c_t, NId of d_t), either possibly absent.
        let mut cd: Vec<(Option<NId>, Option<NId>)> = vec![(None, None); n];

        for vid in vtree.postorder() {
            let node = vtree.node(vid);
            if let Some(x) = node.var {
                // Leaf.
                match lits.iter().find(|(v, _)| *v == x) {
                    Some(&(_, positive)) => {
                        // c_t is the literal; d_t is its negation.
                        let (c_label, d_label) = if positive {
                            (LeafLabel::Pos, LeafLabel::Neg)
                        } else {
                            (LeafLabel::Neg, LeafLabel::Pos)
                        };
                        levels[vid] = Level::Leaf(vec![c_label, d_label]);
                        cd[vid] = (Some(0), Some(1));
                    }
                    None => {
                        // Variable outside the clause: c_t = 0 (absent), d_t = 1.
                        levels[vid] = Level::Leaf(vec![LeafLabel::One]);
                        cd[vid] = (None, Some(0));
                    }
                }
            } else {
                // Internal node.
                let (c1, d1) = cd[node.left.unwrap()];
                let (c2, d2) = cd[node.right.unwrap()];
                let d1 = d1.expect("d_t exists at every node");
                let d2 = d2.expect("d_t exists at every node");

                // E(c_t): the existing pairs among (c1,c2), (c1,d2), (d1,c2).
                let mut c_pairs: Vec<(NId, NId)> = Vec::new();
                if let (Some(c1), Some(c2)) = (c1, c2) {
                    c_pairs.push((c1, c2));
                }
                if let Some(c1) = c1 {
                    c_pairs.push((c1, d2));
                }
                if let Some(c2) = c2 {
                    c_pairs.push((d1, c2));
                }
                let c_exists = c1.is_some() || c2.is_some();

                let mut nodes: Vec<Box<[(NId, NId)]>> = Vec::with_capacity(2);
                let mut c_nid = None;
                let mut d_nid = None;
                if c_exists {
                    c_pairs.sort_unstable();
                    c_pairs.dedup();
                    c_nid = Some(nodes.len() as NId);
                    nodes.push(c_pairs.into_boxed_slice());
                }
                // The root's d-node is the output's complement — never referenced
                // upward, so drop it; keep it at every other node.
                if vid != root {
                    d_nid = Some(nodes.len() as NId);
                    nodes.push(vec![(d1, d2)].into_boxed_slice());
                }
                levels[vid] = Level::Internal(nodes);
                cd[vid] = (c_nid, d_nid);
            }
        }
        Tdd { levels }
    }

    /// Evaluate the represented function at `assignment` (indexed by variable id)
    /// into a caller-provided selection buffer (length `>= levels.len()`), given
    /// the vtree's postorder — both caller-provided to avoid per-call allocation
    /// in the `2^n` loop.
    fn eval_into(
        &self,
        vtree: &Vtree,
        postorder: &[usize],
        assignment: &[bool],
        sel: &mut [Option<NId>],
    ) -> bool {
        for &vid in postorder {
            let node = vtree.node(vid);
            sel[vid] = match &self.levels[vid] {
                Level::Leaf(labels) => {
                    let value = assignment[node.var.unwrap()];
                    labels
                        .iter()
                        .position(|l| l.satisfied_by(value))
                        .map(|i| i as NId)
                }
                Level::Internal(nodes) => {
                    match (sel[node.left.unwrap()], sel[node.right.unwrap()]) {
                        (Some(a), Some(b)) => nodes
                            .iter()
                            .position(|pairs| pairs.binary_search(&(a, b)).is_ok())
                            .map(|i| i as NId),
                        _ => None,
                    }
                }
            };
        }
        // A model iff the output node (node 0 of the root level) is selected.
        sel[vtree.root()] == Some(0)
    }

    /// Evaluate the represented function at `assignment` (indexed by variable
    /// id; length `>= vtree.var_space()`).
    pub fn eval(&self, vtree: &Vtree, assignment: &[bool]) -> bool {
        let mut sel = vec![None; self.levels.len()];
        self.eval_into(vtree, &vtree.postorder(), assignment, &mut sel)
    }

    /// Materialize the represented Boolean function as a truth table over `2^n`
    /// assignments (vtree leaf order) — the differential-testing oracle.
    pub fn to_truth_table(&self, vtree: &Vtree) -> Vec<bool> {
        let n = vtree.n_vars();
        let post = vtree.postorder();
        let mut a = vec![false; vtree.var_space()];
        let mut sel = vec![None; self.levels.len()];
        let mut out = Vec::with_capacity(1usize << n);
        for idx in 0..(1usize << n) {
            index_to_assignment_into(idx, vtree, &mut a);
            out.push(self.eval_into(vtree, &post, &a, &mut sel));
        }
        out
    }

    /// Per-vtree-node width `|N_t|` (indexed by vtree-node id). After
    /// `minimize` this equals the factor width `S_t`.
    pub fn widths(&self) -> Vec<usize> {
        self.levels.iter().map(Level::len).collect()
    }

    /// Maximum width over all vtree nodes.
    pub fn width(&self) -> usize {
        self.levels.iter().map(Level::len).max().unwrap_or(0)
    }

    /// Total size `Σ_g |E(g)|` (leaves contribute 0, matching the paper).
    pub fn size(&self) -> usize {
        self.levels
            .iter()
            .map(|lvl| match lvl {
                Level::Leaf(_) => 0,
                Level::Internal(nodes) => nodes.iter().map(|p| p.len()).sum(),
            })
            .sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cnf::Lit;
    use crate::instances::random_kcnf;
    use crate::rng::Rng;
    use crate::truthtable::clause_truth_table;
    use crate::vtree::Vtree;

    fn lits(clause: &Clause) -> Vec<(usize, bool)> {
        match normalize_clause(clause) {
            NormalizedClause::Lits(v) => v,
            other => panic!("expected non-trivial clause, got {other:?}"),
        }
    }

    #[test]
    fn constant_true_is_all_true() {
        for vtree in [Vtree::right_linear(4), Vtree::balanced(5)] {
            let t = Tdd::constant_true(&vtree);
            assert!(t.to_truth_table(&vtree).iter().all(|&b| b));
        }
    }

    #[test]
    fn clause_computes_its_function() {
        let mut rng = Rng::new(20260707);
        for _ in 0..200 {
            let n = 2 + rng.below(6); // 2..=7
            let k = 1 + rng.below(n.min(4));
            // one random clause
            let cnf = random_kcnf(n, 1, k, &mut rng);
            let clause = &cnf.clauses[0];
            let ls = lits(clause);
            for vtree in [
                Vtree::right_linear(n),
                Vtree::balanced(n),
                Vtree::random(n, &mut rng),
            ] {
                let t = Tdd::clause(&vtree, &ls);
                assert_eq!(
                    t.to_truth_table(&vtree),
                    clause_truth_table(clause, &vtree),
                    "clause {clause:?} on a vtree over {n} vars"
                );
                // Raw clause diagram has width ≤ 2 everywhere (paper §6).
                assert!(t.width() <= 2, "clause width {} > 2", t.width());
            }
        }
    }

    #[test]
    fn single_variable_clause() {
        // n = 1: the vtree root is a leaf.
        let vtree = Vtree::right_linear(1);
        for positive in [true, false] {
            let t = Tdd::clause(&vtree, &[(0, positive)]);
            let tt = t.to_truth_table(&vtree);
            // (x0) is [false, true]; (¬x0) is [true, false] in leaf order.
            assert_eq!(tt, vec![!positive, positive]);
        }
    }

    #[test]
    fn normalize_dedup_and_tautology() {
        // duplicate same-polarity literal collapses
        let c = Clause::new(vec![Lit::positive(0), Lit::positive(0), Lit::negative(1)]);
        assert_eq!(
            normalize_clause(&c),
            NormalizedClause::Lits(vec![(0, true), (1, false)])
        );
        // opposite polarities ⇒ tautology
        let c = Clause::new(vec![Lit::positive(0), Lit::negative(0)]);
        assert_eq!(normalize_clause(&c), NormalizedClause::Tautology);
        // empty clause
        assert_eq!(
            normalize_clause(&Clause::new(vec![])),
            NormalizedClause::Empty
        );
    }

    #[test]
    fn unit_clause_matches_oracle_all_vtrees() {
        // A unit clause (x2) on several vtrees.
        let n = 5;
        let mut rng = Rng::new(7);
        for vtree in [
            Vtree::right_linear(n),
            Vtree::balanced(n),
            Vtree::random(n, &mut rng),
        ] {
            let t = Tdd::clause(&vtree, &[(2, true)]);
            let clause = Clause::new(vec![Lit::positive(2)]);
            assert_eq!(
                t.to_truth_table(&vtree),
                clause_truth_table(&clause, &vtree)
            );
        }
    }
}
