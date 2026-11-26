//! Canonical vtree rotation surgery for the ATDD backend (M7; Theorem 8 of
//! `FABLE_NOTES/05_vtree_rotation.md`; port of `reference/rotation_alg_toy.py`
//! `left_surgery`/`build_left_canon`/`right_surgery_inverse`).
//!
//! A rotation is an exact, purely local, canonical-to-canonical move: contract
//! the two tensors at the rotation site into a 4-tensor `T`, matricize it as
//! `R` with rows over the *created* cut's children and columns over the rest,
//! take one fraction-free RREF of `Rᵀ`, and read the two new tensors from the
//! echelon rows (`E`) and the pivot slices of `T`. Only the two tensors at the
//! site change; every other node is byte-identical (Prop 0(ii)). The created
//! cut's factor rank is `ρ_m = rank R` (Theorem 8(i)).
//!
//! Left rotation `v = (a, w), w = (b, c)` ↦ `v' = (m, c), m = (a, b)`:
//!   `T[i][j][k][m] = Σ_l W^v[i][j][l] · W^w[l][k][m]`,
//!   `R` rows `(j,k)` (the created cut `A∪B`), cols `(i,m)`; `E = RREF(Rᵀ)`;
//!   `W'^m[e] = E[e]` reshaped `d_a×d_b`, `W'^{v'}[i][e][mc] = T[i][j_e][k_e][mc]`,
//!   canonical tests `p^m_e = p^a_{j_e} × p^b_{k_e}`, `p^{v'} = p^v`.
//! Right rotation is the mirror (destroying `A∪B`, creating `B∪C`).
//!
//! Input: a *canonical* ATDD (bond families are the interpolation bases — as
//! produced by `oracle::reference_canonical` or `pipeline`+`canonicalize`) and
//! its per-node canonical tests. Output: the canonical ATDD w.r.t. the rotated
//! vtree, byte-identical to `reference_canonical` computed from scratch there.

use super::canonical::Pivot;
use super::linalg::{Mat, Q};
use super::oracle::reference_canonical;
use super::{Atdd, NodeData};
use crate::vtree::Vtree;
use num_traits::Zero;
use rustc_hash::FxHashMap;

/// The result of a rotation surgery.
pub struct Rotation {
    /// The rotated vtree (same leaf order as the input, Prop 0(ii)).
    pub vtree: Vtree,
    /// The canonical ATDD over [`Rotation::vtree`].
    pub atdd: Atdd,
    /// Canonical tests per node id of [`Rotation::vtree`].
    pub pivots: Vec<Vec<Pivot>>,
    /// The created cut's factor rank `ρ_m = rank R` (Theorem 8(i)).
    pub rank_r: usize,
    /// Node id (in [`Rotation::vtree`]) of the created merge node.
    pub new_node: usize,
    /// Node id (in [`Rotation::vtree`]) of the rotated node `v'`.
    pub rotated_node: usize,
}

/// A dense 4-tensor `T[i][j][k][m]` (`i` outermost). Index strides are
/// `da·db·dc`, `db·dc`, `dc`, `1`.
struct T4 {
    da: usize,
    db: usize,
    dc: usize,
    e: Vec<Q>,
}

impl T4 {
    fn zeros(d0: usize, da: usize, db: usize, dc: usize) -> T4 {
        T4 {
            da,
            db,
            dc,
            e: vec![Q::zero(); d0 * da * db * dc],
        }
    }

    #[inline]
    fn idx(&self, i: usize, j: usize, k: usize, m: usize) -> usize {
        ((i * self.da + j) * self.db + k) * self.dc + m
    }

    #[inline]
    fn at(&self, i: usize, j: usize, k: usize, m: usize) -> &Q {
        &self.e[self.idx(i, j, k, m)]
    }
}

/// The internal slices at node `t` (panics on a leaf — rotation sites are
/// always internal).
fn slices(a: &Atdd, t: usize) -> &[Mat] {
    match &a.node[t] {
        NodeData::Internal(w) => w,
        NodeData::Leaf(_) => unreachable!("rotation site {t} must be internal"),
    }
}

/// Left contraction `T[i][j][k][m] = Σ_l W^v[i][j][l] · W^w[l][k][m]`
/// (`W^v[i]` is `d_a×d_w`, `W^w[l]` is `d_b×d_c`).
fn contract_left(wv: &[Mat], ww: &[Mat], dv: usize, da: usize, db: usize, dc: usize) -> T4 {
    let mut t = T4::zeros(dv, da, db, dc);
    for (i, wvi) in wv.iter().enumerate() {
        for j in 0..da {
            for (l, wwl) in ww.iter().enumerate() {
                let wval = wvi.at(j, l);
                if wval.is_zero() {
                    continue;
                }
                for k in 0..db {
                    for m in 0..dc {
                        let w2 = wwl.at(k, m);
                        if !w2.is_zero() {
                            let ix = t.idx(i, j, k, m);
                            t.e[ix] += wval * w2;
                        }
                    }
                }
            }
        }
    }
    t
}

/// Right contraction `T[i][j][k][mc] = Σ_l W^v[i][l][mc] · W^q[l][j][k]`
/// (`W^v[i]` is `d_q×d_c`, `W^q[l]` is `d_a×d_b`).
fn contract_right(wv: &[Mat], wq: &[Mat], dv: usize, da: usize, db: usize, dc: usize) -> T4 {
    let mut t = T4::zeros(dv, da, db, dc);
    for (i, wvi) in wv.iter().enumerate() {
        for (l, wql) in wq.iter().enumerate() {
            for mc in 0..dc {
                let wval = wvi.at(l, mc);
                if wval.is_zero() {
                    continue;
                }
                for j in 0..da {
                    for k in 0..db {
                        let w2 = wql.at(j, k);
                        if !w2.is_zero() {
                            let ix = t.idx(i, j, k, mc);
                            t.e[ix] += wval * w2;
                        }
                    }
                }
            }
        }
    }
    t
}

/// Left rotation at `v` (internal, with internal right child). `a` must be the
/// canonical ATDD over `vt` and `pivots` its canonical tests.
pub fn left_rotate(vt: &Vtree, a: &Atdd, pivots: &[Vec<Pivot>], v: usize) -> Rotation {
    assert!(vt.is_left_rotatable(v), "left_rotate: illegal site {v}");
    let w = vt.node(v).right.unwrap();
    let a_id = vt.node(v).left.unwrap();
    let b_id = vt.node(w).left.unwrap();
    let c_id = vt.node(w).right.unwrap();
    let (dv, da, db, dc) = (a.dim(v), a.dim(a_id), a.dim(b_id), a.dim(c_id));

    let t = contract_left(slices(a, v), slices(a, w), dv, da, db, dc);
    // Rᵀ: rows (i,m) i-major, cols (j,k) j-major (the created cut A∪B).
    let rt = Mat::from_fn(dv * dc, da * db, |row, col| {
        t.at(row / dc, col / db, col % db, row % dc).clone()
    });
    let (e, pivcols) = rt.rref();
    let rho = e.r;

    // W'^m[e]: d_a×d_b echelon slices; pivot decodes to (j_e, k_e).
    let wm: Vec<Mat> = (0..rho)
        .map(|ee| Mat::from_fn(da, db, |j, k| e.at(ee, j * db + k).clone()))
        .collect();
    let jk: Vec<(usize, usize)> = pivcols.iter().map(|&pc| (pc / db, pc % db)).collect();
    // W'^{v'}[i]: ρ×d_c sampled at the pivots.
    let wvp: Vec<Mat> = (0..dv)
        .map(|i| {
            Mat::from_fn(rho, dc, |ee, mc| {
                let (je, ke) = jk[ee];
                t.at(i, je, ke, mc).clone()
            })
        })
        .collect();
    let piv_m: Vec<Pivot> = jk
        .iter()
        .map(|&(je, ke)| pivots[a_id][je].concat(&pivots[b_id][ke]))
        .collect();

    let vt2 = vt.left_rotate(v);
    let new_is_left = true; // v' = (m, c): the created node m is v''s LEFT child
    assemble(
        vt,
        vt2,
        a,
        pivots,
        v,
        NodeData::Internal(wvp),
        pivots[v].clone(),
        NodeData::Internal(wm),
        piv_m,
        rho,
        new_is_left,
    )
}

/// Right rotation at `v` (internal, with internal left child) — the mirror of
/// [`left_rotate`]; inverts it exactly on canonical forms.
pub fn right_rotate(vt: &Vtree, a: &Atdd, pivots: &[Vec<Pivot>], v: usize) -> Rotation {
    assert!(vt.is_right_rotatable(v), "right_rotate: illegal site {v}");
    let q = vt.node(v).left.unwrap();
    let c_id = vt.node(v).right.unwrap();
    let a_id = vt.node(q).left.unwrap();
    let b_id = vt.node(q).right.unwrap();
    let (dv, da, db, dc) = (a.dim(v), a.dim(a_id), a.dim(b_id), a.dim(c_id));

    let t = contract_right(slices(a, v), slices(a, q), dv, da, db, dc);
    // Rᵀ: rows (i,j) i-major, cols (k,mc) k-major (the created cut B∪C).
    let rt = Mat::from_fn(dv * da, db * dc, |row, col| {
        t.at(row / da, row % da, col / dc, col % dc).clone()
    });
    let (e, pivcols) = rt.rref();
    let rho = e.r;

    // W'^{w2}[e]: d_b×d_c echelon slices; pivot decodes to (k_e, mc_e).
    let ww2: Vec<Mat> = (0..rho)
        .map(|ee| Mat::from_fn(db, dc, |k, mc| e.at(ee, k * dc + mc).clone()))
        .collect();
    let km: Vec<(usize, usize)> = pivcols.iter().map(|&pc| (pc / dc, pc % dc)).collect();
    // W'^{v'}[i]: d_a×ρ sampled at the pivots.
    let wv2: Vec<Mat> = (0..dv)
        .map(|i| {
            Mat::from_fn(da, rho, |j, ee| {
                let (ke, mce) = km[ee];
                t.at(i, j, ke, mce).clone()
            })
        })
        .collect();
    let piv_w2: Vec<Pivot> = km
        .iter()
        .map(|&(ke, mce)| pivots[b_id][ke].concat(&pivots[c_id][mce]))
        .collect();

    let vt2 = vt.right_rotate(v);
    let new_is_left = false; // v' = (a, w2): the created node w2 is v''s RIGHT child
    assemble(
        vt,
        vt2,
        a,
        pivots,
        v,
        NodeData::Internal(wv2),
        pivots[v].clone(),
        NodeData::Internal(ww2),
        piv_w2,
        rho,
        new_is_left,
    )
}

/// Stitch the two new tensors into the rotated vtree, copying every preserved
/// node byte-identically (matched by its contiguous `(off, nv)` cut block —
/// stable across the rotation because the leaf order is unchanged).
#[allow(clippy::too_many_arguments)]
fn assemble(
    vt: &Vtree,
    vt2: Vtree,
    a: &Atdd,
    pivots: &[Vec<Pivot>],
    v: usize,
    rot_data: NodeData,
    rot_piv: Vec<Pivot>,
    new_data: NodeData,
    new_piv: Vec<Pivot>,
    rank_r: usize,
    new_is_left: bool,
) -> Rotation {
    let (off_v, nv_v) = (vt.node(v).off, vt.node(v).nv());
    // The rotated node v' is the unique internal node covering v's cut block.
    let rotated = (0..vt2.num_nodes())
        .find(|&t| {
            let n = vt2.node(t);
            !n.is_leaf() && n.off == off_v && n.nv() == nv_v
        })
        .expect("rotated node exists in the rotated vtree");
    let new_node = if new_is_left {
        vt2.node(rotated).left.unwrap()
    } else {
        vt2.node(rotated).right.unwrap()
    };

    // Preserved-cut map: (off, nv) → old node id.
    let mut map: FxHashMap<(usize, usize), usize> = FxHashMap::default();
    map.reserve(vt.num_nodes());
    for t in 0..vt.num_nodes() {
        map.insert((vt.node(t).off, vt.node(t).nv()), t);
    }

    let mut rot_data = Some(rot_data);
    let mut rot_piv = Some(rot_piv);
    let mut new_data = Some(new_data);
    let mut new_piv = Some(new_piv);
    let mut node = Vec::with_capacity(vt2.num_nodes());
    let mut piv: Vec<Vec<Pivot>> = Vec::with_capacity(vt2.num_nodes());
    for t2 in 0..vt2.num_nodes() {
        if t2 == rotated {
            node.push(rot_data.take().unwrap());
            piv.push(rot_piv.take().unwrap());
        } else if t2 == new_node {
            node.push(new_data.take().unwrap());
            piv.push(new_piv.take().unwrap());
        } else {
            let key = (vt2.node(t2).off, vt2.node(t2).nv());
            let old = map[&key];
            node.push(a.node[old].clone());
            piv.push(pivots[old].clone());
        }
    }

    Rotation {
        vtree: vt2,
        atdd: Atdd { node },
        pivots: piv,
        rank_r,
        new_node,
        rotated_node: rotated,
    }
}

/// The canonical ATDD of `f` w.r.t. `vt` together with its canonical tests as
/// [`Pivot`]s — the input pair for the rotation primitives. `f ≢ 0` required.
pub fn canonical_and_pivots(f: &[Q], vt: &Vtree) -> (Atdd, Vec<Vec<Pivot>>) {
    let refs = reference_canonical(f, vt);
    let pivots: Vec<Vec<Pivot>> = refs
        .iter()
        .enumerate()
        .map(|(t, (piv, _))| {
            let nb = vt.node(t).nv();
            piv.iter()
                .map(|&idx| Pivot::from_local_index(idx, nb))
                .collect()
        })
        .collect();
    let node = refs.into_iter().map(|(_, d)| d).collect();
    (Atdd { node }, pivots)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::atdd::func;
    use crate::atdd::linalg::q;
    use crate::atdd::oracle::{brute_rank, to_q};
    use crate::instances::{random_kcnf, tt_hwb, tt_mux, tt_parity};
    use crate::rng::Rng;
    use crate::truthtable::cnf_truth_table;

    /// Reference pivots (local indices) at every node of `vt`.
    fn ref_pivots(f: &[Q], vt: &Vtree) -> Vec<Vec<usize>> {
        reference_canonical(f, vt)
            .into_iter()
            .map(|(p, _)| p)
            .collect()
    }

    /// Assert `rot` is byte-identical to the from-scratch canonical ATDD of `f`
    /// over its (rotated) vtree — data AND pivots — and preserves `f`.
    fn assert_canonical(rot: &Rotation, f: &[Q]) {
        let refs = reference_canonical(f, &rot.vtree);
        for (t, (ref_piv, ref_data)) in refs.iter().enumerate() {
            assert_eq!(rot.atdd.node[t], *ref_data, "data mismatch at node {t}");
            let got: Vec<usize> = rot.pivots[t].iter().map(Pivot::to_local_index).collect();
            assert_eq!(&got, ref_piv, "pivot mismatch at node {t}");
        }
        rot.atdd.check(&rot.vtree).unwrap();
        assert_eq!(func(&rot.atdd, &rot.vtree), f, "rotation preserves f");
    }

    /// Every legal left rotation on a truth table, fully validated.
    fn sweep_left(f: &[Q], vt: &Vtree) -> usize {
        let (a, pivots) = canonical_and_pivots(f, vt);
        let mut count = 0;
        for v in 0..vt.num_nodes() {
            if !vt.is_left_rotatable(v) {
                continue;
            }
            count += 1;
            let rot = left_rotate(vt, &a, &pivots, v);

            // (1) byte-identical to from-scratch canonical + function preserved.
            assert_canonical(&rot, f);

            // (2) rank R == brute ρ(A∪B) at the created node.
            let rho_m = brute_rank(f, &rot.vtree, rot.new_node);
            assert_eq!(rot.rank_r, rho_m, "rank R != ρ_m (left at {v})");

            // (3) Prop 2 bound: ρ_m ≤ min(d_a·d_b, d_c·d_v).
            let w = vt.node(v).right.unwrap();
            let (da, db) = (
                a.dim(vt.node(v).left.unwrap()),
                a.dim(vt.node(w).left.unwrap()),
            );
            let (dc, dvv) = (a.dim(vt.node(w).right.unwrap()), a.dim(v));
            assert!(
                rot.rank_r <= (da * db).min(dc * dvv),
                "Prop 2 bound (left at {v})"
            );

            // (4) locality: every node other than v' and m is byte-identical to
            // the input (matched by cut block).
            let mut map: FxHashMap<(usize, usize), usize> = FxHashMap::default();
            for t in 0..vt.num_nodes() {
                map.insert((vt.node(t).off, vt.node(t).nv()), t);
            }
            for t2 in 0..rot.vtree.num_nodes() {
                if t2 == rot.rotated_node || t2 == rot.new_node {
                    continue;
                }
                let old = map[&(rot.vtree.node(t2).off, rot.vtree.node(t2).nv())];
                assert_eq!(rot.atdd.node[t2], a.node[old], "locality broken at {t2}");
                let po: Vec<usize> = pivots[old].iter().map(Pivot::to_local_index).collect();
                let pn: Vec<usize> = rot.pivots[t2].iter().map(Pivot::to_local_index).collect();
                assert_eq!(pn, po, "locality pivots broken at {t2}");
            }

            // (5) predicted tests p^m_e = p^a_{j_e} × p^b_{k_e} — covered by the
            // byte-identical check, but assert the child-product shape too.
            let rp = ref_pivots(f, &rot.vtree);
            let n2 = 1usize << vt.node(vt.node(w).left.unwrap()).nv();
            let a_pivs = &ref_pivots(f, vt)[vt.node(v).left.unwrap()];
            let b_pivs = &ref_pivots(f, vt)[vt.node(w).left.unwrap()];
            for &pm in &rp[rot.new_node] {
                let (ja, kb) = (pm / n2, pm % n2);
                assert!(
                    a_pivs.contains(&ja) && b_pivs.contains(&kb),
                    "product test shape"
                );
            }

            // (6) rotate then inverse-rotate = identity (byte-identical).
            let inv = right_rotate(&rot.vtree, &rot.atdd, &rot.pivots, rot.rotated_node);
            assert_eq!(inv.atdd.node.len(), a.node.len());
            let back: FxHashMap<(usize, usize), &NodeData> = (0..inv.vtree.num_nodes())
                .map(|t| {
                    (
                        (inv.vtree.node(t).off, inv.vtree.node(t).nv()),
                        &inv.atdd.node[t],
                    )
                })
                .collect();
            for t in 0..vt.num_nodes() {
                let nd = back[&(vt.node(t).off, vt.node(t).nv())];
                assert_eq!(*nd, a.node[t], "rotate∘unrotate != id at {t}");
            }
            // inverse output is itself the from-scratch canonical over the
            // original vtree.
            assert_canonical(&inv, f);
        }
        count
    }

    /// Every legal right rotation on a truth table, validated directly (not
    /// only as the inverse of a left rotation).
    fn sweep_right(f: &[Q], vt: &Vtree) -> usize {
        let (a, pivots) = canonical_and_pivots(f, vt);
        let mut count = 0;
        for v in 0..vt.num_nodes() {
            if !vt.is_right_rotatable(v) {
                continue;
            }
            count += 1;
            let rot = right_rotate(vt, &a, &pivots, v);
            assert_canonical(&rot, f);

            // rank R == brute ρ(B∪C) at the created node.
            assert_eq!(
                rot.rank_r,
                brute_rank(f, &rot.vtree, rot.new_node),
                "rank R (right at {v})"
            );
            // Prop 2 mirror: ρ(B∪C) ≤ min(ρ_b·ρ_c, ρ_a·ρ_v).
            let q = vt.node(v).left.unwrap();
            let (da, db) = (
                a.dim(vt.node(q).left.unwrap()),
                a.dim(vt.node(q).right.unwrap()),
            );
            let (dc, dvv) = (a.dim(vt.node(v).right.unwrap()), a.dim(v));
            assert!(rot.rank_r <= (db * dc).min(da * dvv), "Prop 2 mirror bound");

            // Locality: preserved nodes byte-identical.
            let mut map: FxHashMap<(usize, usize), usize> = FxHashMap::default();
            for t in 0..vt.num_nodes() {
                map.insert((vt.node(t).off, vt.node(t).nv()), t);
            }
            for t2 in 0..rot.vtree.num_nodes() {
                if t2 == rot.rotated_node || t2 == rot.new_node {
                    continue;
                }
                let old = map[&(rot.vtree.node(t2).off, rot.vtree.node(t2).nv())];
                assert_eq!(rot.atdd.node[t2], a.node[old], "locality broken at {t2}");
            }

            // Inverse (left-rotate the rotated node) restores the original.
            let inv = left_rotate(&rot.vtree, &rot.atdd, &rot.pivots, rot.rotated_node);
            assert_canonical(&inv, f);
            let back: FxHashMap<(usize, usize), &NodeData> = (0..inv.vtree.num_nodes())
                .map(|t| {
                    (
                        (inv.vtree.node(t).off, inv.vtree.node(t).nv()),
                        &inv.atdd.node[t],
                    )
                })
                .collect();
            for t in 0..vt.num_nodes() {
                assert_eq!(
                    *back[&(vt.node(t).off, vt.node(t).nv())],
                    a.node[t],
                    "unrotate∘rotate != id at {t}"
                );
            }
        }
        count
    }

    #[test]
    fn right_rotation_sweep() {
        // Right rotations need an internal LEFT child, so use balanced/random
        // vtrees (a right comb has none).
        let mut rng = Rng::new(0x0516_47A7);
        let mut rotations = 0;
        for n in [4usize, 5, 6] {
            for vt in [Vtree::balanced(n), Vtree::random(n, &mut rng)] {
                rotations += sweep_right(&to_q(&tt_parity(n)), &vt);
                rotations += sweep_right(&to_q(&tt_hwb(n, &vt)), &vt);
            }
        }
        // A few random SAT CNFs too.
        let mut tested = 0;
        let mut attempt = 0;
        while tested < 12 && attempt < 300 {
            attempt += 1;
            let n = 4 + rng.below(3);
            let cnf = random_kcnf(n, 1 + rng.below(2 * n), 3, &mut rng);
            let vt = Vtree::balanced(n);
            if !cnf_truth_table(&cnf, &vt).iter().any(|&b| b) {
                continue;
            }
            tested += 1;
            rotations += sweep_right(&to_q(&cnf_truth_table(&cnf, &vt)), &vt);
        }
        assert!(
            rotations > 20,
            "too few right rotations exercised: {rotations}"
        );
    }

    #[test]
    fn left_rotation_sweep_random_cnf() {
        let mut rng = Rng::new(0x2072A7E);
        let mut rotations = 0;
        let mut tested = 0;
        let mut attempt = 0;
        while tested < 24 && attempt < 400 {
            attempt += 1;
            let n = 4 + rng.below(4); // 4..=7
            let m = 1 + rng.below(2 * n);
            let cnf = random_kcnf(n, m, 3, &mut rng);
            let vt0 = Vtree::right_linear(n);
            if !cnf_truth_table(&cnf, &vt0).iter().any(|&b| b) {
                continue; // UNSAT: no canonical form
            }
            tested += 1;
            for vt in [Vtree::balanced(n), Vtree::random(n, &mut rng)] {
                let f = to_q(&cnf_truth_table(&cnf, &vt));
                rotations += sweep_left(&f, &vt);
            }
        }
        assert!(tested >= 24, "too few satisfiable instances: {tested}");
        assert!(
            rotations > 40,
            "too few rotation positions exercised: {rotations}"
        );
    }

    #[test]
    fn left_rotation_sweep_structured() {
        let mut rng = Rng::new(0x57444);
        let mut rotations = 0;
        for n in [4usize, 5, 6] {
            for vt in [Vtree::balanced(n), Vtree::random(n, &mut rng)] {
                rotations += sweep_left(&to_q(&tt_parity(n)), &vt);
                rotations += sweep_left(&to_q(&tt_hwb(n, &vt)), &vt);
            }
        }
        // MUX_2 on a balanced vtree: the S = 2^ρ − 1 gap witness under rotation.
        let vt = Vtree::balanced(6);
        rotations += sweep_left(&to_q(&tt_mux(2, &vt)), &vt);
        assert!(
            rotations > 20,
            "structured sweep exercised too few rotations"
        );
    }

    /// The unique node whose variable set equals `vars` (as a set).
    fn find_node_by_vars(vt: &Vtree, vars: &[usize]) -> usize {
        let want: std::collections::BTreeSet<usize> = vars.iter().copied().collect();
        (0..vt.num_nodes())
            .find(|&t| {
                vt.node(t)
                    .vars
                    .iter()
                    .copied()
                    .collect::<std::collections::BTreeSet<_>>()
                    == want
            })
            .expect("node with the given variable set exists")
    }

    #[test]
    fn proposition_4_trivial_destroyed_cut_forces_rank() {
        // Pinned Corollary-5 witness f_{1,1,0} = (a1 ↔ d1) ∧ (b1 ↔ c1) on 4
        // vars (a=0,b=1,c=2,d=3): on the vtree ((0,(1,2)),3) the node v=(0,(1,2))
        // has destroyed cut w={1,2} of rank ρ_w = 1, and Proposition 4 forces
        // ρ_m = ρ_a·ρ_b = ρ_c·ρ_v = 4 with local ranks (2,2,2,2,1,4).
        //
        // Build ((0,(1,2)),3) from right_linear(4) = (0,(1,(2,3))) by two
        // structural left rotations.
        let vt0 = Vtree::right_linear(4);
        let vt1 = vt0.left_rotate(find_node_by_vars(&vt0, &[1, 2, 3])); // (0,((1,2),3))
        let vt = vt1.left_rotate(find_node_by_vars(&vt1, &[0, 1, 2, 3])); // ((0,(1,2)),3)

        let mut f = vec![q(0); 16];
        for x in 0..16u32 {
            let bit = |i: u32| (x >> (3 - i)) & 1; // MSB-first: var i = bit(i)
            if bit(0) == bit(3) && bit(1) == bit(2) {
                f[x as usize] = q(1);
            }
        }
        let (a, pivots) = canonical_and_pivots(&f, &vt);

        let v = find_node_by_vars(&vt, &[0, 1, 2]);
        assert!(vt.is_left_rotatable(v));
        let w = vt.node(v).right.unwrap();
        assert_eq!(brute_rank(&f, &vt, w), 1, "destroyed cut ρ_w = 1");

        let rot = left_rotate(&vt, &a, &pivots, v);
        assert_canonical(&rot, &f);
        let (da, db) = (a.dim(vt.node(v).left.unwrap()), a.dim(w));
        assert_eq!((da, db), (2, 1), "ρ_a = 2, ρ_w = 1");
        // b = left child of w; ρ_b = ρ_c = 2, ρ_v = 2, so ρ_m = ρ_a·ρ_b = 4.
        assert_eq!(rot.rank_r, 4, "Prop 4: ρ_m = ρ_a·ρ_b = 4");
    }
}
