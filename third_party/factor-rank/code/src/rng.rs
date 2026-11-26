//! A tiny deterministic PRNG (splitmix64), dependency-free and reproducible.
//!
//! Used only for test/benchmark instance generation — never in compiler
//! semantics. Integer-only helpers keep everything reproducible across runs.

/// A splitmix64 pseudo-random generator.
#[derive(Clone, Debug)]
pub struct Rng {
    state: u64,
}

impl Rng {
    pub fn new(seed: u64) -> Self {
        Rng { state: seed }
    }

    /// Next 64-bit value (splitmix64).
    pub fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }

    /// Uniform-ish value in `0..n` (slight modulo bias, acceptable for tests).
    /// Panics if `n == 0`.
    pub fn below(&mut self, n: usize) -> usize {
        assert!(n > 0, "below(0)");
        (self.next_u64() % n as u64) as usize
    }

    /// Uniform-ish value in `lo..=hi`.
    pub fn range_inclusive(&mut self, lo: i64, hi: i64) -> i64 {
        assert!(lo <= hi);
        let span = (hi - lo + 1) as u64;
        lo + (self.next_u64() % span) as i64
    }

    /// A fair coin.
    pub fn next_bool(&mut self) -> bool {
        self.next_u64() & 1 == 1
    }

    /// Returns true with probability `num/den`.
    pub fn chance(&mut self, num: u64, den: u64) -> bool {
        assert!(den > 0 && num <= den);
        self.next_u64() % den < num
    }

    /// A uniform sample of `k` distinct values from `0..n` (partial
    /// Fisher–Yates). Panics if `k > n`.
    pub fn sample_distinct(&mut self, n: usize, k: usize) -> Vec<usize> {
        assert!(k <= n, "cannot sample {k} distinct from {n}");
        let mut pool: Vec<usize> = (0..n).collect();
        for i in 0..k {
            let j = i + self.below(n - i);
            pool.swap(i, j);
        }
        pool.truncate(k);
        pool
    }

    /// Shuffle a slice in place (Fisher–Yates).
    pub fn shuffle<T>(&mut self, xs: &mut [T]) {
        let n = xs.len();
        for i in (1..n).rev() {
            let j = self.below(i + 1);
            xs.swap(i, j);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deterministic() {
        let mut a = Rng::new(42);
        let mut b = Rng::new(42);
        for _ in 0..100 {
            assert_eq!(a.next_u64(), b.next_u64());
        }
    }

    #[test]
    fn different_seeds_differ() {
        let mut a = Rng::new(1);
        let mut b = Rng::new(2);
        assert_ne!(a.next_u64(), b.next_u64());
    }

    #[test]
    fn sample_distinct_is_distinct_and_in_range() {
        let mut rng = Rng::new(7);
        for _ in 0..100 {
            let s = rng.sample_distinct(10, 3);
            assert_eq!(s.len(), 3);
            let mut sorted = s.clone();
            sorted.sort_unstable();
            sorted.dedup();
            assert_eq!(sorted.len(), 3);
            assert!(s.iter().all(|&v| v < 10));
        }
    }

    #[test]
    fn below_in_range() {
        let mut rng = Rng::new(9);
        for _ in 0..1000 {
            assert!(rng.below(5) < 5);
        }
    }
}
