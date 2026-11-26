//! ATDD backend: algebraic tree decision diagrams — a ℚ-weighted multiplicity
//! tree automaton over the vtree (`reference/atdd_proofs.tex` def:atdd).
//!
//! Authoritative implementation spec: `FABLE_NOTES/02_atdd_backend_spec.md`,
//! a line-by-line-verified port plan of `reference/atdd_toy.py`. Layout: per
//! vtree node `t`, a bond family of `d(t)` functions `u^t_i : 2^{X_t} → ℚ`.
//! A leaf stores a `d×2` matrix (row `i` = `[u_i(x=0), u_i(x=1)]`); an
//! internal node stores `d(t)` slices `W_i ∈ ℚ^{d(t1)×d(t2)}` with
//! `u^t_i = Σ_{j,k} W_i[j][k] · u^{t1}_j ⊗ u^{t2}_k`. The represented
//! function is `f = u^root_0`; canonical width at `t` is the factor rank
//! `ρ_t = rank M_t(f)`.

use crate::vtree::Vtree;
use linalg::{Mat, Q};
use num_traits::Zero;

pub mod canonical;
pub mod combine;
pub mod contract;
pub mod intcount;
pub mod interchange;
pub mod linalg;
pub mod minimize;
pub mod ops;
pub mod oracle;
pub mod pipeline;
pub mod rotate;
pub mod shadow;
pub mod vtree_change;

/// The bond data at one vtree node.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum NodeData {
    /// `d × 2`: row `i` is `[u_i(x=0), u_i(x=1)]`.
    Leaf(Mat),
    /// `d` slices, each `d(t1) × d(t2)`.
    Internal(Vec<Mat>),
}

/// An ATDD over a vtree: one `NodeData` per vtree node, indexed by vtree-node
/// id (same arena ids as the `Vtree`). The represented function is bond `0`
/// at the root.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Atdd {
    pub node: Vec<NodeData>,
}

impl Atdd {
    /// Bond dimension `d(t)` at vtree node `t`.
    pub fn dim(&self, t: usize) -> usize {
        match &self.node[t] {
            NodeData::Leaf(m) => m.r,
            NodeData::Internal(w) => w.len(),
        }
    }

    /// Size per def:atdd: `Σ_internal d·d1·d2 + Σ_leaf 2·d` (rational
    /// entries). No vtree needed — mirrors `Tdd::size()`.
    pub fn size(&self) -> usize {
        self.node
            .iter()
            .map(|nd| match nd {
                NodeData::Leaf(m) => 2 * m.r,
                NodeData::Internal(w) => w.iter().map(|wi| wi.r * wi.c).sum(),
            })
            .sum()
    }

    /// Per-node bond dimensions (indexed by vtree-node id). After `minimize`
    /// this is `ρ_t = rank M_t(f)` at every node — the factor-rank statistic.
    pub fn dims(&self) -> Vec<usize> {
        (0..self.node.len()).map(|t| self.dim(t)).collect()
    }

    /// Maximum bond dimension (the ATDD width statistic; after `minimize` this
    /// is the factor rank `fr(f, T) = max_t ρ_t`).
    pub fn width(&self) -> usize {
        (0..self.node.len()).map(|t| self.dim(t)).max().unwrap_or(0)
    }

    /// Exact model count `Σ_τ f(τ)` (thm:queries(i)) — method form mirroring
    /// `Tdd::model_count`; delegates to [`contract::model_count`].
    pub fn model_count(&self, vt: &Vtree) -> Q {
        contract::model_count(self, vt)
    }

    /// Structural invariants (spec §0.4): root has `d = 1`; every internal
    /// slice at `t` has shape `d(t1) × d(t2)`; leaves have 2 columns. Run in
    /// tests after every mutation. Shapes are read from the children's `dim`,
    /// never from `slices[0]`, so zero dimensions are harmless.
    pub fn check(&self, vt: &Vtree) -> Result<(), String> {
        if self.node.len() != vt.num_nodes() {
            return Err(format!(
                "node count {} != vtree size {}",
                self.node.len(),
                vt.num_nodes()
            ));
        }
        if self.dim(vt.root()) != 1 {
            return Err(format!("d(root) = {} != 1", self.dim(vt.root())));
        }
        for t in vt.postorder() {
            let node = vt.node(t);
            match (&self.node[t], node.is_leaf()) {
                (NodeData::Leaf(m), true) => {
                    if m.c != 2 {
                        return Err(format!("leaf {t}: {} columns != 2", m.c));
                    }
                }
                (NodeData::Internal(w), false) => {
                    let (d1, d2) = (self.dim(node.left.unwrap()), self.dim(node.right.unwrap()));
                    for (i, wi) in w.iter().enumerate() {
                        if (wi.r, wi.c) != (d1, d2) {
                            return Err(format!(
                                "internal {t} slice {i}: shape {}x{} != {d1}x{d2}",
                                wi.r, wi.c
                            ));
                        }
                    }
                }
                _ => return Err(format!("node {t}: leaf/internal kind mismatch")),
            }
        }
        Ok(())
    }

    /// Is the represented function identically zero? Detected exactly via
    /// `⟨f,f⟩ == 0` (spec §0.4) — over ℚ this is equivalent to `f ≡ 0`.
    /// Must be checked *before* `minimize`/`canonicalize` (their theory
    /// assumes `f ≢ 0`). Runs the root Gram over the integer shadow (the scaled
    /// `σ·⟨f,f⟩` is zero iff `⟨f,f⟩` is), so this per-clause check no longer
    /// pays the `Ratio<BigInt>` tax on the wide post-Hadamard diagram.
    pub fn is_zero_function(&self, vt: &Vtree) -> bool {
        shadow::Shadow::build(self, vt)
            .gram_scaled_q(vt, vt.root(), &contract::Partial::default())
            .at(0, 0)
            .is_zero()
    }
}

/// Compilation outcome: the diagram, or the unsatisfiable verdict for which
/// no canonical ATDD exists (the canonical form is undefined for `f ≡ 0`).
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum CompiledAtdd {
    Unsat,
    Atdd(Atdd),
}

/// Explicit truth tables of the bond functions at `t` (toy `vecs`) — the
/// exponential brute-force semantics, test/oracle use only.
pub fn bond_vectors(a: &Atdd, vt: &Vtree, t: usize) -> Vec<Vec<Q>> {
    debug_assert!(vt.n_vars() <= 24, "bond_vectors is exponential (2^n)");
    let node = vt.node(t);
    match &a.node[t] {
        NodeData::Leaf(m) => (0..m.r).map(|i| m.row(i).to_vec()).collect(),
        NodeData::Internal(w) => {
            let (l, r) = (node.left.unwrap(), node.right.unwrap());
            let u1 = bond_vectors(a, vt, l);
            let u2 = bond_vectors(a, vt, r);
            let n2 = 1usize << vt.node(r).nv();
            let len = 1usize << node.nv();
            w.iter()
                .map(|wi| {
                    let mut v = vec![Q::zero(); len];
                    for (j, uj) in u1.iter().enumerate() {
                        for (k, uk) in u2.iter().enumerate() {
                            let c = wi.at(j, k);
                            if c.is_zero() {
                                continue;
                            }
                            for (ia, x) in uj.iter().enumerate() {
                                if x.is_zero() {
                                    continue;
                                }
                                let cx = c * x;
                                let base = ia * n2;
                                for (ib, y) in uk.iter().enumerate() {
                                    if !y.is_zero() {
                                        v[base + ib] += &cx * y;
                                    }
                                }
                            }
                        }
                    }
                    v
                })
                .collect()
        }
    }
}

/// The represented function as a `2^n` truth-table of rationals (toy `func`).
/// Exponential; test/oracle use only.
pub fn func(a: &Atdd, vt: &Vtree) -> Vec<Q> {
    bond_vectors(a, vt, vt.root()).swap_remove(0)
}
