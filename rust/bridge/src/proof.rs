use crate::{
    codec::{Path, Term},
    engine::Library,
    protocol::OriginSites,
};
use anyhow::{Context, Result, ensure};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Serialize)]
struct Argument {
    parameter: usize,
    term: Term,
}

#[derive(Serialize)]
pub struct Step {
    kind: &'static str,
    rule_id: String,
    direction: &'static str,
    site_path: Path,
    substitution: Vec<Argument>,
    premise_refs: Vec<String>,
}

#[derive(Serialize)]
pub struct Proof {
    proof_id: String,
    left_term: Term,
    right_term: Term,
    steps: Vec<Step>,
}

#[derive(Serialize)]
pub struct CallSite {
    program_index: usize,
    call_path: Path,
    definition_ref: String,
    argument_terms: Vec<Term>,
    source_occurrences: Vec<String>,
    proof_ref: String,
}

struct Work(usize);

impl Work {
    fn use_node(&mut self) {
        crate::resources::check();
        self.0 = self.0.checked_add(1).expect("proof visits overflow");
    }
}

#[derive(Clone)]
struct Marked {
    head: Term,
    marks: BTreeSet<Path>,
    children: Vec<Marked>,
}

impl Marked {
    fn new(
        term: &Term,
        site: &mut Path,
        work: &mut Work,
        mark: &impl Fn(&Path, &Term) -> BTreeSet<Path>,
    ) -> Self {
        work.use_node();
        let (head, children) = match term {
            Term::Call { operator, args } => (
                Term::call(operator, Vec::new()),
                args.iter()
                    .enumerate()
                    .map(|(index, item)| {
                        site.push(index);
                        let marked = Self::new(item, site, work, mark);
                        site.pop();
                        marked
                    })
                    .collect(),
            ),
            _ => (term.clone(), Vec::new()),
        };
        Self {
            head,
            children,
            marks: mark(site, term),
        }
    }

    fn term(&self) -> Term {
        match &self.head {
            Term::Call { operator, .. } => {
                Term::call(operator, self.children.iter().map(Self::term).collect())
            }
            _ => self.head.clone(),
        }
    }

    fn instantiate(self, args: &[Self], work: &mut Work) -> Self {
        work.use_node();
        if let Term::Param { index } = self.head {
            let arg = &args[index];
            fn charge(node: &Marked, work: &mut Work) {
                work.use_node();
                for child in &node.children {
                    charge(child, work);
                }
            }
            charge(arg, work);
            let mut arg = arg.clone();
            arg.marks.extend(self.marks);
            return arg;
        }
        let children = self
            .children
            .into_iter()
            .map(|node| node.instantiate(args, work))
            .collect();
        Self { children, ..self }
    }

    fn reduce(
        mut self,
        library: &Library,
        site: &mut Path,
        steps: &mut Vec<Step>,
        spread: bool,
        work: &mut Work,
    ) -> Self {
        work.use_node();
        self.children = self
            .children
            .into_iter()
            .enumerate()
            .map(|(index, node)| {
                site.push(index);
                let next = node.reduce(library, site, steps, spread, work);
                site.pop();
                next
            })
            .collect();
        let Term::Call { operator, .. } = &self.head else {
            return self;
        };
        let Some(def) = library.get(operator) else {
            return self;
        };
        steps.push(Step {
            kind: "rule",
            rule_id: format!("def.{operator}"),
            direction: "forward",
            site_path: site.clone(),
            premise_refs: Vec::new(),
            substitution: self
                .children
                .iter()
                .enumerate()
                .map(|(parameter, term)| Argument {
                    parameter,
                    term: term.term(),
                })
                .collect(),
        });
        let no_mark = BTreeSet::new();
        let mut instance = Marked::new(&def.body, &mut Vec::new(), work, &|_, _| {
            if spread {
                self.marks.clone()
            } else {
                no_mark.clone()
            }
        })
        .instantiate(&self.children, work);
        instance.marks.extend(self.marks);
        instance.reduce(library, site, steps, spread, work)
    }

    fn mark_correspondence(
        &self,
        right: &Self,
        witnesses: &mut BTreeMap<Path, BTreeSet<Path>>,
        work: &mut Work,
    ) -> BTreeSet<Path> {
        work.use_node();
        let mut sources = self.marks.clone();
        for (left_child, right_child) in self.children.iter().zip(&right.children) {
            sources.extend(left_child.mark_correspondence(right_child, witnesses, work));
        }
        for site in &right.marks {
            witnesses
                .entry(site.clone())
                .or_default()
                .extend(sources.iter().cloned());
        }
        sources
    }
}

fn substitute(term: &Term, args: &[Argument], work: &mut Work) -> Term {
    work.use_node();
    match term {
        Term::Param { index } => args[*index].term.clone(),
        Term::Call {
            operator,
            args: children,
        } => Term::call(
            operator,
            children
                .iter()
                .map(|child| substitute(child, args, work))
                .collect(),
        ),
        _ => term.clone(),
    }
}

fn check_steps(
    original: &Term,
    target: &Term,
    steps: &[Step],
    library: &Library,
    work: &mut Work,
) -> Result<()> {
    let mut current = original.clone();
    for step in steps {
        let name = step
            .rule_id
            .strip_prefix("def.")
            .context("invalid proof rule")?;
        let definition = library.get(name).context("unknown proof definition")?;
        ensure!(
            step.substitution.len() == definition.arity,
            "invalid proof substitution arity"
        );
        let site = current
            .at_mut(&step.site_path)
            .context("proof site is missing")?;
        let call = Term::call(
            name,
            step.substitution
                .iter()
                .map(|arg| arg.term.clone())
                .collect(),
        );
        let body = substitute(&definition.body, &step.substitution, work);
        let (before, after) = if step.direction == "forward" {
            (call, body)
        } else {
            (body, call)
        };
        ensure!(
            *site == before,
            "proof cannot replay this substitution at its site"
        );
        *site = after;
    }
    ensure!(current == *target, "proof replay endpoint mismatch");
    Ok(())
}

pub fn verify(
    original: &[Term],
    target: &[Term],
    origins: &[OriginSites],
    library: &Library,
) -> Result<(Vec<Proof>, Vec<CallSite>, usize)> {
    let mut work = Work(0);
    let mut proofs = Vec::new();
    let mut calls = Vec::new();
    for (index, ((left, right), sites)) in original.iter().zip(target).zip(origins).enumerate() {
        let proof_id = format!("proof-{index}");
        let mut steps = Vec::new();
        let mut reverse = Vec::new();
        let mut uses = BTreeMap::new();
        let from = Marked::new(left, &mut Vec::new(), &mut work, &|site, _| {
            BTreeSet::from([site.clone()])
        })
        .reduce(library, &mut Vec::new(), &mut steps, true, &mut work);
        let to = Marked::new(right, &mut Vec::new(), &mut work, &|site, term| {
            if let Term::Call { operator, .. } = term
                && library.contains_key(operator)
            {
                BTreeSet::from([site.clone()])
            } else {
                BTreeSet::new()
            }
        })
        .reduce(library, &mut Vec::new(), &mut reverse, false, &mut work);
        ensure!(
            from.term() == to.term(),
            "independent definition expansion differs at program {index}"
        );
        from.mark_correspondence(&to, &mut uses, &mut work);
        steps.extend(reverse.into_iter().rev().map(|mut step| {
            step.direction = "reverse";
            step
        }));
        check_steps(left, right, &steps, library, &mut work)?;
        proofs.push(Proof {
            proof_id: proof_id.clone(),
            left_term: left.clone(),
            right_term: right.clone(),
            steps,
        });
        let mut missing_witness = false;
        right.walk(&mut Vec::new(), &mut |path, term| {
            if let Term::Call { operator, args } = term
                && library.contains_key(operator)
            {
                let Some(positions) = uses.get(path).filter(|positions| !positions.is_empty())
                else {
                    missing_witness = true;
                    return;
                };
                let source_occurrences = positions.iter().map(|p| sites[p].clone()).collect();
                calls.push(CallSite {
                    program_index: index,
                    call_path: path.clone(),
                    definition_ref: operator.clone(),
                    argument_terms: args.clone(),
                    source_occurrences,
                    proof_ref: proof_id.clone(),
                });
            }
        });
        ensure!(!missing_witness, "selected call has no occurrence witness");
    }
    Ok((proofs, calls, work.0))
}
