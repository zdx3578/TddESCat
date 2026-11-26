//! `arith_sweep` — bounded confirmation experiment (structural metric only).
//!
//! For two arithmetic-circuit output-bit truth tables over `2k` input
//! variables — the ADDER bit `m` of `a + b` and the MULTIPLIER bit `m` of
//! `a * b`, with `a = x_0..x_{k-1}` (the low `k` bits of the assignment index)
//! and `b = x_k..x_{2k-1}` (the high `k` bits) — enumerate ALL variable
//! bipartitions `(Y | rest)` and measure, at each cut:
//!   * `S`   = number of DISTINCT NONZERO rows of the cut matrix (count width),
//!   * `rho` = rank of the cut matrix over ℚ (factor rank).
//!
//! A "gap" is `S > rho`. This confirms the predicted taxonomy (`ARITH_RESULT.md`)
//! by direct measurement — no compiler, no vtree search, one local run.
//!
//! `rho` in the bulk sweep is computed over a large prime field
//! (`P1 = 2^61 − 1`); for 0/1 matrices `rank_{GF(p)} = rank_ℚ` with overwhelming
//! probability, and the sandwich assertion `S ≤ 2^rho − 1` catches any
//! (astronomically unlikely) prime-specific rank drop. Every headline integer
//! (operand-cut `S,rho`; carry-out; the multiplier small cases; and each
//! family's global-max cut) is confirmed a second way: exact BigRational rank
//! for `n ≤ 12`, and independent agreement of a second prime `P2 = 2^31 − 1`
//! for all `n` (two Mersenne primes agreeing ⇒ exact with certainty for these
//! sizes).

use atddc::atdd::linalg::{Mat, Q};
use num_traits::{One, Zero};
use rustc_hash::FxHashSet;

const P1: u64 = 2_305_843_009_213_693_951; // 2^61 - 1 (Mersenne prime)
const P2: u64 = 2_147_483_647; // 2^31 - 1 (Mersenne prime), independent cross-check
const EXACT_Q_MAX_N: usize = 14; // build a BigRational rank up to 128×128 cuts

// ---- prime-field arithmetic --------------------------------------------------

fn mulmod(a: u64, b: u64, p: u64) -> u64 {
    ((a as u128 * b as u128) % p as u128) as u64
}

fn powmod(mut a: u64, mut e: u64, p: u64) -> u64 {
    let mut r = 1u64 % p;
    a %= p;
    while e > 0 {
        if e & 1 == 1 {
            r = mulmod(r, a, p);
        }
        a = mulmod(a, a, p);
        e >>= 1;
    }
    r
}

fn invmod(a: u64, p: u64) -> u64 {
    powmod(a, p - 2, p) // Fermat: a^{p-2} ≡ a^{-1} (mod p)
}

// ---- generators --------------------------------------------------------------

/// Bit `m` of `a + b`, where `a` = low `k` bits and `b` = high `k` bits of the
/// `2k`-bit assignment index (variable `v` is bit `v`). Bit `m` of `x` is
/// `(x >> m) & 1`.
fn tt_addbit(k: usize, m: usize) -> Vec<bool> {
    let n = 2 * k;
    let mask = (1usize << k) - 1;
    (0..(1usize << n))
        .map(|idx| {
            let a = idx & mask;
            let b = (idx >> k) & mask;
            ((a + b) >> m) & 1 == 1
        })
        .collect()
}

/// Bit `m` of `a * b`, same variable layout as [`tt_addbit`].
fn tt_multbit(k: usize, m: usize) -> Vec<bool> {
    let n = 2 * k;
    let mask = (1usize << k) - 1;
    (0..(1usize << n))
        .map(|idx| {
            let a = idx & mask;
            let b = (idx >> k) & mask;
            ((a * b) >> m) & 1 == 1
        })
        .collect()
}

// ---- cut construction --------------------------------------------------------

/// Spread the bits of `v` (LSB→MSB) into the target positions `pos`.
fn scatter(v: usize, pos: &[usize]) -> usize {
    let mut out = 0;
    for (t, &p) in pos.iter().enumerate() {
        if (v >> t) & 1 == 1 {
            out |= 1 << p;
        }
    }
    out
}

/// Row/column variable lists for the bipartition `Y = ymask` over `n` vars.
fn split(n: usize, ymask: usize) -> (Vec<usize>, Vec<usize>) {
    let yv = (0..n).filter(|&v| (ymask >> v) & 1 == 1).collect();
    let rv = (0..n).filter(|&v| (ymask >> v) & 1 == 0).collect();
    (yv, rv)
}

/// `(S, rho)` at the cut `Y = ymask`: `S` = distinct nonzero rows (exact,
/// combinatorial), `rho` = rank over the prime field `prime`.
fn measure_cut(f: &[bool], n: usize, ymask: usize, prime: u64) -> (usize, usize) {
    let (yvars, rvars) = split(n, ymask);
    let nrow = 1usize << yvars.len();
    let ncol = 1usize << rvars.len();
    let yscat: Vec<usize> = (0..nrow).map(|iy| scatter(iy, &yvars)).collect();
    let rscat: Vec<usize> = (0..ncol).map(|ir| scatter(ir, &rvars)).collect();
    let words = ncol.div_ceil(64);
    let mut field: Vec<Vec<u64>> = vec![vec![0u64; ncol]; nrow];
    let mut seen: FxHashSet<Vec<u64>> = FxHashSet::default();
    let mut bitrow = vec![0u64; words];
    for iy in 0..nrow {
        let yb = yscat[iy];
        bitrow.iter_mut().for_each(|w| *w = 0);
        let frow = &mut field[iy];
        let mut nonzero = false;
        for (ir, &rb) in rscat.iter().enumerate() {
            if f[yb | rb] {
                frow[ir] = 1;
                bitrow[ir >> 6] |= 1u64 << (ir & 63);
                nonzero = true;
            }
        }
        if nonzero {
            seen.insert(bitrow.clone());
        }
    }
    (seen.len(), rank_mod(&mut field, prime))
}

/// Rank over `GF(p)` by forward Gaussian elimination (input consumed).
fn rank_mod(mat: &mut [Vec<u64>], p: u64) -> usize {
    let rows = mat.len();
    if rows == 0 {
        return 0;
    }
    let cols = mat[0].len();
    let mut rank = 0;
    for col in 0..cols {
        let Some(pr) = (rank..rows).find(|&r| mat[r][col] != 0) else {
            continue;
        };
        mat.swap(rank, pr);
        let pivinv = invmod(mat[rank][col], p);
        for r in (rank + 1)..rows {
            let coef = mat[r][col];
            if coef != 0 {
                let factor = mulmod(coef, pivinv, p);
                for c in col..cols {
                    let pv = mat[rank][c];
                    if pv != 0 {
                        let sub = mulmod(factor, pv, p);
                        let x = mat[r][c];
                        mat[r][c] = if x >= sub { x - sub } else { x + p - sub };
                    }
                }
            }
        }
        rank += 1;
        if rank == rows {
            break;
        }
    }
    rank
}

/// Exact rank over ℚ of the cut matrix (reuses the crate's BigRational RREF).
fn rank_q(f: &[bool], n: usize, ymask: usize) -> usize {
    let (yvars, rvars) = split(n, ymask);
    let nrow = 1usize << yvars.len();
    let ncol = 1usize << rvars.len();
    let yscat: Vec<usize> = (0..nrow).map(|iy| scatter(iy, &yvars)).collect();
    let rscat: Vec<usize> = (0..ncol).map(|ir| scatter(ir, &rvars)).collect();
    let m = Mat::from_fn(nrow, ncol, |i, j| {
        if f[yscat[i] | rscat[j]] {
            Q::one()
        } else {
            Q::zero()
        }
    });
    m.rank()
}

/// Confirm `rho` at a headline cut: P1, P2 (and exact ℚ when `n ≤ 12`) must all
/// agree. Returns the confirmed `rho`; panics on any disagreement.
fn confirm_rho(f: &[bool], n: usize, ymask: usize) -> usize {
    let (_, r1) = measure_cut(f, n, ymask, P1);
    let (_, r2) = measure_cut(f, n, ymask, P2);
    assert_eq!(
        r1, r2,
        "prime cross-check disagreed at ymask {ymask} (n={n})"
    );
    if n <= EXACT_Q_MAX_N {
        let rq = rank_q(f, n, ymask);
        assert_eq!(rq, r1, "exact ℚ rank disagreed at ymask {ymask} (n={n})");
    }
    r1
}

// ---- reporting ---------------------------------------------------------------

/// Human label for a bipartition: which vars are `a`-bits vs `b`-bits.
fn label_cut(n: usize, k: usize, ymask: usize) -> String {
    let (yvars, _) = split(n, ymask);
    let parts: Vec<String> = yvars
        .iter()
        .map(|&v| {
            if v < k {
                format!("a{v}")
            } else {
                format!("b{}", v - k)
            }
        })
        .collect();
    format!("{{{}}}", parts.join(","))
}

/// Full bipartition sweep of `f` (an instance over `n` vars), plus exact
/// confirmation of the operand cut and the global-max cut. Returns the
/// operand-cut `(S, rho)` for the caller's prediction check.
fn sweep(label: &str, f: &[bool], n: usize, k: usize) -> (usize, usize) {
    // Liveness: for the tested bits every one of the 2k inputs is live, so
    // there are no dead variables to deduplicate (dead vars would only
    // duplicate rows/cols and leave S, rho unchanged anyway).
    for v in 0..n {
        let live = (0..(1usize << n)).any(|idx| f[idx] != f[idx ^ (1usize << v)]);
        assert!(live, "[{label}] variable {v} is dead (unexpected)");
    }

    let full = (1usize << n) - 1;
    let operand = (1usize << k) - 1; // Y = a-bits {0..k-1}
    let mut max_ratio = 0.0f64;
    let mut argmax = operand;
    let mut max_s = 0;
    let mut max_rho = 1;
    let mut gap_cuts = 0usize;
    let mut sandwich_fixups = 0usize;

    for ymask in 1..full {
        let (s, mut rho) = measure_cut(f, n, ymask, P1);
        assert!(
            rho <= s,
            "[{label}] rho>S at ymask {ymask}: rho={rho} S={s}"
        );
        // Sandwich upper bound; a violation means the prime dropped rank —
        // recompute that (astronomically rare) cut exactly. Only checkable
        // when 2^rho − 1 can't be exceeded by S ≤ 2^13 trivially, i.e. rho<14.
        if rho > 0 && rho < 14 && s >= (1usize << rho) {
            let exact = confirm_rho(f, n, ymask);
            assert!(
                exact >= rho && s < (1usize << exact),
                "[{label}] genuine sandwich violation at ymask {ymask}: S={s} rho={exact}"
            );
            rho = exact;
            sandwich_fixups += 1;
        }
        if s > rho {
            gap_cuts += 1;
        }
        if rho > 0 {
            let ratio = s as f64 / rho as f64;
            if ratio > max_ratio {
                max_ratio = ratio;
                argmax = ymask;
                max_s = s;
                max_rho = rho;
            }
        }
    }

    // Exact confirmation of the two reported cuts.
    let (op_s, _) = measure_cut(f, n, operand, P1);
    let operand_rho = confirm_rho(f, n, operand);
    let argmax_rho = confirm_rho(f, n, argmax);
    assert_eq!(argmax_rho, max_rho, "[{label}] argmax rho mismatch");

    println!(
        "[{label}] operand-cut Y={:<22} S={:>4} rho={:>4} ratio={:.4}",
        label_cut(n, k, operand),
        op_s,
        operand_rho,
        op_s as f64 / operand_rho as f64,
    );
    println!(
        "           global-max Y={:<22} S={:>4} rho={:>4} ratio={:.4}{}",
        label_cut(n, k, argmax),
        max_s,
        max_rho,
        max_s as f64 / max_rho as f64,
        if argmax == operand {
            "  (= operand cut)"
        } else {
            ""
        },
    );
    println!(
        "           gap cuts (S>rho): {}/{}   sandwich fixups: {}",
        gap_cuts,
        full - 1,
        sandwich_fixups,
    );

    (op_s, operand_rho)
}

/// The interleaved (low-order block) cuts of the adder: `Y` = the low `j`
/// bit-pairs `{a_0..a_{j-1}, b_0..b_{j-1}}`. Only the 1-bit carry crosses.
fn interleaved_report(f: &[bool], n: usize, k: usize) {
    print!("           interleaved cuts (low j bit-pairs):");
    for j in 1..k {
        let ymask = ((1usize << j) - 1) | (((1usize << j) - 1) << k);
        let (s, rho) = measure_cut(f, n, ymask, P1);
        let cr = confirm_rho(f, n, ymask);
        assert_eq!(cr, rho);
        print!(" j={j}:(S={s},rho={rho})");
    }
    println!();
}

/// Third independent prime for the `verify` cross-check (10^9 + 7, prime).
const P3: u64 = 1_000_000_007;

/// Confirm `rho` at a cut by three independent prime fields, and (optionally,
/// when the matrix is not too large) exact `BigRational`. Panics on disagreement.
fn confirm_multi(f: &[bool], n: usize, ymask: usize, exact_q: bool) -> usize {
    let (_, r1) = measure_cut(f, n, ymask, P1);
    let (_, r2) = measure_cut(f, n, ymask, P2);
    let (_, r3) = measure_cut(f, n, ymask, P3);
    assert!(
        r1 == r2 && r2 == r3,
        "prime cross-check disagreed at ymask {ymask}: P1={r1} P2={r2} P3={r3}"
    );
    if exact_q {
        let rq = rank_q(f, n, ymask);
        assert_eq!(rq, r1, "exact ℚ rank disagreed at ymask {ymask}");
        println!("           (rho confirmed: exact ℚ == P1 == P2 == P3)");
    } else {
        println!("           (rho confirmed: P1 == P2 == P3, three primes)");
    }
    r1
}

/// Targeted verification of the multiplier closed form (run with `verify`;
/// does NOT touch the full sweep). Reuses the exact-ℚ rank (`rank_q`).
fn verify_closed_form(exact_q_test1: bool) {
    println!("== TARGETED CLOSED-FORM VERIFICATION (multiplier bit) ==\n");

    // (1) k=8, operand cut Y = a (low 8 vars), output bit m = k-1 = 7.
    //     Predict EXACTLY S = 2^k - 1 = 255 and rho = 2^{k-1} + k - 1 = 135.
    {
        let (k, m) = (8usize, 7usize);
        let n = 2 * k;
        let f = tt_multbit(k, m);
        let operand = (1usize << k) - 1; // Y = {a0..a7}
        let (s, _) = measure_cut(&f, n, operand, P1);
        let rho = confirm_multi(&f, n, operand, exact_q_test1); // 256×256
        let pred_s = (1usize << k) - 1;
        let pred_rho = (1usize << (k - 1)) + k - 1; // 2^7 + 7 = 135
        println!("(1) k=8, m=7, operand cut Y=a  (256×256)");
        println!(
            "    measured : S={s}   rho={rho}   ratio={:.4}",
            s as f64 / rho as f64
        );
        println!("    predicted: S=2^8-1={pred_s}   rho=2^7+7={pred_rho}");
        println!(
            "    => {}\n",
            if s == pred_s && rho == pred_rho {
                "MATCH (closed form rho = 2^{k-1}+k-1 CONFIRMED at k=8)"
            } else {
                "*** MISMATCH ***"
            }
        );
    }

    // (2) k=8, columns Z = {a0,a1,b0,b1}, rows = the other 12 vars, bit m = 7.
    //     Predict rho = 16, S in [2000,3800] (cap 2^12-1 = 4095), ratio > 100.
    {
        let (k, m) = (8usize, 7usize);
        let n = 2 * k;
        let f = tt_multbit(k, m);
        let z_mask = 1usize | (1usize << 1) | (1usize << k) | (1usize << (k + 1)); // {0,1,8,9}
        let ymask = ((1usize << n) - 1) ^ z_mask; // rows = 12-var complement
        let (s, _) = measure_cut(&f, n, ymask, P1);
        let rho = confirm_multi(&f, n, ymask, true); // 4096×16, exact ℚ safe
        let ratio = s as f64 / rho as f64;
        println!("(2) k=8, m=7, cols Z={{a0,a1,b0,b1}}, rows = other 12 vars  (4096×16)");
        println!("    measured : S={s}   rho={rho}   ratio={ratio:.2}");
        println!("    predicted: rho=16, S in [2000,3800] (cap 4095), ratio>100");
        let ok = rho == 16 && (2000..=3800).contains(&s) && ratio > 100.0;
        println!("    => {}\n", if ok { "MATCH" } else { "*** MISMATCH ***" });
    }

    // (3) k=6 component identity (row pairing of the operand cut), bit m = k-1 = 5:
    //     Row_a[b] + Row_{2^k-a}[b] = 1 - [ab≡0] + [ab≡2^{k-1}]  (mod 2^k), for all b.
    {
        let (k, m) = (6usize, 5usize);
        let f = tt_multbit(k, m);
        let modk = 1usize << k; // 2^k = 64
        let half = 1usize << (k - 1); // 2^{k-1} = 32
        let row = |a: usize, b: usize| f[a | (b << k)] as i64; // operand cut idx = a | (b<<k)
        let a_vals = [1usize, 7, 13, 21, 31, 33, 47, 63]; // fixed representatives in [1,2^k-1]
        let mut all_ok = true;
        println!(
            "(3) k=6, m=5 row-pairing identity  Row_a + Row_(2^k-a) = J - [ab≡0] + [ab≡2^(k-1)] (mod 2^k)"
        );
        for &a in &a_vals {
            let acomp = modk - a; // 2^k - a
            let mut ok = true;
            for b in 0..modk {
                let lhs = row(a, b) + row(acomp, b);
                let prod = a * b;
                let rhs = 1 - i64::from(prod % modk == 0) + i64::from(prod % modk == half);
                if lhs != rhs {
                    ok = false;
                    all_ok = false;
                    println!("    a={a} b={b}: LHS={lhs} != RHS={rhs}  *** MISMATCH ***");
                }
            }
            println!(
                "    a={a:2} (2^k-a={acomp:2}): identity holds over all {modk} columns b  => {}",
                if ok { "OK" } else { "FAIL" }
            );
        }
        println!(
            "    => {}\n",
            if all_ok {
                "MATCH (all sampled a)"
            } else {
                "*** MISMATCH ***"
            }
        );
    }

    println!("== DONE ==");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "verify") {
        // `verify noq` skips the 256×256 exact-ℚ rank (three primes still confirm it).
        let exact_q_test1 = !args.iter().any(|a| a == "noq");
        verify_closed_form(exact_q_test1);
        return;
    }

    println!("== SANITY ==");
    {
        // tt_addbit(2,1) at the operand cut must reproduce SUMBIT_2: S=4, rho=3.
        let f = tt_addbit(2, 1);
        let (s, _) = measure_cut(&f, 4, 0b0011, P1);
        let rho = confirm_rho(&f, 4, 0b0011);
        assert_eq!((s, rho), (4, 3), "SUMBIT_2 sanity");
        println!("SUMBIT_2 = tt_addbit(2,1) operand cut: S={s} rho={rho}  (expect 4,3) OK");
        // multiplier k=2,m=1 operand cut must be S=rho=3.
        let g = tt_multbit(2, 1);
        let (s2, _) = measure_cut(&g, 4, 0b0011, P1);
        let r2 = confirm_rho(&g, 4, 0b0011);
        assert_eq!((s2, r2), (3, 3), "mult(2,1) sanity");
        println!("mult k=2,m=1 operand cut:               S={s2} rho={r2}  (expect 3,3) OK");
    }

    println!("\n== ADDER: top sum bit m = k-1 ==");
    println!("(predict operand cut S=2^k, rho=2^{{k-1}}+1; global-max ratio < 2)");
    for k in 2..=7 {
        let m = k - 1;
        let f = tt_addbit(k, m);
        let (op_s, op_rho) = sweep(&format!("adder-sum k={k} m={m}"), &f, 2 * k, k);
        let pred_s = 1usize << k;
        let pred_rho = (1usize << (k - 1)) + 1;
        let hit = op_s == pred_s && op_rho == pred_rho;
        println!(
            "           PREDICT operand S=2^{k}={pred_s}, rho=2^{}+1={pred_rho}  => {}",
            k - 1,
            if hit { "HIT" } else { "*** MISS ***" }
        );
        interleaved_report(&f, 2 * k, k);
    }

    println!("\n== ADDER: carry-out bit m = k (headline k=6; pattern shown for k=2..7) ==");
    println!("(predict S = rho = 2^k - 1 at operand cut; full rank, NO gap)");
    for k in 2..=7 {
        let m = k;
        let f = tt_addbit(k, m);
        let (op_s, op_rho) = sweep(&format!("adder-carry k={k} m={m}"), &f, 2 * k, k);
        let pred = (1usize << k) - 1;
        let hit = op_s == pred && op_rho == pred;
        println!(
            "           PREDICT operand S=rho=2^{k}-1={pred}  => {}{}",
            if hit { "HIT" } else { "*** MISS ***" },
            if k == 6 {
                "   <== specified target"
            } else {
                ""
            }
        );
    }

    println!("\n== MULTIPLIER: bits m = k-1 and m = k ==");
    println!("(predict mixing: S ~ rho, ratio -> 1; both widths explode)");
    for k in 2..=7 {
        for m in [k - 1, k] {
            let f = tt_multbit(k, m);
            let _ = sweep(&format!("mult k={k} m={m}"), &f, 2 * k, k);
        }
    }

    println!("\n== DONE ==");
}
