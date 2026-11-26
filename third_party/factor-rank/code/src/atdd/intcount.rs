//! Integer counting kernel: a query-only fast path for exact model counting
//! that removes `BigRational`'s per-operation overhead (heap values + gcd
//! normalization) without giving up exactness.
//!
//! The canonical ℚ-form (`super::canonical`) stays the identity object — this
//! is *only* a query kernel, derived from an already-compiled ATDD. The idea
//! (Stefan, 2026-07-07): entries at a vtree node `t` share a denominator
//! (lem:bits: canonical entries are quotients over `det Q_t`), so multiplying
//! node `t`'s tensor by `D_t = lcm` of its entry denominators clears it to
//! integers. The ones-contraction is multilinear with each node contributing
//! its scale exactly once, so the integer contraction equals `(∏_t D_t) · Σ_τ
//! f(τ)` — one exact division by the single global scalar `∏_t D_t` recovers
//! the count. Boolean `f` ⇒ `Σ_τ f(τ) ∈ ℤ`, so the division is exact.
//!
//! The contraction runs in checked `i128` (register arithmetic, ~2 ns/op) with
//! a `BigInt` fallback on overflow. Whether the fallback is needed is decided
//! once at build time by a dry-run contraction, so `count` never wastes a
//! failed `i128` attempt: `Store::I128` ⇒ both entries and all contraction
//! intermediates fit `i128`; `Store::Big` ⇒ exact but slower.
//!
//! TDD counting already uses register `u128` (one multiply-add per edge), so
//! this trick has no TDD analog — recorded in the BENCHMARKS.md caveats.

use super::linalg::Q;
use super::{Atdd, NodeData};
use crate::vtree::Vtree;
use num_bigint::BigInt;
use num_integer::Integer;
use num_traits::{ToPrimitive, Zero};

/// One node's denominator-cleared integer tensor, generic over the entry
/// width (`i128` fast path or `BigInt` exact fallback).
enum INode<T> {
    /// `d × 2` leaf, row-major (`m[i*2 + col]`).
    Leaf { m: Vec<T>, d: usize },
    /// `d` slices, each `d1 × d2` row-major (`w[i][j*d2 + k]`); the row count
    /// `d1` is implicit in each `s`-vector's length, so only `d2` is stored.
    Internal { w: Vec<Vec<T>>, d2: usize },
}

enum Store {
    I128(Vec<INode<i128>>),
    Big(Vec<INode<BigInt>>),
}

/// A compiled integer model-counting kernel for one ATDD over one vtree.
pub struct IntKernel {
    store: Store,
    /// Global scalar: exact count = (integer contraction) / `denom`.
    denom: BigInt,
    /// Whether the `i128` fast path is in force (for reporting).
    fast: bool,
}

impl IntKernel {
    /// Build the kernel from a compiled ATDD (compile-time step; not timed as
    /// part of a query). `a.node[id]` is indexed by vtree-node id.
    pub fn build(a: &Atdd, vt: &Vtree) -> IntKernel {
        // Clear each node's denominator; accumulate the global scale ∏_t D_t.
        let mut denom = BigInt::from(1);
        let mut big_nodes: Vec<INode<BigInt>> = Vec::with_capacity(a.node.len());
        let mut fits = true;
        for nd in &a.node {
            // D_t = lcm of the node's (reduced, positive) entry denominators;
            // folded over the entry iterator directly (no intermediate Vec).
            let mut d_t = BigInt::from(1);
            match nd {
                NodeData::Leaf(m) => {
                    for e in m.entries() {
                        d_t = d_t.lcm(e.denom());
                    }
                }
                NodeData::Internal(w) => {
                    for e in w.iter().flat_map(|wi| wi.entries()) {
                        d_t = d_t.lcm(e.denom());
                    }
                }
            }
            denom *= &d_t;
            let clear = |e: &Q| -> BigInt {
                // exact: e.numer() * (D_t / e.denom())  (D_t is a multiple).
                e.numer() * (&d_t / e.denom())
            };
            let node = match nd {
                NodeData::Leaf(m) => {
                    let mut flat = Vec::with_capacity(m.r * 2);
                    for i in 0..m.r {
                        flat.push(clear(m.at(i, 0)));
                        flat.push(clear(m.at(i, 1)));
                    }
                    for x in &flat {
                        fits &= x.to_i128().is_some();
                    }
                    INode::Leaf { m: flat, d: m.r }
                }
                NodeData::Internal(w) => {
                    let d2 = w[0].c;
                    let slices: Vec<Vec<BigInt>> = w
                        .iter()
                        .map(|wi| {
                            let mut flat = Vec::with_capacity(wi.r * wi.c);
                            for i in 0..wi.r {
                                for j in 0..wi.c {
                                    let x = clear(wi.at(i, j));
                                    fits &= x.to_i128().is_some();
                                    flat.push(x);
                                }
                            }
                            flat
                        })
                        .collect();
                    INode::Internal { w: slices, d2 }
                }
            };
            big_nodes.push(node);
        }

        // Promote to i128 storage and dry-run the contraction; if either the
        // entries or any intermediate overflow, keep the BigInt store.
        if fits {
            let i128_nodes = to_i128(&big_nodes);
            if contract_i128(&i128_nodes, vt).is_some() {
                return IntKernel {
                    store: Store::I128(i128_nodes),
                    denom,
                    fast: true,
                };
            }
        }
        IntKernel {
            store: Store::Big(big_nodes),
            denom,
            fast: false,
        }
    }

    /// Whether the `i128` fast path is active (else the `BigInt` fallback).
    pub fn is_fast(&self) -> bool {
        self.fast
    }

    /// Exact model count `Σ_τ f(τ)` via the integer ones-contraction.
    pub fn count(&self, vt: &Vtree) -> BigInt {
        let raw = match &self.store {
            // `I128` store implies the dry run fit, so `unwrap` cannot fail
            // (the compiled ATDD is immutable between build and query).
            Store::I128(nodes) => BigInt::from(contract_i128(nodes, vt).unwrap()),
            Store::Big(nodes) => contract_big(nodes, vt),
        };
        let (q, r) = raw.div_rem(&self.denom);
        debug_assert!(r.is_zero(), "integer count not divisible by ∏ D_t");
        q
    }
}

fn to_i128(nodes: &[INode<BigInt>]) -> Vec<INode<i128>> {
    nodes
        .iter()
        .map(|n| match n {
            INode::Leaf { m, d } => INode::Leaf {
                m: m.iter().map(|x| x.to_i128().unwrap()).collect(),
                d: *d,
            },
            INode::Internal { w, d2 } => INode::Internal {
                w: w.iter()
                    .map(|s| s.iter().map(|x| x.to_i128().unwrap()).collect())
                    .collect(),
                d2: *d2,
            },
        })
        .collect()
}

/// Checked `i128` ones-contraction to the root count; `None` on any overflow.
fn contract_i128(nodes: &[INode<i128>], vt: &Vtree) -> Option<i128> {
    let mut memo: Vec<Option<Vec<i128>>> = vec![None; vt.num_nodes()];
    for x in vt.postorder() {
        let node = vt.node(x);
        let s: Vec<i128> = match &nodes[x] {
            // Checked even at leaves — symmetric with `bilinear_i128`, so no
            // silent wrap can slip past the build-time dry run.
            INode::Leaf { m, d } => (0..*d)
                .map(|i| m[i * 2].checked_add(m[i * 2 + 1]))
                .collect::<Option<Vec<i128>>>()?,
            INode::Internal { w, d2 } => {
                let s1 = memo[node.left.unwrap()].as_ref().unwrap();
                let s2 = memo[node.right.unwrap()].as_ref().unwrap();
                let mut out = Vec::with_capacity(w.len());
                for wi in w {
                    out.push(bilinear_i128(s1, wi, s2, *d2)?);
                }
                out
            }
        };
        memo[x] = Some(s);
    }
    Some(memo[vt.root()].take().unwrap()[0])
}

/// `s1ᵀ · W · s2` in checked `i128`, zero-skipped; `None` on overflow.
fn bilinear_i128(s1: &[i128], w: &[i128], s2: &[i128], d2: usize) -> Option<i128> {
    let mut acc: i128 = 0;
    for (j, &x) in s1.iter().enumerate() {
        if x == 0 {
            continue;
        }
        for (k, &y) in s2.iter().enumerate() {
            let wjk = w[j * d2 + k];
            if y == 0 || wjk == 0 {
                continue;
            }
            let t = x.checked_mul(wjk)?.checked_mul(y)?;
            acc = acc.checked_add(t)?;
        }
    }
    Some(acc)
}

/// Exact `BigInt` ones-contraction (no gcd normalization — integer tensors).
fn contract_big(nodes: &[INode<BigInt>], vt: &Vtree) -> BigInt {
    let mut memo: Vec<Option<Vec<BigInt>>> = vec![None; vt.num_nodes()];
    for x in vt.postorder() {
        let node = vt.node(x);
        let s: Vec<BigInt> = match &nodes[x] {
            INode::Leaf { m, d } => (0..*d).map(|i| &m[i * 2] + &m[i * 2 + 1]).collect(),
            INode::Internal { w, d2 } => {
                let s1 = memo[node.left.unwrap()].as_ref().unwrap();
                let s2 = memo[node.right.unwrap()].as_ref().unwrap();
                w.iter().map(|wi| bilinear_big(s1, wi, s2, *d2)).collect()
            }
        };
        memo[x] = Some(s);
    }
    memo[vt.root()].take().unwrap().swap_remove(0)
}

fn bilinear_big(s1: &[BigInt], w: &[BigInt], s2: &[BigInt], d2: usize) -> BigInt {
    let mut acc = BigInt::zero();
    for (j, x) in s1.iter().enumerate() {
        if x.is_zero() {
            continue;
        }
        for (k, y) in s2.iter().enumerate() {
            let wjk = &w[j * d2 + k];
            if !y.is_zero() && !wjk.is_zero() {
                acc += x * wjk * y;
            }
        }
    }
    acc
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::atdd::canonical::canonicalize;
    use crate::atdd::minimize::minimize;
    use crate::atdd::oracle::{build_from_truthtable, to_q};
    use crate::instances::{tt_hwb, tt_mux, tt_parity, tt_threshold};
    use crate::vtree::Vtree;

    /// The integer kernel reproduces the ℚ ones-contraction exactly, across
    /// families (0/1-entry MUX/PARITY and fractional-interpolator HWB/THR).
    fn check(tt: &[bool], vt: &Vtree) {
        let qf = to_q(tt);
        let mut a = build_from_truthtable(&qf, vt);
        minimize(&mut a, vt);
        canonicalize(&mut a, vt);
        let want = crate::atdd::contract::model_count(&a, vt).to_integer();
        let k = IntKernel::build(&a, vt);
        assert_eq!(k.count(vt), want, "int kernel count mismatch");
    }

    #[test]
    fn matches_rational_kernel() {
        for n in [4usize, 6, 8] {
            check(&tt_parity(n), &Vtree::right_linear(n));
            check(&tt_parity(n), &Vtree::balanced(n));
        }
        for n in [4usize, 6, 8, 10] {
            let vt = Vtree::right_linear(n);
            check(&tt_hwb(n, &vt), &vt);
            check(&tt_hwb(n, &vt), &Vtree::balanced(n));
        }
        for n in [6usize, 8, 10] {
            check(&tt_threshold(n, n.div_ceil(2)), &Vtree::balanced(n));
        }
        for k in [2usize, 3] {
            let n = k + (1 << k);
            let vt = Vtree::right_linear(n);
            check(&tt_mux(k, &vt), &Vtree::mux_data(k));
        }
    }

    /// MUX has 0/1 canonical entries ⇒ denom = 1 ⇒ the fast i128 path is used.
    #[test]
    fn mux_uses_fast_path() {
        let k = 3;
        let n = k + (1 << k);
        let vt = Vtree::right_linear(n);
        let qf = to_q(&tt_mux(k, &vt));
        let vd = Vtree::mux_data(k);
        let mut a = build_from_truthtable(&qf, &vd);
        minimize(&mut a, &vd);
        canonicalize(&mut a, &vd);
        let kern = IntKernel::build(&a, &vd);
        assert!(kern.is_fast(), "MUX (0/1 entries) should use the i128 path");
        assert_eq!(kern.count(&vd), BigInt::from(1u64 << (n - 1)));
    }
}
