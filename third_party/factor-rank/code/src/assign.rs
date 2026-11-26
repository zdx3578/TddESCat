//! Conversions between assignments and their integer indices.
//!
//! A full assignment is a `Vec<bool>` indexed by variable id. Indices are
//! MSB-first in vtree leaf order, matching `reference/atdd_toy.py` (`_byvar`
//! and `index_from_assign`), so a subtree's local index folds `t.vars`
//! MSB-first with the left child more significant.

use crate::vtree::{Vtree, VtreeNode};

/// Decode a global assignment index into a per-variable assignment.
///
/// Bit `(n-1-i)` of `idx` is the value of variable `leaf_order[i]`.
pub fn index_to_assignment(idx: usize, vtree: &Vtree) -> Vec<bool> {
    let mut a = vec![false; vtree.var_space()];
    index_to_assignment_into(idx, vtree, &mut a);
    a
}

/// Decode a global assignment index into `out` (indexed by variable id),
/// reusing the caller's buffer. `out` must have length `>= var_space()`
/// (which exceeds `n_vars()` on induced vtrees). Every variable is a leaf,
/// so all positions in `leaf_order` are overwritten — no stale bits — but
/// positions outside the variable range are left untouched. This is the
/// allocation-free twin used in the `2^n` truth-table loops.
pub fn index_to_assignment_into(idx: usize, vtree: &Vtree, out: &mut [bool]) {
    let order = vtree.leaf_order();
    let n = order.len();
    for (i, &v) in order.iter().enumerate() {
        out[v] = (idx >> (n - 1 - i)) & 1 == 1;
    }
}

/// Encode a full assignment (indexed by variable id) to its global index.
pub fn assignment_to_index(assignment: &[bool], vtree: &Vtree) -> usize {
    let mut idx = 0usize;
    for &v in vtree.leaf_order() {
        idx = (idx << 1) | usize::from(assignment[v]);
    }
    idx
}

/// Local index at a node: fold the node's variables MSB-first.
///
/// `assignment` must be defined at least on `node.vars`.
pub fn local_index(assignment: &[bool], node: &VtreeNode) -> usize {
    let mut idx = 0usize;
    for &v in &node.vars {
        idx = (idx << 1) | usize::from(assignment[v]);
    }
    idx
}

/// Decode a node-local index into a partial assignment over `node.vars`,
/// writing into `assignment` (other positions untouched). MSB-first.
pub fn write_local_assignment(idx: usize, node: &VtreeNode, assignment: &mut [bool]) {
    let m = node.vars.len();
    for (i, &v) in node.vars.iter().enumerate() {
        assignment[v] = (idx >> (m - 1 - i)) & 1 == 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn global_roundtrip() {
        let t = Vtree::balanced(6);
        for idx in 0..(1usize << 6) {
            let a = index_to_assignment(idx, &t);
            assert_eq!(assignment_to_index(&a, &t), idx);
        }
    }

    #[test]
    fn msb_first_leaf_order() {
        // right-linear over 3 vars: leaf order 0,1,2. idx bit2->x0, bit1->x1, bit0->x2.
        let t = Vtree::right_linear(3);
        // idx = 0b100 => x0=1, x1=0, x2=0
        let a = index_to_assignment(0b100, &t);
        assert_eq!(a, vec![true, false, false]);
        // idx = 0b001 => x2=1
        let a = index_to_assignment(0b001, &t);
        assert_eq!(a, vec![false, false, true]);
    }

    #[test]
    fn local_index_left_significant() {
        // balanced over 4: root left = {0,1}, right = {2,3}.
        let t = Vtree::balanced(4);
        let root = t.node(t.root());
        // assignment x0=1,x1=0,x2=1,x3=1
        let a = vec![true, false, true, true];
        // local at root over vars [0,1,2,3] MSB-first = 0b1011 = 11
        assert_eq!(local_index(&a, root), 0b1011);
        let l = t.node(root.left.unwrap());
        let r = t.node(root.right.unwrap());
        // left {0,1}: 0b10 = 2 ; right {2,3}: 0b11 = 3
        assert_eq!(local_index(&a, l), 0b10);
        assert_eq!(local_index(&a, r), 0b11);
        // left more significant: idx_root == idx_l * 2^|right| + idx_r
        assert_eq!(
            local_index(&a, root),
            local_index(&a, l) * (1 << r.nv()) + local_index(&a, r)
        );
    }

    #[test]
    fn write_local_roundtrip() {
        let t = Vtree::random(5, &mut crate::rng::Rng::new(3));
        let node = t.node(t.root());
        let mut a = vec![false; 5];
        for idx in 0..(1usize << node.nv()) {
            write_local_assignment(idx, node, &mut a);
            assert_eq!(local_index(&a, node), idx);
        }
    }
}
