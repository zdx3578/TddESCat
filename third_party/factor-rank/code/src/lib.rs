//! `atddc` — twin knowledge compilers (TDD and ATDD) over a shared vtree layer.
//!
//! See `ARCHITECTURE.md` for the design. This crate root wires up the shared
//! infrastructure (M1): CNF/DIMACS parsing, vtrees, assignment indexing, a
//! brute-force truth-table oracle, a deterministic PRNG, and instance
//! generators. The TDD (M2) and ATDD (M3) backends are added on top.
//!
//! Conventions (must match `reference/atdd_toy.py` for cross-checks):
//! * Variables are 0-indexed internally; DIMACS var `v ∈ 1..=n` ↦ id `v-1`.
//! * The vtree leaf order (left to right) is the variable order.
//! * A global assignment index is MSB-first in leaf order: bit `(n-1-i)` is
//!   variable `root.vars[i]`. A node-local index folds `t.vars` MSB-first, with
//!   the left child more significant (Kronecker order).

pub mod assign;
pub mod atdd;
pub mod backend;
pub mod cnf;
pub mod instances;
pub mod rng;
pub mod tdd;
pub mod truthtable;
pub mod vtree;
