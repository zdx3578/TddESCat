//! Exact rational linear algebra for the ATDD backend (`FABLE_NOTES/02` §1;
//! `atdd_toy.py` 30–85).
//!
//! `Mat` is a dims-carrying row-major matrix over `Q = BigRational`, so that
//! `0×k` and `k×0` matrices are representable (the Python toy crashes on
//! these). Invariant (Q-INV): every stored `Q` is reduced with positive
//! denominator — guaranteed by `Ratio::new`/arithmetic; `Ratio::new_raw` is
//! banned in this crate. Under (Q-INV), structural `==`/`Hash` agree with
//! mathematical equality.
//!
//! `rref` follows the toy exactly: first nonzero pivot at/below `r` (no
//! magnitude pivoting), pivot row normalized *before* elimination, full
//! Gauss–Jordan in one pass, zero rows dropped. In exact arithmetic RREF is
//! unique per row space, so this matches the Python oracle bit-for-bit.

use num_traits::{One, Zero};

pub type Q = num_rational::BigRational;

/// Convenience integer→`Q` conversion (reduced by construction).
pub fn q(n: i64) -> Q {
    Q::from_integer(n.into())
}

/// A `Q`-matrix with explicit dimensions; `e.len() == r * c`, row-major.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Mat {
    pub r: usize,
    pub c: usize,
    e: Vec<Q>,
}

/// A square matrix with no inverse (returned by [`Mat::inv`]).
#[derive(Debug, PartialEq, Eq)]
pub struct Singular;

impl Mat {
    pub fn zero(r: usize, c: usize) -> Mat {
        Mat {
            r,
            c,
            e: vec![Q::zero(); r * c],
        }
    }

    pub fn eye(n: usize) -> Mat {
        let mut m = Mat::zero(n, n);
        for i in 0..n {
            *m.at_mut(i, i) = Q::one();
        }
        m
    }

    /// The `1×1` matrix `[x]`.
    pub fn from_scalar(x: Q) -> Mat {
        Mat {
            r: 1,
            c: 1,
            e: vec![x],
        }
    }

    pub fn from_fn(r: usize, c: usize, mut f: impl FnMut(usize, usize) -> Q) -> Mat {
        let mut e = Vec::with_capacity(r * c);
        for i in 0..r {
            for j in 0..c {
                e.push(f(i, j));
            }
        }
        Mat { r, c, e }
    }

    /// Build from explicit rows (all the same length; `rows` may be empty only
    /// via [`Mat::zero`], which carries the column count).
    pub fn from_rows(rows: Vec<Vec<Q>>) -> Mat {
        let r = rows.len();
        let c = rows.first().map_or(0, Vec::len);
        let mut e = Vec::with_capacity(r * c);
        for row in rows {
            assert_eq!(row.len(), c, "ragged rows");
            e.extend(row);
        }
        Mat { r, c, e }
    }

    #[inline]
    pub fn at(&self, i: usize, j: usize) -> &Q {
        debug_assert!(i < self.r && j < self.c);
        &self.e[i * self.c + j]
    }

    #[inline]
    pub fn at_mut(&mut self, i: usize, j: usize) -> &mut Q {
        debug_assert!(i < self.r && j < self.c);
        &mut self.e[i * self.c + j]
    }

    #[inline]
    pub fn row(&self, i: usize) -> &[Q] {
        &self.e[i * self.c..(i + 1) * self.c]
    }

    /// Iterate over the entries of row-major storage (for stats/serialization).
    pub fn entries(&self) -> impl Iterator<Item = &Q> {
        self.e.iter()
    }

    /// Matrix product with the toy's zero-skips (a `Q` multiply-by-zero still
    /// allocates, and minimized networks are sparse).
    pub fn mul(&self, b: &Mat) -> Mat {
        assert_eq!(self.c, b.r, "shape mismatch in mul");
        let mut out = Mat::zero(self.r, b.c);
        for i in 0..self.r {
            for k in 0..self.c {
                let a = self.at(i, k);
                if a.is_zero() {
                    continue;
                }
                for j in 0..b.c {
                    let x = b.at(k, j);
                    if !x.is_zero() {
                        *out.at_mut(i, j) += a * x;
                    }
                }
            }
        }
        out
    }

    /// Matrix–vector product `self · v` (zero-skipped).
    pub fn mul_vec(&self, v: &[Q]) -> Vec<Q> {
        assert_eq!(self.c, v.len(), "shape mismatch in mul_vec");
        let mut out = vec![Q::zero(); self.r];
        for (i, oi) in out.iter_mut().enumerate() {
            for (k, vk) in v.iter().enumerate() {
                let a = self.at(i, k);
                if !a.is_zero() && !vk.is_zero() {
                    *oi += a * vk;
                }
            }
        }
        out
    }

    pub fn transpose(&self) -> Mat {
        let mut out = Mat::zero(self.c, self.r);
        for i in 0..self.r {
            for j in 0..self.c {
                if !self.at(i, j).is_zero() {
                    *out.at_mut(j, i) = self.at(i, j).clone();
                }
            }
        }
        out
    }

    /// `self += coeff * other` entrywise (zero-skipped).
    pub fn axpy(&mut self, coeff: &Q, other: &Mat) {
        assert_eq!(
            (self.r, self.c),
            (other.r, other.c),
            "shape mismatch in axpy"
        );
        if coeff.is_zero() {
            return;
        }
        for (x, y) in self.e.iter_mut().zip(&other.e) {
            if !y.is_zero() {
                *x += coeff * y;
            }
        }
    }

    /// Frobenius inner product `Σ_{i,j} self[i][j] * other[i][j]` (zero-skipped).
    pub fn frob(&self, other: &Mat) -> Q {
        assert_eq!(
            (self.r, self.c),
            (other.r, other.c),
            "shape mismatch in frob"
        );
        let mut s = Q::zero();
        for (x, y) in self.e.iter().zip(&other.e) {
            if !x.is_zero() && !y.is_zero() {
                s += x * y;
            }
        }
        s
    }

    pub fn trace(&self) -> Q {
        debug_assert_eq!(self.r, self.c);
        let mut s = Q::zero();
        for i in 0..self.r {
            s += self.at(i, i);
        }
        s
    }

    /// Horizontal concatenation `[self | b]`.
    pub fn hcat(&self, b: &Mat) -> Mat {
        assert_eq!(self.r, b.r, "shape mismatch in hcat");
        let mut out = Mat::zero(self.r, self.c + b.c);
        for i in 0..self.r {
            for j in 0..self.c {
                *out.at_mut(i, j) = self.at(i, j).clone();
            }
            for j in 0..b.c {
                *out.at_mut(i, self.c + j) = b.at(i, j).clone();
            }
        }
        out
    }

    /// The submatrix of columns `from..` (used by `inv`).
    pub fn cols_from(&self, from: usize) -> Mat {
        Mat::from_fn(self.r, self.c - from, |i, j| self.at(i, from + j).clone())
    }

    /// The submatrix with the given columns (in the given order).
    pub fn cols(&self, cols: &[usize]) -> Mat {
        Mat::from_fn(self.r, cols.len(), |i, j| self.at(i, cols[j]).clone())
    }

    /// The submatrix with the given rows and columns (in the given orders).
    pub fn submatrix(&self, rows: &[usize], cols: &[usize]) -> Mat {
        Mat::from_fn(rows.len(), cols.len(), |i, j| {
            self.at(rows[i], cols[j]).clone()
        })
    }

    fn swap_rows(&mut self, a: usize, b: usize) {
        if a == b {
            return;
        }
        for j in 0..self.c {
            self.e.swap(a * self.c + j, b * self.c + j);
        }
    }

    /// Reduced row echelon form (toy `rref`). Input unchanged. Returns
    /// `(R, piv)`: `R` has exactly `rank` rows (zero rows dropped), same column
    /// count; `piv` = pivot column indices, strictly ascending. Pivot = first
    /// nonzero row at/below `r`; the pivot row is normalized *before*
    /// eliminating above and below (order is load-bearing).
    pub fn rref(&self) -> (Mat, Vec<usize>) {
        let mut rr = self.clone();
        let (rows, cols) = (rr.r, rr.c);
        let mut piv = Vec::new();
        let mut r = 0usize;
        for c in 0..cols {
            let Some(sel) = (r..rows).find(|&i| !rr.at(i, c).is_zero()) else {
                continue;
            };
            rr.swap_rows(r, sel);
            let inv = rr.at(r, c).recip();
            for j in 0..cols {
                if !rr.at(r, j).is_zero() {
                    let v = rr.at(r, j) * &inv;
                    *rr.at_mut(r, j) = v;
                }
            }
            let prow: Vec<Q> = rr.row(r).to_vec();
            for i in 0..rows {
                if i != r && !rr.at(i, c).is_zero() {
                    let f = rr.at(i, c).clone();
                    for (j, pj) in prow.iter().enumerate() {
                        if !pj.is_zero() {
                            let v = rr.at(i, j) - &f * pj;
                            *rr.at_mut(i, j) = v;
                        }
                    }
                }
            }
            piv.push(c);
            r += 1;
            if r == rows {
                break;
            }
        }
        rr.e.truncate(r * cols);
        rr.r = r;
        (rr, piv)
    }

    pub fn rank(&self) -> usize {
        if self.r == 0 || self.c == 0 {
            0
        } else {
            self.rref().1.len()
        }
    }

    /// Inverse via `rref([A | I])` (toy `mat_inv`), or `Err(Singular)`.
    pub fn inv(&self) -> Result<Mat, Singular> {
        let n = self.r;
        assert_eq!(self.c, n, "inv needs a square matrix");
        let aug = self.hcat(&Mat::eye(n));
        let (rr, piv) = aug.rref();
        if rr.r != n || piv != (0..n).collect::<Vec<_>>() {
            return Err(Singular);
        }
        Ok(rr.cols_from(n))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rng::Rng;
    use num_bigint::BigInt;

    /// Random small rational: numerator in [-3,3], denominator in [1,4].
    fn rand_q(rng: &mut Rng) -> Q {
        let num = rng.below(7) as i64 - 3;
        let den = 1 + rng.below(4) as i64;
        Q::new(num.into(), den.into())
    }

    #[test]
    fn q_inv_semantics() {
        // The §0.1 port-time verification of num-rational semantics.
        assert_eq!(
            Q::new(2.into(), 4.into()),
            Q::new(1.into(), 2.into()),
            "Ratio::new must reduce"
        );
        // sign normalization: -1/-2 == 1/2, den > 0
        let x = Q::new((-1).into(), (-2).into());
        assert_eq!(x, Q::new(1.into(), 2.into()));
        assert!(x.denom() > &BigInt::from(0));
        // bits() semantics match Python int.bit_length()
        assert_eq!(BigInt::from(0).bits(), 0);
        assert_eq!(BigInt::from(-6).bits(), 3);
        // reference ops compile and reduce
        let a = Q::new(1.into(), 2.into());
        let b = Q::new(2.into(), 3.into());
        assert_eq!(&a * &b, Q::new(1.into(), 3.into()));
    }

    #[test]
    fn rref_hand_checked() {
        // [[1,2],[2,4]] -> R = [[1,2]], piv = [0]
        let m = Mat::from_rows(vec![vec![q(1), q(2)], vec![q(2), q(4)]]);
        let (r, piv) = m.rref();
        assert_eq!(piv, vec![0]);
        assert_eq!(r.r, 1);
        assert_eq!(r.row(0), &[q(1), q(2)]);
        // [[0,1],[1,0]] -> I, piv [0,1]
        let m = Mat::from_rows(vec![vec![q(0), q(1)], vec![q(1), q(0)]]);
        let (r, piv) = m.rref();
        assert_eq!(piv, vec![0, 1]);
        assert_eq!(r, Mat::eye(2));
        // fractional pivots: [[2,1],[1,1]] -> I
        let m = Mat::from_rows(vec![vec![q(2), q(1)], vec![q(1), q(1)]]);
        let (r, _) = m.rref();
        assert_eq!(r, Mat::eye(2));
    }

    #[test]
    fn rref_properties_random() {
        let mut rng = Rng::new(0xA7DD);
        for _ in 0..200 {
            let r = 1 + rng.below(5);
            let c = 1 + rng.below(5);
            let m = Mat::from_fn(r, c, |_, _| rand_q(&mut rng));
            let (rr, piv) = m.rref();
            // pivot count == row count of R; pivots strictly ascending
            assert_eq!(rr.r, piv.len());
            assert!(piv.windows(2).all(|w| w[0] < w[1]));
            // pivot structure: R[i][piv[i]] == 1, zeros above/below
            for (i, &p) in piv.iter().enumerate() {
                for ii in 0..rr.r {
                    let want = if ii == i { q(1) } else { q(0) };
                    assert_eq!(*rr.at(ii, p), want);
                }
                // entries left of the pivot are 0
                for j in 0..p {
                    if !piv[..i].contains(&j) {
                        assert_eq!(*rr.at(i, j), q(0), "nonzero left of pivot");
                    }
                }
            }
            // rank(R) == rank(M) (idempotence of rref row count)
            assert_eq!(rr.rank(), piv.len());
            // rref is invariant under row shuffles (uniqueness per row space)
            let mut rows: Vec<Vec<Q>> = (0..r).map(|i| m.row(i).to_vec()).collect();
            rng.shuffle(&mut rows);
            let (rr2, piv2) = Mat::from_rows(rows).rref();
            assert_eq!(rr, rr2);
            assert_eq!(piv, piv2);
        }
    }

    #[test]
    fn inv_random() {
        let mut rng = Rng::new(0xB0);
        let mut inverted = 0;
        for _ in 0..100 {
            let n = 1 + rng.below(4);
            let m = Mat::from_fn(n, n, |_, _| rand_q(&mut rng));
            match m.inv() {
                Ok(mi) => {
                    assert_eq!(m.mul(&mi), Mat::eye(n));
                    assert_eq!(mi.mul(&m), Mat::eye(n));
                    inverted += 1;
                }
                Err(Singular) => assert!(m.rank() < n),
            }
        }
        assert!(inverted > 20, "too few invertible samples: {inverted}");
        // singular matrix is rejected
        let m = Mat::from_rows(vec![vec![q(1), q(2)], vec![q(2), q(4)]]);
        assert_eq!(m.inv(), Err(Singular));
    }

    #[test]
    fn degenerate_shapes() {
        // 0xk and kx0 matrices must not crash (the toy does).
        let z = Mat::zero(0, 3);
        assert_eq!(z.rank(), 0);
        let z2 = Mat::zero(3, 0);
        assert_eq!(z2.rank(), 0);
        let m = Mat::from_fn(3, 2, |i, j| q((i + j) as i64));
        // (0x3)·(3x2) = 0x2
        let p = z.mul(&m);
        assert_eq!((p.r, p.c), (0, 2));
        // transpose of 0x3 is 3x0
        let t = z.transpose();
        assert_eq!((t.r, t.c), (3, 0));
    }

    #[test]
    fn mul_transpose_hand() {
        let a = Mat::from_rows(vec![vec![q(1), q(2)], vec![q(3), q(4)]]);
        let b = Mat::from_rows(vec![vec![q(0), q(1)], vec![q(1), q(0)]]);
        assert_eq!(
            a.mul(&b),
            Mat::from_rows(vec![vec![q(2), q(1)], vec![q(4), q(3)]])
        );
        assert_eq!(
            a.transpose(),
            Mat::from_rows(vec![vec![q(1), q(3)], vec![q(2), q(4)]])
        );
        assert_eq!(a.trace(), q(5));
        assert_eq!(a.frob(&b), q(2) + q(3));
        assert_eq!(a.mul_vec(&[q(1), q(1)]), vec![q(3), q(7)]);
    }
}
