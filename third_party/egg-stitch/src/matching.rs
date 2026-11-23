use crate::factor::Factor;
use crate::lang::{StitchEgraph, StitchLanguage};
use egg::Id;
use num_bigint::BigUint;

/// All the ways the current pattern can match at a specific e-class, stored as a
/// cartesian factoring of the substitution set (see [`Factor`]).
/// Invariant: `root_eclass` and all ids in every factor row are canonical
/// (the egraph isn't unioned during search). The factors' `slots` partition
/// `0..arity` where `arity` is the pattern's variable count.
#[derive(Debug, Clone)]
pub struct MatchAtEClass {
    pub root_eclass: Id,
    pub factors: Vec<Factor>,
}

impl MatchAtEClass {
    /// Creates a match for e-class `c` with a single-variable pattern: one
    /// factor over slot 0 with the lone row `[c]`.
    pub fn identity_match(c: Id) -> Self {
        Self {
            root_eclass: c,
            factors: vec![Factor::new(vec![0], vec![vec![c]]).unwrap()],
        }
    }

    /// Number of full substitutions = product of the factors' row counts.
    /// Factors are never empty, so this is `≥ 1`.
    pub fn num_substs(&self) -> usize {
        self.factors.iter().map(|f| f.rows.len()).fold(1, count_product)
    }

    /// Counts exact substitutions without flattening the product.
    pub fn exact_num_substs(&self) -> BigUint {
        self.factors.iter().fold(BigUint::from(1u8), |product, factor| product * factor.rows.len())
    }

    /// `(factor_index, position_within_factor)` for `slot`. Panics if no factor covers it.
    pub fn locate_slot(&self, slot: usize) -> (usize, usize) {
        for (fi, f) in self.factors.iter().enumerate() {
            if let Some(pos) = f.pos_of(slot) {
                return (fi, pos);
            }
        }
        panic!("slot {slot} not covered by any factor");
    }
}

/// Returns one identity match per e-class in the egraph, skipping the root
/// e-class. The root holds the synthetic `(programs ...)` node that wraps the
/// whole corpus; letting the search match there produces abstractions like
/// `(programs ?#0 ?#0)` that collapse the program list itself, which is never
/// what we want.
pub fn identity_matches<L: StitchLanguage>(egraph: &StitchEgraph<L>, root: Id) -> Vec<MatchAtEClass> {
    let root = egraph.find(root);
    egraph.classes().filter(|c| c.id != root).map(|c| MatchAtEClass::identity_match(c.id)).collect()
}

pub(crate) fn count_product(left: usize, right: usize) -> usize {
    left.checked_mul(right).unwrap_or_else(|| std::panic::panic_any(crate::lang::SearchBudgetStop("count_overflow")))
}

pub(crate) fn count_sum(left: usize, right: usize) -> usize {
    left.checked_add(right).unwrap_or_else(|| std::panic::panic_any(crate::lang::SearchBudgetStop("count_overflow")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sparse_factors_can_exceed_machine_count() {
        let matched = MatchAtEClass {
            root_eclass: Id::from(0),
            factors: (0..8)
                .map(|slot| Factor::new(vec![slot], (0..256).map(|v| vec![Id::from(v)]).collect()).unwrap())
                .collect(),
        };
        assert_eq!(matched.exact_num_substs().to_string(), "18446744073709551616");
        let failure = std::panic::catch_unwind(|| matched.num_substs()).unwrap_err();
        assert_eq!(failure.downcast_ref::<crate::lang::SearchBudgetStop>().unwrap().0, "count_overflow");
    }
}
