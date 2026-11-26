//! CNF formulas and DIMACS parsing.
//!
//! Variables are 0-indexed internally; a DIMACS variable `v ∈ 1..=n` maps to
//! internal id `v - 1`.

use std::fmt;

/// A literal: a variable id (0-indexed) together with a sign.
///
/// `positive == true` denotes the plain variable, `false` its negation.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct Lit {
    pub var: usize,
    pub positive: bool,
}

impl Lit {
    pub const fn new(var: usize, positive: bool) -> Self {
        Self { var, positive }
    }

    pub const fn positive(var: usize) -> Self {
        Self {
            var,
            positive: true,
        }
    }

    pub const fn negative(var: usize) -> Self {
        Self {
            var,
            positive: false,
        }
    }

    /// Value of this literal under `assignment` (indexed by variable id).
    pub fn eval(&self, assignment: &[bool]) -> bool {
        assignment[self.var] == self.positive
    }

    /// The literal as a signed DIMACS integer (`+v` or `-v`, 1-indexed).
    pub fn to_dimacs(&self) -> i64 {
        let v = (self.var + 1) as i64;
        if self.positive { v } else { -v }
    }
}

impl fmt::Display for Lit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if !self.positive {
            write!(f, "¬")?;
        }
        write!(f, "x{}", self.var)
    }
}

/// A clause: a disjunction of literals.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct Clause {
    pub lits: Vec<Lit>,
}

impl Clause {
    pub fn new(lits: Vec<Lit>) -> Self {
        Self { lits }
    }

    /// Is the clause satisfied by `assignment` (indexed by variable id)?
    pub fn eval(&self, assignment: &[bool]) -> bool {
        self.lits.iter().any(|l| l.eval(assignment))
    }

    /// The distinct variables occurring in the clause.
    pub fn vars(&self) -> impl Iterator<Item = usize> + '_ {
        self.lits.iter().map(|l| l.var)
    }

    pub fn len(&self) -> usize {
        self.lits.len()
    }

    pub fn is_empty(&self) -> bool {
        self.lits.is_empty()
    }
}

/// A CNF formula over `n_vars` variables (ids `0..n_vars`).
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct Cnf {
    pub n_vars: usize,
    pub clauses: Vec<Clause>,
}

impl Cnf {
    pub fn new(n_vars: usize) -> Self {
        Self {
            n_vars,
            clauses: Vec::new(),
        }
    }

    pub fn add_clause(&mut self, clause: Clause) {
        self.clauses.push(clause);
    }

    /// Is the formula satisfied by `assignment` (indexed by variable id)?
    pub fn eval(&self, assignment: &[bool]) -> bool {
        self.clauses.iter().all(|c| c.eval(assignment))
    }

    /// Parse a DIMACS CNF text. Comment lines (`c ...`) and the problem line
    /// (`p cnf n m`) are recognized; clauses are whitespace/newline-agnostic
    /// sequences of nonzero signed integers terminated by `0`. A trailing
    /// unterminated clause is accepted.
    pub fn parse_dimacs(text: &str) -> Result<Cnf, ParseError> {
        let mut n_vars: Option<usize> = None;
        let mut pending: Vec<Lit> = Vec::new();
        let mut clauses: Vec<Clause> = Vec::new();
        let mut max_var_seen: usize = 0;

        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('c') {
                continue;
            }
            if let Some(rest) = line.strip_prefix('p') {
                // Expect: p cnf <n> <m>
                let mut it = rest.split_whitespace();
                match it.next() {
                    Some("cnf") => {}
                    other => return Err(ParseError::BadProblemLine(format!("{other:?}"))),
                }
                let n = it
                    .next()
                    .ok_or_else(|| ParseError::BadProblemLine("missing var count".into()))?
                    .parse::<usize>()
                    .map_err(|_| ParseError::BadProblemLine("var count".into()))?;
                n_vars = Some(n);
                continue;
            }
            // A clause fragment: signed integers, possibly ending in 0.
            for tok in line.split_whitespace() {
                let lit: i64 = tok
                    .parse()
                    .map_err(|_| ParseError::BadToken(tok.to_string()))?;
                if lit == 0 {
                    clauses.push(Clause::new(std::mem::take(&mut pending)));
                } else {
                    let var = lit.unsigned_abs() as usize - 1;
                    max_var_seen = max_var_seen.max(var + 1);
                    pending.push(Lit::new(var, lit > 0));
                }
            }
        }
        if !pending.is_empty() {
            clauses.push(Clause::new(pending));
        }

        let n_vars = n_vars.unwrap_or(max_var_seen);
        if max_var_seen > n_vars {
            return Err(ParseError::VarOutOfRange {
                var: max_var_seen,
                declared: n_vars,
            });
        }
        Ok(Cnf { n_vars, clauses })
    }

    /// Render the formula back to DIMACS text.
    pub fn to_dimacs(&self) -> String {
        use std::fmt::Write;
        let mut s = format!("p cnf {} {}\n", self.n_vars, self.clauses.len());
        for c in &self.clauses {
            for l in &c.lits {
                let _ = write!(s, "{} ", l.to_dimacs());
            }
            s.push_str("0\n");
        }
        s
    }
}

/// Errors from DIMACS parsing.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum ParseError {
    BadProblemLine(String),
    BadToken(String),
    VarOutOfRange { var: usize, declared: usize },
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::BadProblemLine(s) => write!(f, "bad problem line: {s}"),
            ParseError::BadToken(s) => write!(f, "bad token: {s:?}"),
            ParseError::VarOutOfRange { var, declared } => {
                write!(f, "variable {var} exceeds declared count {declared}")
            }
        }
    }
}

impl std::error::Error for ParseError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lit_eval() {
        let a = [true, false];
        assert!(Lit::positive(0).eval(&a));
        assert!(!Lit::negative(0).eval(&a));
        assert!(Lit::negative(1).eval(&a));
    }

    #[test]
    fn clause_eval() {
        // (x0 ∨ ¬x1)
        let c = Clause::new(vec![Lit::positive(0), Lit::negative(1)]);
        assert!(c.eval(&[true, true]));
        assert!(!c.eval(&[false, true]));
        assert!(c.eval(&[false, false]));
    }

    #[test]
    fn empty_clause_false_tautology_true() {
        // The empty clause is never satisfied (⇒ UNSAT formula).
        let empty = Clause::new(vec![]);
        assert!(empty.is_empty());
        assert!(!empty.eval(&[false, true]));
        // A tautological clause (x0 ∨ ¬x0) is always satisfied.
        let taut = Clause::new(vec![Lit::positive(0), Lit::negative(0)]);
        assert!(taut.eval(&[true, false]));
        assert!(taut.eval(&[false, false]));
    }

    #[test]
    fn parse_basic() {
        let text = "c comment\np cnf 3 2\n1 -2 3 0\n-1 2 0\n";
        let cnf = Cnf::parse_dimacs(text).unwrap();
        assert_eq!(cnf.n_vars, 3);
        assert_eq!(cnf.clauses.len(), 2);
        assert_eq!(
            cnf.clauses[0].lits,
            vec![Lit::positive(0), Lit::negative(1), Lit::positive(2)]
        );
        assert_eq!(
            cnf.clauses[1].lits,
            vec![Lit::negative(0), Lit::positive(1)]
        );
    }

    #[test]
    fn parse_multiline_clause() {
        // A clause split across lines.
        let text = "p cnf 4 1\n1 2\n3 4 0\n";
        let cnf = Cnf::parse_dimacs(text).unwrap();
        assert_eq!(cnf.clauses.len(), 1);
        assert_eq!(cnf.clauses[0].len(), 4);
    }

    #[test]
    fn parse_unterminated_trailing() {
        let text = "p cnf 2 1\n1 2\n";
        let cnf = Cnf::parse_dimacs(text).unwrap();
        assert_eq!(cnf.clauses.len(), 1);
    }

    #[test]
    fn parse_var_out_of_range() {
        let text = "p cnf 2 1\n1 2 3 0\n";
        assert!(matches!(
            Cnf::parse_dimacs(text),
            Err(ParseError::VarOutOfRange { .. })
        ));
    }

    #[test]
    fn dimacs_roundtrip() {
        let text = "p cnf 3 2\n1 -2 3 0\n-1 2 0\n";
        let cnf = Cnf::parse_dimacs(text).unwrap();
        let cnf2 = Cnf::parse_dimacs(&cnf.to_dimacs()).unwrap();
        assert_eq!(cnf, cnf2);
    }
}
