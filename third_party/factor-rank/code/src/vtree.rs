//! Variable trees (vtrees): rooted, ordered, binary trees whose leaves are in
//! bijection with the variables. Stored as an arena of nodes.
//!
//! Each node is annotated with `vars` (the variables at leaves below it, in
//! left-to-right leaf order), `off` (the number of variables preceding this
//! subtree in the global leaf order), and parent/`is_left` links. Because the
//! leaf order places a subtree's variables in the contiguous block
//! `[off, off + nv)`, the cut of the variable set at any node is a contiguous
//! split of the leaf order — which the cut-matrix construction relies on.

use crate::cnf::Cnf;
use crate::rng::Rng;

/// A single vtree node in the arena.
#[derive(Clone, Debug)]
pub struct VtreeNode {
    /// `Some(v)` for a leaf labeled by variable `v`; `None` for an internal node.
    pub var: Option<usize>,
    /// Child arena indices (internal nodes only).
    pub left: Option<usize>,
    pub right: Option<usize>,
    /// Parent arena index (`None` at the root).
    pub parent: Option<usize>,
    /// Whether this node is the left child of its parent (irrelevant at root).
    pub is_left: bool,
    /// Variables below this node, in leaf order.
    pub vars: Vec<usize>,
    /// Number of variables preceding this subtree in the global leaf order.
    pub off: usize,
}

impl VtreeNode {
    pub fn is_leaf(&self) -> bool {
        self.var.is_some()
    }

    /// Number of variables below this node.
    pub fn nv(&self) -> usize {
        self.vars.len()
    }
}

/// A vtree: an arena of nodes with a designated root.
#[derive(Clone, Debug)]
pub struct Vtree {
    nodes: Vec<VtreeNode>,
    root: usize,
    n_vars: usize,
}

impl Vtree {
    pub fn node(&self, id: usize) -> &VtreeNode {
        &self.nodes[id]
    }

    pub fn root(&self) -> usize {
        self.root
    }

    pub fn n_vars(&self) -> usize {
        self.n_vars
    }

    pub fn num_nodes(&self) -> usize {
        self.nodes.len()
    }

    /// The variables in leaf (left-to-right) order.
    pub fn leaf_order(&self) -> &[usize] {
        &self.nodes[self.root].vars
    }

    /// Size of the variable-id space: max variable id + 1. Assignment
    /// buffers indexed by variable id must have this length — on an
    /// *induced* vtree (`without_var`) it exceeds `n_vars()` because the
    /// surviving leaves keep their original ids.
    pub fn var_space(&self) -> usize {
        self.leaf_order().iter().max().map_or(0, |&v| v + 1)
    }

    /// Node indices in post-order (children before parents). Iterative to stay
    /// safe on deep (e.g. right-linear) vtrees; the backends call this heavily.
    pub fn postorder(&self) -> Vec<usize> {
        // Post-order = reverse of a (root, right, left) traversal.
        let mut out = Vec::with_capacity(self.nodes.len());
        let mut stack = vec![self.root];
        while let Some(id) = stack.pop() {
            out.push(id);
            let n = &self.nodes[id];
            if let (Some(l), Some(r)) = (n.left, n.right) {
                stack.push(l);
                stack.push(r);
            }
        }
        out.reverse();
        out
    }

    /// Node indices in pre-order (parents before children). Iterative.
    pub fn preorder(&self) -> Vec<usize> {
        let mut out = Vec::with_capacity(self.nodes.len());
        let mut stack = vec![self.root];
        while let Some(id) = stack.pop() {
            out.push(id);
            let n = &self.nodes[id];
            if let (Some(l), Some(r)) = (n.left, n.right) {
                stack.push(r);
                stack.push(l);
            }
        }
        out
    }

    /// Leaf node indices (in leaf order).
    pub fn leaves(&self) -> Vec<usize> {
        self.postorder()
            .into_iter()
            .filter(|&i| self.nodes[i].is_leaf())
            .collect()
    }

    /// Right-linear ("right comb") vtree over variables `0..n`, i.e. the OBDD
    /// order `0, 1, …, n-1`.
    pub fn right_linear(n: usize) -> Vtree {
        let order: Vec<usize> = (0..n).collect();
        Vtree::right_linear_order(&order)
    }

    /// Right-linear vtree over an explicit variable order.
    pub fn right_linear_order(order: &[usize]) -> Vtree {
        assert!(!order.is_empty(), "vtree needs at least one variable");
        let mut b = Builder::new(order.len());
        let root = b.right_linear(order);
        b.finish(root)
    }

    /// Balanced vtree over variables `0..n` (recursive half split).
    pub fn balanced(n: usize) -> Vtree {
        let order: Vec<usize> = (0..n).collect();
        Vtree::balanced_order(&order)
    }

    /// Balanced vtree over an explicit variable order.
    pub fn balanced_order(order: &[usize]) -> Vtree {
        assert!(!order.is_empty(), "vtree needs at least one variable");
        let mut b = Builder::new(order.len());
        let root = b.balanced(order);
        b.finish(root)
    }

    /// Random vtree over an explicit variable order (matches
    /// `atdd_toy.random_vtree`: split at a uniform point in `1..len`).
    pub fn random_order(order: &[usize], rng: &mut Rng) -> Vtree {
        assert!(!order.is_empty(), "vtree needs at least one variable");
        let mut b = Builder::new(order.len());
        let root = b.random(order, rng);
        b.finish(root)
    }

    /// Random vtree over variables `0..n`.
    pub fn random(n: usize, rng: &mut Rng) -> Vtree {
        let order: Vec<usize> = (0..n).collect();
        Vtree::random_order(&order, rng)
    }

    /// A two-block vtree: `root(balanced(left), balanced(right))`. Used for
    /// the MUX data vtree (`FABLE_NOTES/04` §3, treatment `mux_data`), which
    /// guarantees a node with `X_t = {data variables}` where the sandwich is
    /// tight (`S_t = 2^{ρ_t} − 1`).
    pub fn balanced_pair(left: &[usize], right: &[usize]) -> Vtree {
        assert!(!left.is_empty() && !right.is_empty());
        let mut b = Builder::new(left.len() + right.len());
        let l = b.balanced(left);
        let r = b.balanced(right);
        let root = b.internal(l, r);
        b.finish(root)
    }

    /// The MUX_k data vtree: addresses `0..k` balanced on the left, data
    /// variables `k..k+2^k` balanced on the right.
    pub fn mux_data(k: usize) -> Vtree {
        let addr: Vec<usize> = (0..k).collect();
        let data: Vec<usize> = (k..k + (1 << k)).collect();
        Vtree::balanced_pair(&addr, &data)
    }

    /// The induced vtree with variable `x` removed: the leaf of `x` is
    /// deleted and its parent contracted to the sibling (toy
    /// `clone_without`). Returns the new vtree and the old→new node-id map
    /// (`None` for the removed leaf and the contracted parent). Requires at
    /// least two variables (removing the last leaf leaves no tree).
    pub fn without_var(&self, x: usize) -> (Vtree, Vec<Option<usize>>) {
        assert!(self.n_vars >= 2, "cannot remove the only variable");
        assert!(
            self.leaf_order().contains(&x),
            "without_var: {x} is not a variable of this vtree"
        );
        let mut b = Builder::new(self.n_vars - 1);
        let mut mapping: Vec<Option<usize>> = vec![None; self.nodes.len()];
        let root = self
            .clone_without(self.root, x, &mut b, &mut mapping)
            .expect("n >= 2: removing one leaf keeps the tree nonempty");
        (b.finish(root), mapping)
    }

    fn clone_without(
        &self,
        id: usize,
        x: usize,
        b: &mut Builder,
        mapping: &mut Vec<Option<usize>>,
    ) -> Option<usize> {
        let node = &self.nodes[id];
        if let Some(v) = node.var {
            if v == x {
                return None;
            }
            let nid = b.leaf(v);
            mapping[id] = Some(nid);
            return Some(nid);
        }
        let nl = self.clone_without(node.left.unwrap(), x, b, mapping);
        let nr = self.clone_without(node.right.unwrap(), x, b, mapping);
        match (nl, nr) {
            (Some(l), Some(r)) => {
                let nid = b.internal(l, r);
                mapping[id] = Some(nid);
                Some(nid)
            }
            // Contracted: this node's position is taken by the surviving
            // child; the node itself has no image.
            (Some(l), None) => Some(l),
            (None, Some(r)) => Some(r),
            (None, None) => unreachable!("both children lost a single leaf"),
        }
    }

    // --- Vtree rotations (M7 / FABLE_NOTES/05, rotation_alg_toy.py) ---------
    //
    // Rotations are the SDD-style local vtree moves. A **left rotation** at an
    // internal node `v = (a, w)` with internal right child `w = (b, c)`
    // replaces the subtree by `v' = (m, c)` with a new node `m = (a, b)`; the
    // subtrees `a, b, c` and everything outside `v`'s subtree are untouched.
    // The **right rotation** is the inverse: `v = (q, c)` with internal left
    // child `q = (a, b)` ↦ `(a, (b, c))`. A **swap** exchanges a node's two
    // children. All three preserve the in-order leaf sequence (Prop 0(ii)), so
    // every preserved node keeps its `(off, nv)` block — the caller re-maps
    // node data by that block (see `atdd::rotate`).

    /// Is `v` a legal left-rotation site: internal with an internal right child?
    pub fn is_left_rotatable(&self, v: usize) -> bool {
        let n = &self.nodes[v];
        !n.is_leaf() && n.right.is_some_and(|r| !self.nodes[r].is_leaf())
    }

    /// Is `v` a legal right-rotation site: internal with an internal left child?
    pub fn is_right_rotatable(&self, v: usize) -> bool {
        let n = &self.nodes[v];
        !n.is_leaf() && n.left.is_some_and(|l| !self.nodes[l].is_leaf())
    }

    /// Left rotation at `v`: `v = (a, w), w = (b, c)` ↦ `v' = (m, c), m = (a, b)`.
    /// Returns a fresh vtree with the same leaf order (Prop 0(ii)).
    pub fn left_rotate(&self, v: usize) -> Vtree {
        assert!(
            self.is_left_rotatable(v),
            "left_rotate: v needs an internal right child"
        );
        let mut b = Builder::new(self.n_vars);
        let root = self.emit_rotate(self.root, v, Rot::Left, &mut b);
        b.finish(root)
    }

    /// Right rotation at `v`: `v = (q, c), q = (a, b)` ↦ `v' = (a, w2), w2 = (b, c)`.
    /// Inverse of a left rotation; a fresh vtree with the same leaf order.
    pub fn right_rotate(&self, v: usize) -> Vtree {
        assert!(
            self.is_right_rotatable(v),
            "right_rotate: v needs an internal left child"
        );
        let mut b = Builder::new(self.n_vars);
        let root = self.emit_rotate(self.root, v, Rot::Right, &mut b);
        b.finish(root)
    }

    /// Swap the two children of internal node `v` (an ordered-tree move). The
    /// leaf order *does* change here, unlike rotations — a fresh vtree.
    pub fn swap(&self, v: usize) -> Vtree {
        assert!(!self.nodes[v].is_leaf(), "swap: v must be internal");
        let mut b = Builder::new(self.n_vars);
        let root = self.emit_swap(self.root, v, &mut b);
        b.finish(root)
    }

    /// Clone the subtree rooted at `id` verbatim into the builder.
    fn emit_clone(&self, id: usize, b: &mut Builder) -> usize {
        let node = &self.nodes[id];
        if let Some(v) = node.var {
            b.leaf(v)
        } else {
            let l = self.emit_clone(node.left.unwrap(), b);
            let r = self.emit_clone(node.right.unwrap(), b);
            b.internal(l, r)
        }
    }

    /// Clone into the builder, applying the rotation once when `id == v`.
    fn emit_rotate(&self, id: usize, v: usize, rot: Rot, b: &mut Builder) -> usize {
        let node = &self.nodes[id];
        if id == v {
            return match rot {
                Rot::Left => {
                    // v = (a, w), w = (b, c) ↦ ((a, b), c)
                    let w = &self.nodes[node.right.unwrap()];
                    let a = self.emit_clone(node.left.unwrap(), b);
                    let bb = self.emit_clone(w.left.unwrap(), b);
                    let c = self.emit_clone(w.right.unwrap(), b);
                    let m = b.internal(a, bb);
                    b.internal(m, c)
                }
                Rot::Right => {
                    // v = (q, c), q = (a, b) ↦ (a, (b, c))
                    let q = &self.nodes[node.left.unwrap()];
                    let a = self.emit_clone(q.left.unwrap(), b);
                    let bb = self.emit_clone(q.right.unwrap(), b);
                    let c = self.emit_clone(node.right.unwrap(), b);
                    let w2 = b.internal(bb, c);
                    b.internal(a, w2)
                }
            };
        }
        if let Some(var) = node.var {
            b.leaf(var)
        } else {
            let l = self.emit_rotate(node.left.unwrap(), v, rot, b);
            let r = self.emit_rotate(node.right.unwrap(), v, rot, b);
            b.internal(l, r)
        }
    }

    /// Clone into the builder, swapping the children of `v`.
    fn emit_swap(&self, id: usize, v: usize, b: &mut Builder) -> usize {
        let node = &self.nodes[id];
        if let Some(var) = node.var {
            return b.leaf(var);
        }
        let l = self.emit_swap(node.left.unwrap(), v, b);
        let r = self.emit_swap(node.right.unwrap(), v, b);
        if id == v {
            b.internal(r, l)
        } else {
            b.internal(l, r)
        }
    }
}

/// Rotation direction for [`Vtree::emit_rotate`].
#[derive(Clone, Copy)]
enum Rot {
    Left,
    Right,
}

/// Min-fill elimination order on the CNF's primal graph (`FABLE_NOTES/04`
/// §8.2): repeatedly eliminate the variable whose neighborhood needs the
/// fewest fill edges to become a clique (ties by lowest id), connecting its
/// neighbors. Feed the result to `right_linear_order`/`balanced_order`
/// (first-eliminated variable = leftmost leaf — a documented convention).
/// Deterministic; all fill-0 vertices (simplicial or isolated) tie-break by
/// lowest id.
pub fn min_fill_order(cnf: &Cnf) -> Vec<usize> {
    let n = cnf.n_vars;
    let mut adj = vec![vec![false; n]; n];
    for clause in &cnf.clauses {
        let vars: Vec<usize> = clause.vars().collect();
        for (i, &u) in vars.iter().enumerate() {
            for &w in &vars[i + 1..] {
                if u != w {
                    adj[u][w] = true;
                    adj[w][u] = true;
                }
            }
        }
    }
    let mut alive = vec![true; n];
    let mut order = Vec::with_capacity(n);
    for _ in 0..n {
        // Pick the alive vertex with minimum fill; ties by lowest id.
        let mut best: Option<(usize, usize)> = None; // (fill, v)
        for v in 0..n {
            if !alive[v] {
                continue;
            }
            let nbrs: Vec<usize> = (0..n).filter(|&u| alive[u] && adj[v][u]).collect();
            let mut fill = 0usize;
            for (i, &u) in nbrs.iter().enumerate() {
                for &w in &nbrs[i + 1..] {
                    if !adj[u][w] {
                        fill += 1;
                    }
                }
            }
            if best.is_none_or(|(bf, _)| fill < bf) {
                best = Some((fill, v));
            }
        }
        let (_, v) = best.expect("an alive vertex remains");
        // Eliminate v: clique its alive neighborhood.
        let nbrs: Vec<usize> = (0..n).filter(|&u| alive[u] && adj[v][u]).collect();
        for (i, &u) in nbrs.iter().enumerate() {
            for &w in &nbrs[i + 1..] {
                adj[u][w] = true;
                adj[w][u] = true;
            }
        }
        alive[v] = false;
        order.push(v);
    }
    order
}

/// Arena builder for vtrees; annotates after the tree shape is fixed.
struct Builder {
    nodes: Vec<VtreeNode>,
    n_vars: usize,
}

impl Builder {
    fn new(n_vars: usize) -> Self {
        Builder {
            nodes: Vec::new(),
            n_vars,
        }
    }

    fn leaf(&mut self, var: usize) -> usize {
        let id = self.nodes.len();
        self.nodes.push(VtreeNode {
            var: Some(var),
            left: None,
            right: None,
            parent: None,
            is_left: false,
            vars: Vec::new(),
            off: 0,
        });
        id
    }

    fn internal(&mut self, left: usize, right: usize) -> usize {
        let id = self.nodes.len();
        self.nodes.push(VtreeNode {
            var: None,
            left: Some(left),
            right: Some(right),
            parent: None,
            is_left: false,
            vars: Vec::new(),
            off: 0,
        });
        id
    }

    fn right_linear(&mut self, order: &[usize]) -> usize {
        if order.len() == 1 {
            return self.leaf(order[0]);
        }
        let l = self.leaf(order[0]);
        let r = self.right_linear(&order[1..]);
        self.internal(l, r)
    }

    fn balanced(&mut self, order: &[usize]) -> usize {
        if order.len() == 1 {
            return self.leaf(order[0]);
        }
        let k = order.len() / 2;
        let l = self.balanced(&order[..k]);
        let r = self.balanced(&order[k..]);
        self.internal(l, r)
    }

    fn random(&mut self, order: &[usize], rng: &mut Rng) -> usize {
        if order.len() == 1 {
            return self.leaf(order[0]);
        }
        // split point in 1..=len-1
        let k = 1 + rng.below(order.len() - 1);
        let l = self.random(&order[..k], rng);
        let r = self.random(&order[k..], rng);
        self.internal(l, r)
    }

    fn finish(mut self, root: usize) -> Vtree {
        self.annotate_vars(root);
        self.annotate_offsets(root, 0, None, false);
        Vtree {
            nodes: self.nodes,
            root,
            n_vars: self.n_vars,
        }
    }

    /// Post-order: fill `vars` bottom-up.
    fn annotate_vars(&mut self, id: usize) {
        let (l, r) = (self.nodes[id].left, self.nodes[id].right);
        if let (Some(l), Some(r)) = (l, r) {
            self.annotate_vars(l);
            self.annotate_vars(r);
            let mut vars = self.nodes[l].vars.clone();
            vars.extend_from_slice(&self.nodes[r].vars);
            self.nodes[id].vars = vars;
        } else {
            let v = self.nodes[id].var.expect("leaf has a variable");
            self.nodes[id].vars = vec![v];
        }
    }

    /// Pre-order: fill `off`, `parent`, `is_left`. Left child inherits the
    /// parent offset; right child is shifted by the left subtree's size.
    fn annotate_offsets(&mut self, id: usize, off: usize, parent: Option<usize>, is_left: bool) {
        self.nodes[id].off = off;
        self.nodes[id].parent = parent;
        self.nodes[id].is_left = is_left;
        let (l, r) = (self.nodes[id].left, self.nodes[id].right);
        if let (Some(l), Some(r)) = (l, r) {
            let left_nv = self.nodes[l].nv();
            self.annotate_offsets(l, off, Some(id), true);
            self.annotate_offsets(r, off + left_nv, Some(id), false);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn right_linear_shape() {
        let t = Vtree::right_linear(4);
        assert_eq!(t.n_vars(), 4);
        // n leaves + (n-1) internal = 2n-1 nodes
        assert_eq!(t.num_nodes(), 7);
        assert_eq!(t.leaf_order(), &[0, 1, 2, 3]);
        // root's left child is the leaf x0
        let root = t.node(t.root());
        assert!(root.left.is_some());
        assert_eq!(t.node(root.left.unwrap()).var, Some(0));
    }

    #[test]
    fn balanced_shape() {
        let t = Vtree::balanced(4);
        assert_eq!(t.num_nodes(), 7);
        assert_eq!(t.leaf_order(), &[0, 1, 2, 3]);
        // balanced over 4: root splits {0,1} | {2,3}
        let root = t.node(t.root());
        assert_eq!(t.node(root.left.unwrap()).vars, vec![0, 1]);
        assert_eq!(t.node(root.right.unwrap()).vars, vec![2, 3]);
    }

    #[test]
    fn offsets_are_contiguous() {
        // Every subtree occupies leaf_order[off .. off+nv].
        let t = Vtree::balanced(6);
        let order = t.leaf_order().to_vec();
        for id in t.postorder() {
            let n = t.node(id);
            assert_eq!(&order[n.off..n.off + n.nv()], n.vars.as_slice());
        }
    }

    #[test]
    fn single_variable() {
        let t = Vtree::right_linear(1);
        assert_eq!(t.num_nodes(), 1);
        assert!(t.node(t.root()).is_leaf());
    }

    #[test]
    fn min_fill_is_a_permutation_and_deterministic() {
        use crate::instances::{php, random_kcnf};
        let cnf = php(4, 3);
        let o1 = min_fill_order(&cnf);
        let o2 = min_fill_order(&cnf);
        assert_eq!(o1, o2, "deterministic");
        let mut sorted = o1.clone();
        sorted.sort_unstable();
        assert_eq!(sorted, (0..12).collect::<Vec<_>>(), "permutation");
        // Isolated variables are ordinary fill-0 candidates (lowest-id tie
        // break); the order must still be a full permutation including them.
        let mut rng = crate::rng::Rng::new(9);
        let mut cnf = random_kcnf(4, 3, 2, &mut rng);
        cnf.n_vars = 6; // vars 4, 5 isolated
        let o = min_fill_order(&cnf);
        let mut sorted = o.clone();
        sorted.sort_unstable();
        assert_eq!(sorted, (0..6).collect::<Vec<_>>());
        // A vtree built from the order is valid.
        let vt = Vtree::right_linear_order(&o);
        assert_eq!(vt.n_vars(), 6);
    }

    #[test]
    fn mux_data_vtree_has_the_data_node() {
        for k in [1usize, 2, 3] {
            let vt = Vtree::mux_data(k);
            assert_eq!(vt.n_vars(), k + (1 << k));
            let data: Vec<usize> = (k..k + (1 << k)).collect();
            let root = vt.node(vt.root());
            assert_eq!(vt.node(root.right.unwrap()).vars, data);
        }
    }

    fn cut_family(t: &Vtree) -> std::collections::BTreeSet<Vec<usize>> {
        t.postorder()
            .into_iter()
            .map(|id| {
                let mut v = t.node(id).vars.clone();
                v.sort_unstable();
                v
            })
            .collect()
    }

    #[test]
    fn left_rotation_structure_and_inverse() {
        // right_linear(4) = (0,(1,(2,3))). Left-rotate at w = {1,2,3}.
        let t = Vtree::right_linear(4);
        let w = t
            .postorder()
            .into_iter()
            .find(|&i| t.node(i).vars == vec![1, 2, 3])
            .unwrap();
        assert!(t.is_left_rotatable(w));
        let t2 = t.left_rotate(w);
        // Leaf order preserved (Prop 0(ii)); one cut destroyed, one created.
        assert_eq!(t2.leaf_order(), t.leaf_order());
        assert_eq!(t2.n_vars(), 4);
        assert_eq!(t2.num_nodes(), t.num_nodes());
        let (c0, c2) = (cut_family(&t), cut_family(&t2));
        // Exactly one cut differs each way.
        assert_eq!(c0.difference(&c2).count(), 1, "one cut destroyed");
        assert_eq!(c2.difference(&c0).count(), 1, "one cut created");
        // Created cut {1,2} = A∪B; destroyed {2,3} = B∪C.
        assert!(c2.contains(&vec![1, 2]) && !c0.contains(&vec![1, 2]));
        // The rotated node covers the same block; right-rotate it back.
        let vprime = t2
            .postorder()
            .into_iter()
            .find(|&i| !t2.node(i).is_leaf() && t2.node(i).vars == vec![1, 2, 3])
            .unwrap();
        assert!(t2.is_right_rotatable(vprime));
        let t3 = t2.right_rotate(vprime);
        assert_eq!(
            cut_family(&t3),
            cut_family(&t),
            "rotate∘unrotate restores cut family"
        );
    }

    #[test]
    fn swap_changes_leaf_order_not_cut_ranks() {
        let t = Vtree::balanced(4); // ((0,1),(2,3))
        let root = t.root();
        let t2 = t.swap(root); // ((2,3),(0,1))
        assert_eq!(t2.leaf_order(), &[2, 3, 0, 1], "swap reorders leaves");
        assert_eq!(t2.num_nodes(), t.num_nodes());
        // Swap at the root: the two child cuts are exchanged as sets.
        assert_eq!(
            cut_family(&t),
            cut_family(&t2),
            "swap preserves the cut family"
        );
    }

    #[test]
    fn random_is_valid_tree() {
        let mut rng = Rng::new(12345);
        for _ in 0..50 {
            let n = 1 + rng.below(8);
            let t = Vtree::random(n, &mut rng);
            assert_eq!(t.n_vars(), n);
            assert_eq!(t.num_nodes(), 2 * n - 1);
            // leaves cover 0..n exactly once
            let mut leaf_vars: Vec<usize> =
                t.leaves().iter().map(|&i| t.node(i).var.unwrap()).collect();
            leaf_vars.sort_unstable();
            assert_eq!(leaf_vars, (0..n).collect::<Vec<_>>());
            // parent/is_left consistency
            for id in t.postorder() {
                let node = t.node(id);
                if let Some(p) = node.parent {
                    let pn = t.node(p);
                    if node.is_left {
                        assert_eq!(pn.left, Some(id));
                    } else {
                        assert_eq!(pn.right, Some(id));
                    }
                }
            }
        }
    }
}
