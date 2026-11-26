//! Network-side contractions (`FABLE_NOTES/02` §2; toy 195–287): all
//! `O(poly(|A|))`, no `2^n` anywhere. These four recursions are the entire
//! query layer; `minimize` and `pivot_descent` are built from them.
//!
//! Everything is implemented iteratively over a subtree postorder (not by
//! call-stack recursion) so deep right-linear vtrees cannot overflow the
//! stack (spec §6.3 item 11).

use super::linalg::{Mat, Q};
use super::{Atdd, NodeData};
use crate::vtree::Vtree;
use num_traits::Zero;

/// A partial assignment: `set(v, b)` fixes variable `v`; unset variables are
/// summed over. Growable dense map (variables are small integers).
#[derive(Clone, Default, Debug)]
pub struct Partial(Vec<Option<bool>>);

impl Partial {
    pub fn get(&self, var: usize) -> Option<bool> {
        self.0.get(var).copied().flatten()
    }

    pub fn set(&mut self, var: usize, b: bool) {
        if self.0.len() <= var {
            self.0.resize(var + 1, None);
        }
        self.0[var] = Some(b);
    }
}

/// Postorder of the subtree rooted at `t` (children before parents).
pub(crate) fn subtree_postorder(vt: &Vtree, t: usize) -> Vec<usize> {
    // Reverse of a (node, right, left) traversal, like `Vtree::postorder`.
    let mut out = Vec::new();
    let mut stack = vec![t];
    while let Some(id) = stack.pop() {
        out.push(id);
        let n = vt.node(id);
        if let (Some(l), Some(r)) = (n.left, n.right) {
            stack.push(l);
            stack.push(r);
        }
    }
    out.reverse();
    out
}

/// The (conditioned) Gram matrix of the bond family at `t` (lem:gram):
/// `G[i][i'] = Σ_{τ ∈ 2^{X_t} consistent with partial} u_i(τ) · u_{i'}(τ)`.
///
/// `G` is PSD, and over ℚ `⟨v,v⟩ = 0 ⟹ v = 0` — the exactness on which every
/// zero test in minimize/canonicalize rests.
pub fn gram(a: &Atdd, vt: &Vtree, t: usize, partial: &Partial) -> Mat {
    let mut memo: Vec<Option<Mat>> = vec![None; vt.num_nodes()];
    for x in subtree_postorder(vt, t) {
        let node = vt.node(x);
        let g = match &a.node[x] {
            NodeData::Leaf(rows) => {
                let d = rows.r;
                let mut g = Mat::zero(d, d);
                match partial.get(node.var.unwrap()) {
                    Some(b) => {
                        let col = usize::from(b);
                        for i in 0..d {
                            for j in 0..d {
                                *g.at_mut(i, j) = rows.at(i, col) * rows.at(j, col);
                            }
                        }
                    }
                    None => {
                        for i in 0..d {
                            for j in 0..d {
                                *g.at_mut(i, j) =
                                    rows.at(i, 0) * rows.at(j, 0) + rows.at(i, 1) * rows.at(j, 1);
                            }
                        }
                    }
                }
                g
            }
            NodeData::Internal(w) => {
                let g1 = memo[node.left.unwrap()].as_ref().unwrap();
                let g2 = memo[node.right.unwrap()].as_ref().unwrap();
                let d = w.len();
                // B_i = G1 · W_i · G2; then G[i][i'] = ⟨W_{i'}, B_i⟩_F.
                let bs: Vec<Mat> = w.iter().map(|wi| g1.mul(wi).mul(g2)).collect();
                let mut g = Mat::zero(d, d);
                for (i, bi) in bs.iter().enumerate() {
                    for (ip, wip) in w.iter().enumerate().skip(i) {
                        let s = wip.frob(bi);
                        *g.at_mut(ip, i) = s.clone();
                        *g.at_mut(i, ip) = s;
                    }
                }
                g
            }
        };
        memo[x] = Some(g);
    }
    memo[t].take().unwrap()
}

/// Cross inner products of two ATDDs on the SAME vtree (toy `cross_inner`):
/// `X[i][j] = ⟨u^{A,t}_i, u^{B,t}_j⟩`, shape `d_A(t) × d_B(t)`.
pub fn cross_inner(a: &Atdd, b: &Atdd, vt: &Vtree, t: usize) -> Mat {
    let mut memo: Vec<Option<Mat>> = vec![None; vt.num_nodes()];
    for x in subtree_postorder(vt, t) {
        let node = vt.node(x);
        let m = match (&a.node[x], &b.node[x]) {
            (NodeData::Leaf(la), NodeData::Leaf(lb)) => Mat::from_fn(la.r, lb.r, |i, j| {
                la.at(i, 0) * lb.at(j, 0) + la.at(i, 1) * lb.at(j, 1)
            }),
            (NodeData::Internal(wa), NodeData::Internal(wb)) => {
                let x1 = memo[node.left.unwrap()].as_ref().unwrap();
                let x2 = memo[node.right.unwrap()].as_ref().unwrap();
                let x1t = x1.transpose();
                let mut out = Mat::zero(wa.len(), wb.len());
                for (i, wai) in wa.iter().enumerate() {
                    let y = x1t.mul(wai).mul(x2); // d_B(t1) × d_B(t2)
                    for (j, wbj) in wb.iter().enumerate() {
                        *out.at_mut(i, j) = wbj.frob(&y);
                    }
                }
                out
            }
            _ => unreachable!("A and B disagree on leaf/internal at node {x}"),
        };
        memo[x] = Some(m);
    }
    memo[t].take().unwrap()
}

/// `out[i] = u^t_i(assign)`; `assign` must fix all of `vars(t)`.
pub fn point_eval(a: &Atdd, vt: &Vtree, t: usize, assign: &Partial) -> Vec<Q> {
    let mut memo: Vec<Option<Vec<Q>>> = vec![None; vt.num_nodes()];
    for x in subtree_postorder(vt, t) {
        let node = vt.node(x);
        let e = match &a.node[x] {
            NodeData::Leaf(rows) => {
                let b = assign
                    .get(node.var.unwrap())
                    .expect("point_eval: assignment must fix all of vars(t)");
                (0..rows.r)
                    .map(|i| rows.at(i, usize::from(b)).clone())
                    .collect()
            }
            NodeData::Internal(w) => {
                let e1 = memo[node.left.unwrap()].as_ref().unwrap();
                let e2 = memo[node.right.unwrap()].as_ref().unwrap();
                w.iter().map(|wi| bilinear(e1, wi, e2)).collect()
            }
        };
        memo[x] = Some(e);
    }
    memo[t].take().unwrap()
}

/// `s[i] = Σ_τ u^t_i(τ)` — contraction with weight vector `(1,1)` at every
/// leaf (toy `ones_contract`).
pub fn ones_contract(a: &Atdd, vt: &Vtree, t: usize) -> Vec<Q> {
    let mut memo: Vec<Option<Vec<Q>>> = vec![None; vt.num_nodes()];
    for x in subtree_postorder(vt, t) {
        let node = vt.node(x);
        let s = match &a.node[x] {
            NodeData::Leaf(rows) => (0..rows.r).map(|i| rows.at(i, 0) + rows.at(i, 1)).collect(),
            NodeData::Internal(w) => {
                let s1 = memo[node.left.unwrap()].as_ref().unwrap();
                let s2 = memo[node.right.unwrap()].as_ref().unwrap();
                w.iter().map(|wi| bilinear(s1, wi, s2)).collect()
            }
        };
        memo[x] = Some(s);
    }
    memo[t].take().unwrap()
}

/// `e1ᵀ · W · e2`, zero-skipped.
fn bilinear(e1: &[Q], w: &Mat, e2: &[Q]) -> Q {
    let mut s = Q::zero();
    for (j, x) in e1.iter().enumerate() {
        if x.is_zero() {
            continue;
        }
        for (k, y) in e2.iter().enumerate() {
            if !y.is_zero() && !w.at(j, k).is_zero() {
                s += x * w.at(j, k) * y;
            }
        }
    }
    s
}

/// Exact model count `Σ_τ f(τ)` via ones-contraction (thm:queries(i)).
pub fn model_count(a: &Atdd, vt: &Vtree) -> Q {
    ones_contract(a, vt, vt.root()).swap_remove(0)
}

/// `f == g` via `Σ(f-g)² = ⟨f,f⟩ - 2⟨f,g⟩ + ⟨g,g⟩ == 0` (thm:queries(ii)).
pub fn equal_funcs(a: &Atdd, b: &Atdd, vt: &Vtree) -> bool {
    let root = vt.root();
    let aa = cross_inner(a, a, vt, root);
    let ab = cross_inner(a, b, vt, root);
    let bb = cross_inner(b, b, vt, root);
    (aa.at(0, 0) - super::linalg::q(2) * ab.at(0, 0) + bb.at(0, 0)).is_zero()
}
