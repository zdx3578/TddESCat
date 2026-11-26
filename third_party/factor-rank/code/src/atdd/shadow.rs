//! Per-node denominator-cleared integer **shadow** of the working ATDD — the
//! compile-side analogue of the counting [`IntKernel`](super::intcount) that
//! removes `Ratio<BigInt>`'s per-operation gcd/normalization tax from the hot
//! contractions (`gram`, `point_eval`, the Phase-2 context chain), which the
//! profile pins at 96–98 % of compile time.
//!
//! # Idea (fable-deep design, session 5)
//!
//! At vtree node `x`, let `D_x = lcm` of the (reduced, positive) denominators of
//! the ℚ tensor there; the integer tensor is `D_x ·` the ℚ tensor (exact, since
//! `D_x` is a common multiple — lem:bits guarantees `D_x` stays small). The ℚ
//! `Atdd` stays the single source of truth; this shadow is *derived* and kept in
//! sync by re-clearing only the ≤ 2 nodes each `apply_node_transform` touches.
//!
//! Running the contractions over the integer tensors yields **uniformly scaled**
//! results (all proved by induction over the exact recursions, and unit-tested):
//! - `gram` returns `σ_t · G_t` with `σ_t = ∏_{x ∈ subtree(t)} D_x²`
//!   (each bilinear leaf/internal step contributes a square). [`Shadow::scale_sq`]
//! - `point_eval` returns `σ'_t · e` with `σ'_t = ∏_{x ∈ subtree(t)} D_x`
//!   (linear). [`Shadow::scale_lin`]
//! - the context chain returns `σ_H · H` with `σ_H` a tracked integer product.
//!
//! A uniform positive scalar leaves every downstream decision the ℚ pipeline
//! makes **byte-identical**: `Mat::rref` pivot columns are invariant under
//! `M ↦ σM` (so the canonical tests / `kept` sets are preserved), zero tests are
//! invariant, and the reconstruction/gauge ratios (`γ`, `Λ`, `(Pᵀ)⁻¹`) either
//! cancel `σ` exactly or are recovered by one exact `Ratio::new` per entry. See
//! the wiring in `minimize`/`canonical` for where each scaled result is consumed.
//!
//! # Storage: `i128` fast path, `BigInt` fallback
//!
//! The contractions are generic over an [`Int`] backend. When every cleared
//! entry fits `i128` (the common case — MUX has 0/1 entries, `D_x = 1`), a
//! parallel `i128` shadow drives register arithmetic (the [`IntKernel`] regime);
//! any single contraction whose *intermediate* overflows `i128` returns `None`
//! and is transparently redone in `BigInt` (still gcd-free). Exactness never
//! depends on the fast path — the `BigInt` shadow is always present.

use super::canonical::Pivot;
use super::contract::{Partial, subtree_postorder};
use super::linalg::{Mat, Q};
use super::{Atdd, NodeData};
use crate::vtree::Vtree;
use num_bigint::BigInt;
use num_integer::Integer;
use num_traits::{CheckedAdd, CheckedMul, CheckedSub, One, ToPrimitive, Zero};

/// The integer backend the contractions run over: exact `BigInt` (its
/// `checked_*` never overflow → always `Some`) or checked `i128` (returns
/// `None` on overflow so the caller can fall back). `Zero`/`One`/`CheckedMul`/
/// `CheckedAdd`/`CheckedSub` come from `num_traits`; only the `BigInt`
/// conversion is new.
trait Int: Clone + Zero + One + CheckedMul + CheckedAdd + CheckedSub {
    fn to_bigint(&self) -> BigInt;
}

impl Int for i128 {
    #[inline]
    fn to_bigint(&self) -> BigInt {
        BigInt::from(*self)
    }
}

impl Int for BigInt {
    #[inline]
    fn to_bigint(&self) -> BigInt {
        self.clone()
    }
}

/// One node's denominator-cleared integer tensor, generic over the entry width.
enum INode<T> {
    /// `d × 2` leaf, row-major (`m[i*2 + col]`).
    Leaf { m: Vec<T>, d: usize },
    /// `d` slices, each `d1 × d2` row-major (`w[i][j*d2 + k]`).
    Internal {
        w: Vec<Vec<T>>,
        d1: usize,
        d2: usize,
    },
}

/// The integer shadow of a working ATDD, indexed by vtree-node id.
pub(crate) struct Shadow {
    /// `D_x` ≥ 1: lcm of node `x`'s (reduced, positive) entry denominators.
    den: Vec<BigInt>,
    /// Cleared integer tensors (exact): `big[x]` entries `= D_x ·` ℚ entries.
    big: Vec<INode<BigInt>>,
    /// `i128` copy of `big`, present iff every entry fits (dropped on refresh
    /// if a re-cleared node no longer fits).
    small: Option<Vec<INode<i128>>>,
}

/// Clear one ℚ node to `(D, integer tensor)`.
fn clear_node(nd: &NodeData) -> (BigInt, INode<BigInt>) {
    // D = lcm of the entry denominators; skip the gcd on already-integer entries.
    let mut d = BigInt::one();
    match nd {
        NodeData::Leaf(m) => {
            for e in m.entries() {
                if !e.denom().is_one() {
                    d = d.lcm(e.denom());
                }
            }
        }
        NodeData::Internal(w) => {
            for e in w.iter().flat_map(Mat::entries) {
                if !e.denom().is_one() {
                    d = d.lcm(e.denom());
                }
            }
        }
    }
    // exact: numer · (D / denom). When D = 1 (all-integer node — the MUX-class
    // common case) the division and multiply are identities: clone the numerator.
    let all_int = d.is_one();
    let clear = |e: &Q| -> BigInt {
        if all_int {
            e.numer().clone()
        } else {
            e.numer() * (&d / e.denom())
        }
    };
    let node = match nd {
        NodeData::Leaf(m) => {
            let mut flat = Vec::with_capacity(m.r * 2);
            for i in 0..m.r {
                flat.push(clear(m.at(i, 0)));
                flat.push(clear(m.at(i, 1)));
            }
            INode::Leaf { m: flat, d: m.r }
        }
        NodeData::Internal(w) => {
            let (d1, d2) = w.first().map_or((0, 0), |w0| (w0.r, w0.c));
            let slices = w
                .iter()
                .map(|wi| {
                    let mut flat = Vec::with_capacity(wi.r * wi.c);
                    for i in 0..wi.r {
                        for j in 0..wi.c {
                            flat.push(clear(wi.at(i, j)));
                        }
                    }
                    flat
                })
                .collect();
            INode::Internal { w: slices, d1, d2 }
        }
    };
    (d, node)
}

/// Try to narrow a `BigInt` node to `i128` (`None` if any entry overflows).
fn to_small(n: &INode<BigInt>) -> Option<INode<i128>> {
    match n {
        INode::Leaf { m, d } => Some(INode::Leaf {
            m: m.iter().map(BigInt::to_i128).collect::<Option<Vec<_>>>()?,
            d: *d,
        }),
        INode::Internal { w, d1, d2 } => Some(INode::Internal {
            w: w.iter()
                .map(|s| s.iter().map(BigInt::to_i128).collect::<Option<Vec<_>>>())
                .collect::<Option<Vec<_>>>()?,
            d1: *d1,
            d2: *d2,
        }),
    }
}

/// A dense row-major integer matrix — the scratch type for the contractions
/// (no gcd anywhere, unlike `Mat` over `Q`). Arithmetic is checked via [`Int`].
struct BMat<T> {
    r: usize,
    c: usize,
    e: Vec<T>,
}

impl<T: Int> BMat<T> {
    fn zero(r: usize, c: usize) -> BMat<T> {
        BMat {
            r,
            c,
            e: vec![T::zero(); r * c],
        }
    }
    #[inline]
    fn at(&self, i: usize, j: usize) -> &T {
        &self.e[i * self.c + j]
    }
    #[inline]
    fn at_mut(&mut self, i: usize, j: usize) -> &mut T {
        &mut self.e[i * self.c + j]
    }
    /// `self · b`, zero-skipped; `None` on overflow.
    fn mul(&self, b: &BMat<T>) -> Option<BMat<T>> {
        debug_assert_eq!(self.c, b.r);
        let mut out: BMat<T> = BMat::zero(self.r, b.c);
        for i in 0..self.r {
            for k in 0..self.c {
                let a = self.at(i, k);
                if a.is_zero() {
                    continue;
                }
                for j in 0..b.c {
                    let x = b.at(k, j);
                    if !x.is_zero() {
                        let p = a.checked_mul(x)?;
                        *out.at_mut(i, j) = out.at(i, j).checked_add(&p)?;
                    }
                }
            }
        }
        Some(out)
    }
    /// Frobenius inner product `Σ self[i][j]·other[i][j]`; `None` on overflow.
    fn frob(&self, other: &BMat<T>) -> Option<T> {
        debug_assert!(self.r == other.r && self.c == other.c);
        let mut s = T::zero();
        for (x, y) in self.e.iter().zip(&other.e) {
            if !x.is_zero() && !y.is_zero() {
                s = s.checked_add(&x.checked_mul(y)?)?;
            }
        }
        Some(s)
    }
    /// `self += coeff · other`, zero-skipped; `None` on overflow.
    fn axpy(&mut self, coeff: &T, other: &BMat<T>) -> Option<()> {
        if coeff.is_zero() {
            return Some(());
        }
        for i in 0..self.e.len() {
            if !other.e[i].is_zero() {
                let p = coeff.checked_mul(&other.e[i])?;
                self.e[i] = self.e[i].checked_add(&p)?;
            }
        }
        Some(())
    }
    fn transpose(&self) -> BMat<T> {
        let mut out: BMat<T> = BMat::zero(self.c, self.r);
        for i in 0..self.r {
            for j in 0..self.c {
                if !self.at(i, j).is_zero() {
                    *out.at_mut(j, i) = self.at(i, j).clone();
                }
            }
        }
        out
    }
    fn from_slice(flat: &[T], r: usize, c: usize) -> BMat<T> {
        BMat {
            r,
            c,
            e: flat.to_vec(),
        }
    }
    /// To a `Q`-matrix with denominator 1 (`Q::from_integer` does no gcd).
    fn to_q(&self) -> Mat {
        Mat::from_fn(self.r, self.c, |i, j| {
            Q::from_integer(self.at(i, j).to_bigint())
        })
    }
    /// `n × n` identity (used to seed the fraction-free pivot descent).
    fn eye(n: usize) -> BMat<T> {
        let mut m = BMat::zero(n, n);
        for i in 0..n {
            *m.at_mut(i, i) = T::one();
        }
        m
    }
    /// `self · v`, zero-skipped; `None` on overflow.
    fn mul_vec(&self, v: &[T]) -> Option<Vec<T>> {
        debug_assert_eq!(self.c, v.len());
        let mut out = Vec::with_capacity(self.r);
        for i in 0..self.r {
            let mut s = T::zero();
            for (k, vk) in v.iter().enumerate() {
                if !vk.is_zero() {
                    let a = self.at(i, k);
                    if !a.is_zero() {
                        s = s.checked_add(&a.checked_mul(vk)?)?;
                    }
                }
            }
            out.push(s);
        }
        Some(out)
    }
    /// Build from explicit rows (all length `c`).
    fn from_rows(rows: Vec<Vec<T>>, c: usize) -> BMat<T> {
        let r = rows.len();
        let mut e = Vec::with_capacity(r * c);
        for row in rows {
            debug_assert_eq!(row.len(), c);
            e.extend(row);
        }
        BMat { r, c, e }
    }
}

/// Integer (conditioned) Gram at `t` over `nodes` (`= σ_t · G_t`); `None` on
/// `i128` overflow.
fn gram_gen<T: Int>(
    nodes: &[INode<T>],
    vt: &Vtree,
    t: usize,
    partial: &Partial,
) -> Option<BMat<T>> {
    let mut memo: Vec<Option<BMat<T>>> = (0..vt.num_nodes()).map(|_| None).collect();
    for x in subtree_postorder(vt, t) {
        let node = vt.node(x);
        let g = match &nodes[x] {
            INode::Leaf { m, d } => {
                let d = *d;
                let mut g = BMat::zero(d, d);
                match partial.get(node.var.unwrap()) {
                    Some(b) => {
                        let col = usize::from(b);
                        for i in 0..d {
                            for j in 0..d {
                                *g.at_mut(i, j) = m[i * 2 + col].checked_mul(&m[j * 2 + col])?;
                            }
                        }
                    }
                    None => {
                        for i in 0..d {
                            for j in 0..d {
                                let a = m[i * 2].checked_mul(&m[j * 2])?;
                                let b = m[i * 2 + 1].checked_mul(&m[j * 2 + 1])?;
                                *g.at_mut(i, j) = a.checked_add(&b)?;
                            }
                        }
                    }
                }
                g
            }
            INode::Internal { w, d1, d2 } => {
                let g1 = memo[node.left.unwrap()].as_ref().unwrap();
                let g2 = memo[node.right.unwrap()].as_ref().unwrap();
                let d = w.len();
                let ws: Vec<BMat<T>> = w.iter().map(|wi| BMat::from_slice(wi, *d1, *d2)).collect();
                // B_i = g1 · W_i · g2; G[i][i'] = ⟨W_{i'}, B_i⟩_F.
                let bs: Vec<BMat<T>> = ws
                    .iter()
                    .map(|wi| g1.mul(wi)?.mul(g2))
                    .collect::<Option<Vec<_>>>()?;
                let mut g = BMat::zero(d, d);
                for (i, bi) in bs.iter().enumerate() {
                    for (ip, wip) in ws.iter().enumerate().skip(i) {
                        let s = wip.frob(bi)?;
                        *g.at_mut(ip, i) = s.clone();
                        *g.at_mut(i, ip) = s;
                    }
                }
                g
            }
        };
        memo[x] = Some(g);
    }
    memo[t].take()
}

/// `e1ᵀ · W · e2` (`W` is `d1 × d2` row-major); `None` on overflow.
fn bilinear_gen<T: Int>(e1: &[T], w: &[T], e2: &[T], d1: usize, d2: usize) -> Option<T> {
    debug_assert!(e1.len() == d1 && e2.len() == d2);
    let mut s = T::zero();
    for (j, x) in e1.iter().enumerate() {
        if x.is_zero() {
            continue;
        }
        for (k, y) in e2.iter().enumerate() {
            let wjk = &w[j * d2 + k];
            if !y.is_zero() && !wjk.is_zero() {
                let p = x.checked_mul(wjk)?.checked_mul(y)?;
                s = s.checked_add(&p)?;
            }
        }
    }
    Some(s)
}

/// Integer `point_eval` at `t` over `nodes` (`= σ'_t · e`); `None` on overflow.
fn point_eval_gen<T: Int>(
    nodes: &[INode<T>],
    vt: &Vtree,
    t: usize,
    assign: &Partial,
) -> Option<Vec<T>> {
    let mut memo: Vec<Option<Vec<T>>> = (0..vt.num_nodes()).map(|_| None).collect();
    for x in subtree_postorder(vt, t) {
        let node = vt.node(x);
        let e = match &nodes[x] {
            INode::Leaf { m, d } => {
                let b = assign
                    .get(node.var.unwrap())
                    .expect("point_eval: assignment must fix all of vars(t)");
                let col = usize::from(b);
                (0..*d).map(|i| m[i * 2 + col].clone()).collect()
            }
            INode::Internal { w, d1, d2 } => {
                let e1 = memo[node.left.unwrap()].as_ref().unwrap();
                let e2 = memo[node.right.unwrap()].as_ref().unwrap();
                w.iter()
                    .map(|wi| bilinear_gen(e1, wi, e2, *d1, *d2))
                    .collect::<Option<Vec<_>>>()?
            }
        };
        memo[x] = Some(e);
    }
    memo[t].take()
}

/// The Phase-2 context Gram `H` at the end of `path` over `nodes` (`= σ_H · H`,
/// integer); `None` on overflow. Mirrors the ℚ H-chain in `minimize`.
fn context_chain_gen<T: Int>(
    nodes: &[INode<T>],
    a: &Atdd,
    vt: &Vtree,
    path: &[usize],
) -> Option<BMat<T>> {
    let mut h = BMat {
        r: 1,
        c: 1,
        e: vec![T::one()],
    };
    for &x in path {
        let xn = vt.node(x);
        let p = xn.parent.unwrap();
        let pn = vt.node(p);
        let q = if xn.is_left {
            pn.right.unwrap()
        } else {
            pn.left.unwrap()
        };
        let gq = gram_gen(nodes, vt, q, &Partial::default())?; // σ_q · G_q
        let INode::Internal { w, d1, d2 } = &nodes[p] else {
            unreachable!("internal path node has slices");
        };
        // slices of p as dx × d(q) integer matrices.
        let ms: Vec<BMat<T>> = if xn.is_left {
            w.iter().map(|wi| BMat::from_slice(wi, *d1, *d2)).collect()
        } else {
            w.iter()
                .map(|wi| BMat::from_slice(wi, *d1, *d2).transpose())
                .collect()
        };
        let dx = a.dim(x);
        let mgs: Vec<BMat<T>> = ms
            .iter()
            .map(|mi| mi.mul(&gq))
            .collect::<Option<Vec<_>>>()?;
        // Transpose each `ms[ip]` once (depends only on `ip`), not d² times.
        let mst: Vec<BMat<T>> = ms.iter().map(BMat::transpose).collect();
        let mut hx = BMat::zero(dx, dx);
        for (i, mgi) in mgs.iter().enumerate() {
            for (ip, mip_t) in mst.iter().enumerate() {
                let hv = h.at(i, ip);
                if hv.is_zero() {
                    continue;
                }
                let pr = mgi.mul(mip_t)?;
                hx.axpy(hv, &pr)?;
            }
        }
        h = hx;
    }
    Some(h)
}

impl Shadow {
    /// Build the shadow of `a` from scratch (one lcm/clear per node), plus the
    /// `i128` narrowing when every entry fits.
    pub fn build(a: &Atdd, _vt: &Vtree) -> Shadow {
        let mut den = Vec::with_capacity(a.node.len());
        let mut big = Vec::with_capacity(a.node.len());
        for nd in &a.node {
            let (d, n) = clear_node(nd);
            den.push(d);
            big.push(n);
        }
        let small = big.iter().map(to_small).collect::<Option<Vec<_>>>();
        Shadow { den, big, small }
    }

    /// Re-clear one node after its ℚ data changed (`apply_node_transform`
    /// touches exactly a node and its parent).
    pub fn refresh(&mut self, a: &Atdd, x: usize) {
        let (d, n) = clear_node(&a.node[x]);
        self.den[x] = d;
        if self.small.is_some() {
            match to_small(&n) {
                Some(sn) => self.small.as_mut().unwrap()[x] = sn,
                None => self.small = None, // a node overflowed i128 → BigInt from here
            }
        }
        self.big[x] = n;
    }

    /// `σ_t = ∏_{x ∈ subtree(t)} D_x²`.
    pub fn scale_sq(&self, vt: &Vtree, t: usize) -> BigInt {
        let mut s = BigInt::one();
        for x in subtree_postorder(vt, t) {
            if !self.den[x].is_one() {
                s *= &self.den[x] * &self.den[x];
            }
        }
        s
    }

    /// `σ'_t = ∏_{x ∈ subtree(t)} D_x`.
    pub fn scale_lin(&self, vt: &Vtree, t: usize) -> BigInt {
        let mut s = BigInt::one();
        for x in subtree_postorder(vt, t) {
            if !self.den[x].is_one() {
                s *= &self.den[x];
            }
        }
        s
    }

    /// `σ_t · G_t` as a denom-1 `Q`-matrix (i128 fast path, BigInt fallback).
    pub fn gram_scaled_q(&self, vt: &Vtree, t: usize, partial: &Partial) -> Mat {
        if let Some(small) = &self.small
            && let Some(g) = gram_gen(small, vt, t, partial)
        {
            return g.to_q();
        }
        gram_gen(&self.big, vt, t, partial)
            .expect("BigInt gram is infallible")
            .to_q()
    }

    /// Exact `point_eval` at `t`: integer eval divided by `σ'_t` per entry.
    /// (Production evaluation now goes through the integer descent's `node_eval`;
    /// this exact-ℚ form is retained for the differential tests.)
    #[cfg(test)]
    pub fn point_eval_exact(&self, vt: &Vtree, t: usize, assign: &Partial) -> Vec<Q> {
        let ebig: Vec<BigInt> = self
            .small
            .as_ref()
            .and_then(|small| point_eval_gen(small, vt, t, assign))
            .map_or_else(
                || {
                    point_eval_gen(&self.big, vt, t, assign)
                        .expect("BigInt point_eval is infallible")
                        .iter()
                        .map(Int::to_bigint)
                        .collect()
                },
                |e| e.iter().map(Int::to_bigint).collect(),
            );
        let sl = self.scale_lin(vt, t);
        ebig.into_iter().map(|e| Q::new(e, sl.clone())).collect()
    }

    /// The Phase-2 context Gram `H` at `t`, integer-scaled: returns
    /// `(σ_H · H` as a denom-1 `Q`-matrix, `σ_H)`.
    pub fn context_gram_scaled(&self, a: &Atdd, vt: &Vtree, t: usize) -> (Mat, BigInt) {
        let root = vt.root();
        let mut path = Vec::new();
        let mut x = t;
        while x != root {
            path.push(x);
            x = vt.node(x).parent.unwrap();
        }
        path.reverse();

        // σ_H = ∏_steps D_p² · σ_q — from `den` only, independent of the backend.
        let mut sigma = BigInt::one();
        for &x in &path {
            let xn = vt.node(x);
            let p = xn.parent.unwrap();
            let pn = vt.node(p);
            let q = if xn.is_left {
                pn.right.unwrap()
            } else {
                pn.left.unwrap()
            };
            if !self.den[p].is_one() {
                sigma *= &self.den[p] * &self.den[p];
            }
            sigma *= self.scale_sq(vt, q);
        }

        let h = self
            .small
            .as_ref()
            .and_then(|small| context_chain_gen(small, a, vt, &path))
            .map_or_else(
                || {
                    context_chain_gen(&self.big, a, vt, &path)
                        .expect("BigInt context chain is infallible")
                        .to_q()
                },
                |h| h.to_q(),
            );
        (h, sigma)
    }
}

/// Backend for the fraction-free (Bareiss) pivot descent: an [`Int`] plus the
/// node-level integer Gram/eval accessors (choosing the i128 or BigInt store)
/// and the exact division the Bareiss update relies on.
trait DescentInt: Int {
    /// `σ_t · G_π` at `t` as an integer matrix; `None` on i128 overflow or an
    /// absent fast-path store.
    fn node_gram(sh: &Shadow, vt: &Vtree, t: usize, p: &Partial) -> Option<BMat<Self>>;
    /// `σ'_t · e` at `t` as an integer vector; `None` likewise.
    fn node_eval(sh: &Shadow, vt: &Vtree, t: usize, p: &Partial) -> Option<Vec<Self>>;
    /// Exact quotient `self / d`. The Bareiss division is provably exact (§2 of
    /// the design); the `debug_assert` guards a bug, `None` the i128 `MIN/-1`
    /// corner.
    fn exact_div(&self, d: &Self) -> Option<Self>;
}

impl DescentInt for i128 {
    fn node_gram(sh: &Shadow, vt: &Vtree, t: usize, p: &Partial) -> Option<BMat<i128>> {
        gram_gen(sh.small.as_ref()?, vt, t, p)
    }
    fn node_eval(sh: &Shadow, vt: &Vtree, t: usize, p: &Partial) -> Option<Vec<i128>> {
        point_eval_gen(sh.small.as_ref()?, vt, t, p)
    }
    fn exact_div(&self, d: &i128) -> Option<i128> {
        let q = self.checked_div(*d)?;
        // Unconditional (NOT debug_assert): a non-exact division is a theory
        // violation that would silently corrupt the canonical form in release;
        // panic rather than return None (BigInt would hit the same inexactness).
        // `%` is safe here — `checked_div` already rejected `d==0` and `MIN/-1`.
        assert_eq!(
            self % d,
            0,
            "bareiss division not exact (i128) — theory violation"
        );
        Some(q)
    }
}

impl DescentInt for BigInt {
    fn node_gram(sh: &Shadow, vt: &Vtree, t: usize, p: &Partial) -> Option<BMat<BigInt>> {
        Some(gram_gen(&sh.big, vt, t, p).expect("BigInt gram is infallible"))
    }
    fn node_eval(sh: &Shadow, vt: &Vtree, t: usize, p: &Partial) -> Option<Vec<BigInt>> {
        Some(point_eval_gen(&sh.big, vt, t, p).expect("BigInt point_eval is infallible"))
    }
    fn exact_div(&self, d: &BigInt) -> Option<BigInt> {
        let (q, r) = self.div_rem(d);
        // Unconditional (the remainder is already computed by div_rem): the
        // last line of defense for the exact-arithmetic invariant.
        assert!(
            r.is_zero(),
            "bareiss division not exact (BigInt) — theory violation"
        );
        Some(q)
    }
}

/// Fraction-free (Bareiss) pivot descent over the integer shadow (design §1).
/// The internal basis `B̃` stays integer via the single-step recurrence
/// `B̃'[a][j] = (p_cur·B̃[a][j] − w̃[a]·B̃[nz][j]) / p_prev` (exact division,
/// applied to EVERY surviving row incl. `w̃[a]=0`), keeping entries
/// subdeterminant-bounded. Since `B̃_k = D_k·B_k` (uniform per-step factor), the
/// zero tests and `nz` selection are identical to the ℚ descent, so the pivots
/// and the returned integer evals are byte-identical. `None` on any i128
/// overflow → the caller reruns the whole node in `BigInt`.
fn descent_gen<T: DescentInt>(
    sh: &Shadow,
    vt: &Vtree,
    t: usize,
    r: usize,
) -> Option<(Vec<Pivot>, Vec<Vec<BigInt>>)> {
    let mut bmat: BMat<T> = BMat::eye(r);
    let mut p_prev = T::one();
    let mut pivots: Vec<Pivot> = Vec::with_capacity(r);
    let mut evals: Vec<Vec<BigInt>> = Vec::with_capacity(r);
    let vars = &vt.node(t).vars;
    for _k in 0..r {
        let mut partial = Partial::default();
        for &v in vars {
            // MSB-first: probe bit 0; if the subspace is dead there, take bit 1.
            partial.set(v, false);
            let gc = T::node_gram(sh, vt, t, &partial)?;
            if bmat.mul(&gc)?.frob(&bmat)?.is_zero() {
                partial.set(v, true);
            }
        }
        let gc = T::node_gram(sh, vt, t, &partial)?;
        let live = !bmat.mul(&gc)?.frob(&bmat)?.is_zero();
        assert!(live, "pivot descent dead end (input not minimized?)");
        pivots.push(Pivot::from_partial(vt, t, &partial));
        let etilde = T::node_eval(sh, vt, t, &partial)?;
        evals.push(etilde.iter().map(|x| x.to_bigint()).collect());
        // w̃ = B̃·ẽ; pivot row = first live coordinate.
        let w = bmat.mul_vec(&etilde)?;
        let nz = w
            .iter()
            .position(|x| !x.is_zero())
            .expect("evaluation functional vanishes on S_m");
        let p_cur = w[nz].clone();
        // Bareiss eliminate-and-drop: every surviving row a != nz.
        let mut rows: Vec<Vec<T>> = Vec::with_capacity(bmat.r.saturating_sub(1));
        for (a_, wa) in w.iter().enumerate() {
            if a_ == nz {
                continue;
            }
            let mut row = Vec::with_capacity(bmat.c);
            for j in 0..bmat.c {
                let num = p_cur
                    .checked_mul(bmat.at(a_, j))?
                    .checked_sub(&wa.checked_mul(bmat.at(nz, j))?)?;
                row.push(num.exact_div(&p_prev)?);
            }
            rows.push(row);
        }
        bmat = BMat::from_rows(rows, r);
        p_prev = p_cur;
    }
    debug_assert!(
        pivots.windows(2).all(|w| w[0] < w[1]),
        "pivots not strictly ascending"
    );
    Some((pivots, evals))
}

/// [`pivot_descent`](super::canonical::pivot_descent_sh) via the fraction-free
/// integer descent: try the i128 fast path, fall back to `BigInt` for the whole
/// node on overflow, then lift the integer evals to the exact `P` matrix
/// (`Q::new(ẽ_i, σ'_t)` — identical to `point_eval_exact`).
pub(crate) fn pivot_descent_bareiss(
    sh: &Shadow,
    vt: &Vtree,
    t: usize,
    r: usize,
) -> (Vec<Pivot>, Mat) {
    let (pivots, evals) = sh
        .small
        .is_some()
        .then(|| descent_gen::<i128>(sh, vt, t, r))
        .flatten()
        .unwrap_or_else(|| {
            descent_gen::<BigInt>(sh, vt, t, r).expect("BigInt descent is infallible")
        });
    let sl = sh.scale_lin(vt, t);
    let p = Mat::from_rows(
        evals
            .iter()
            .map(|e| e.iter().map(|x| Q::new(x.clone(), sl.clone())).collect())
            .collect(),
    );
    (pivots, p)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::atdd::contract::{gram, point_eval};
    use crate::atdd::oracle::{build_from_truthtable, to_q};
    use crate::instances::{tt_hwb, tt_threshold};
    use crate::rng::Rng;

    fn rand_tt(n: usize, rng: &mut Rng) -> Vec<Q> {
        loop {
            let f: Vec<bool> = (0..(1usize << n)).map(|_| rng.chance(2, 5)).collect();
            if f.iter().any(|&b| b) {
                return to_q(&f);
            }
        }
    }

    /// Lemma A: `gram_scaled_q == σ_t · gram` at every node, on fractional
    /// diagrams (this also runs the i128 fast path where entries fit).
    #[test]
    fn gram_scaled_matches_q_times_sigma() {
        let mut rng = Rng::new(0x5EED);
        for trial in 0..12 {
            let n = 3 + rng.below(4);
            let vt = if trial % 2 == 0 {
                Vtree::balanced(n)
            } else {
                Vtree::right_linear(n)
            };
            let f = if trial % 3 == 0 {
                to_q(&tt_hwb(n, &vt))
            } else if trial % 3 == 1 {
                to_q(&tt_threshold(n, n.div_ceil(2)))
            } else {
                rand_tt(n, &mut rng)
            };
            let mut a = build_from_truthtable(&f, &vt);
            crate::atdd::minimize::minimize(&mut a, &vt);
            let sh = Shadow::build(&a, &vt);
            for t in vt.postorder() {
                let none = Partial::default();
                let gq = gram(&a, &vt, t, &none);
                let gs = sh.gram_scaled_q(&vt, t, &none);
                let sigma = Q::from_integer(sh.scale_sq(&vt, t));
                for i in 0..gq.r {
                    for j in 0..gq.c {
                        assert_eq!(gs.at(i, j), &(&sigma * gq.at(i, j)), "node {t} [{i}][{j}]");
                    }
                }
            }
        }
    }

    /// point_eval_exact reproduces the ℚ point_eval exactly.
    #[test]
    fn point_eval_exact_matches_q() {
        let mut rng = Rng::new(0xE7A1);
        for trial in 0..12 {
            let n = 3 + rng.below(4);
            let vt = if trial % 2 == 0 {
                Vtree::balanced(n)
            } else {
                Vtree::right_linear(n)
            };
            let f = if trial % 2 == 0 {
                to_q(&tt_hwb(n, &vt))
            } else {
                rand_tt(n, &mut rng)
            };
            let mut a = build_from_truthtable(&f, &vt);
            crate::atdd::minimize::minimize(&mut a, &vt);
            let sh = Shadow::build(&a, &vt);
            for t in vt.postorder() {
                let mut partial = Partial::default();
                for &v in &vt.node(t).vars {
                    partial.set(v, rng.next_bool());
                }
                let want = point_eval(&a, &vt, t, &partial);
                let got = sh.point_eval_exact(&vt, t, &partial);
                assert_eq!(got, want, "point_eval at node {t}");
            }
        }
    }

    /// The i128 fast path and the BigInt fallback agree bit-for-bit (Gram and
    /// point_eval), so the fallback can never silently disagree.
    #[test]
    fn i128_and_bigint_paths_agree() {
        let mut rng = Rng::new(0x128B16);
        for trial in 0..10 {
            let n = 3 + rng.below(4);
            let vt = if trial % 2 == 0 {
                Vtree::balanced(n)
            } else {
                Vtree::right_linear(n)
            };
            let f = if trial % 2 == 0 {
                to_q(&tt_hwb(n, &vt))
            } else {
                rand_tt(n, &mut rng)
            };
            let mut a = build_from_truthtable(&f, &vt);
            crate::atdd::minimize::minimize(&mut a, &vt);
            let sh = Shadow::build(&a, &vt);
            let small = sh.small.as_ref().expect("small entries fit i128 at n≤6");
            for t in vt.postorder() {
                let none = Partial::default();
                let gi = gram_gen(small, &vt, t, &none).expect("no overflow at n≤6");
                let gb = gram_gen(&sh.big, &vt, t, &none).unwrap();
                assert_eq!(gi.to_q(), gb.to_q(), "gram i128 vs BigInt at {t}");
            }
        }
    }

    /// The fraction-free descent produces identical pivots+evals on the i128 and
    /// BigInt backends (the whole-node fallback can never silently disagree).
    #[test]
    fn bareiss_descent_i128_and_bigint_agree() {
        let mut rng = Rng::new(0xBA5E12);
        for trial in 0..10 {
            let n = 3 + rng.below(4);
            let vt = if trial % 2 == 0 {
                Vtree::balanced(n)
            } else {
                Vtree::right_linear(n)
            };
            let f = if trial % 2 == 0 {
                to_q(&tt_hwb(n, &vt))
            } else {
                rand_tt(n, &mut rng)
            };
            let mut a = build_from_truthtable(&f, &vt);
            crate::atdd::minimize::minimize(&mut a, &vt);
            let sh = Shadow::build(&a, &vt);
            for t in vt.postorder() {
                let r = a.dim(t);
                let (pi, ei) = descent_gen::<i128>(&sh, &vt, t, r).expect("no overflow at n≤6");
                let (pb, eb) = descent_gen::<BigInt>(&sh, &vt, t, r).unwrap();
                assert_eq!(pi, pb, "descent pivots i128 vs BigInt at node {t}");
                assert_eq!(ei, eb, "descent evals i128 vs BigInt at node {t}");
            }
        }
    }
}
