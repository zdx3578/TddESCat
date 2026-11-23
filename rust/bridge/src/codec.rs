use crate::protocol::{SlotSpec, digest, identifier, operator};
use anyhow::{Context, Result, bail, ensure};
use egg_stitch::lang::PortTypes;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", deny_unknown_fields)]
pub enum Term {
    Param { index: usize },
    Slot { index: usize },
    Const { sort: String, value: Value },
    Call { operator: String, args: Vec<Term> },
}

pub type Path = Vec<usize>;

impl Term {
    pub fn call(name: &str, args: Vec<Term>) -> Self {
        Self::Call {
            operator: name.to_owned(),
            args,
        }
    }

    pub fn show(&self, meta: &str) -> String {
        match self {
            Self::Param { index } => format!("{meta}{index}"),
            Self::Slot { index } => format!("${index}"),
            Self::Const { sort, value } => match (sort.as_str(), value) {
                ("Integer", Value::Number(n)) => format!("i{n}"),
                ("Color", Value::Number(n)) => format!("color{n}"),
                (_, Value::String(s)) => s.clone(),
                _ => String::new(),
            },
            Self::Call { operator, args } if args.is_empty() => operator.clone(),
            Self::Call { operator, args } => {
                let items = args.iter().map(|x| x.show(meta)).collect::<Vec<_>>();
                format!("({operator} {})", items.join(" "))
            }
        }
    }

    pub fn walk(&self, site: &mut Path, visit: &mut impl FnMut(&Path, &Self)) {
        visit(site, self);
        if let Self::Call { args, .. } = self {
            for (i, arg) in args.iter().enumerate() {
                site.push(i);
                arg.walk(site, visit);
                site.pop();
            }
        }
    }

    pub fn at_mut(&mut self, path: &[usize]) -> Option<&mut Self> {
        if let Some((&first, rest)) = path.split_first() {
            if let Self::Call { args, .. } = self {
                return args.get_mut(first)?.at_mut(rest);
            }
            None
        } else {
            Some(self)
        }
    }

    pub fn cost(&self) -> u64 {
        match self {
            Self::Call { args, .. } => args
                .iter()
                .try_fold(1u64, |n, arg| n.checked_add(arg.cost()))
                .expect("AST cost overflow"),
            _ => 1,
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Signature {
    schema_version: u32,
    signature_id: String,
    sorts: Vec<Sort>,
    operators: Vec<Operator>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Sort {
    id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Operator {
    symbol: String,
    inputs: Vec<String>,
    output: String,
    purity: String,
    read_rule: Vec<usize>,
    binder_children: Vec<usize>,
}

#[derive(Clone, Debug)]
pub struct Registry {
    pub sorts: Vec<String>,
    pub ports: BTreeMap<String, PortTypes>,
    pub slots: Vec<u32>,
}

impl Registry {
    pub fn new(signature: Signature, slots: &[SlotSpec]) -> Result<Self> {
        ensure!(
            signature.schema_version == 1 && identifier(&signature.signature_id),
            "invalid signature identity"
        );
        let sorts = signature
            .sorts
            .into_iter()
            .map(|sort| sort.id)
            .collect::<Vec<_>>();
        ensure!(
            !sorts.is_empty()
                && sorts.len() <= 128
                && sorts.iter().all(|s| identifier(s))
                && sorts.iter().collect::<BTreeSet<_>>().len() == sorts.len(),
            "invalid sorts"
        );
        let mut r = Registry {
            sorts,
            ports: BTreeMap::new(),
            slots: Vec::new(),
        };
        for o in signature.operators {
            ensure!(
                operator(&o.symbol)
                    && o.purity == "pure"
                    && o.binder_children.is_empty()
                    && o.read_rule.iter().copied().eq(0..o.inputs.len())
                    && o.inputs.len() <= 8,
                "unsupported operator {}",
                o.symbol
            );
            r.register(&o.symbol, &o.inputs, &o.output)?;
        }
        ensure!(slots.len() <= 128, "too many free slots");
        for (i, slot) in slots.iter().enumerate() {
            ensure!(
                slot.index == i
                    && matches!(slot.time_role.as_str(), "before" | "after" | "timeless")
                    && slot.role_constraints.is_empty(),
                "unsupported slot context"
            );
            let sort = r.sort_id(&slot.sort)?;
            ensure!(
                match slot.sort.as_str() {
                    "RoleBefore" => slot.time_role == "before",
                    "RoleAfter" => slot.time_role == "after",
                    _ => true,
                },
                "slot time role conflicts with its sort"
            );
            r.slots.push(sort);
            r.register(&format!("${i}"), &[], &slot.sort)?;
        }
        Ok(r)
    }

    pub fn sort_id(&self, name: &str) -> Result<u32> {
        self.sorts
            .iter()
            .position(|n| n == name)
            .map(|i| i as u32)
            .with_context(|| format!("unknown sort {name}"))
    }

    pub fn register(&mut self, name: &str, inputs: &[String], output: &str) -> Result<()> {
        let inputs = inputs
            .iter()
            .map(|s| self.sort_id(s))
            .collect::<Result<_>>()?;
        let output = self.sort_id(output)?;
        ensure!(
            self.ports
                .insert(name.to_owned(), PortTypes { inputs, output })
                .is_none(),
            "duplicate operator {name}"
        );
        Ok(())
    }

    pub fn infer(&self, term: &Term, params: Option<&[u32]>) -> Result<u32> {
        let result = match term {
            Term::Slot { index } => {
                ensure!(params.is_none(), "free slot in definition");
                *self.slots.get(*index).context("undeclared free slot")?
            }
            Term::Param { index } => *params
                .and_then(|sorts| sorts.get(*index))
                .context("undeclared parameter")?,
            Term::Const { sort, .. } => {
                let symbol = term.show("?#");
                let expected = self.sort_id(sort)?;
                ensure!(operator(&symbol), "invalid constant representation");
                let actual = self.ports.get(&symbol).context("undeclared constant")?;
                ensure!(
                    actual.inputs.is_empty() && expected == actual.output,
                    "constant sort differs from signature"
                );
                expected
            }
            Term::Call { operator, args } => {
                let ports = self
                    .ports
                    .get(operator)
                    .with_context(|| format!("unregistered operator {operator}"))?;
                ensure!(
                    !operator.starts_with('$') && args.len() == ports.inputs.len(),
                    "invalid arity or operator at {operator}"
                );
                for (arg, &sort) in args.iter().zip(&ports.inputs) {
                    ensure!(
                        self.infer(arg, params)? == sort,
                        "port sort mismatch at {operator}"
                    );
                }
                ports.output
            }
        };
        Ok(result)
    }
}

#[derive(Clone, Copy)]
enum Mode {
    Program,
    Pattern,
    Lambda(usize),
}

struct Syntax<'a> {
    head: &'a str,
    children: Vec<Syntax<'a>>,
}

fn parse(text: &str) -> Result<Syntax<'_>> {
    ensure!(text.len() <= 65_536, "expression text limit");
    let mut tokens = Vec::new();
    let mut start = None;
    for (i, x) in text.bytes().enumerate() {
        if b"() \r\t\n".contains(&x) {
            if let Some(s) = start.take() {
                tokens.push(&text[s..i]);
            }
            if b"()".contains(&x) {
                tokens.push(&text[i..i + 1]);
            }
        } else {
            ensure!(
                x.is_ascii_alphanumeric() || b"_.-$?#".contains(&x),
                "non-canonical expression character"
            );
            start.get_or_insert(i);
        }
    }
    if let Some(s) = start {
        tokens.push(&text[s..]);
    }
    ensure!(tokens.len() <= 4096, "expression token limit");
    fn parse_node<'a>(
        tokens: &mut std::iter::Peekable<impl Iterator<Item = &'a str>>,
        depth: usize,
    ) -> Result<Syntax<'a>> {
        ensure!(depth <= 64, "expression depth limit");
        let token = tokens.next().context("missing expression")?;
        if token != "(" {
            ensure!(token != ")", "unexpected closing parenthesis");
            return Ok(Syntax {
                head: token,
                children: Vec::new(),
            });
        }
        let head = tokens.next().context("missing operator")?;
        ensure!(!matches!(head, "(" | ")"), "invalid operator");
        let mut children = Vec::new();
        while let Some(&token) = tokens.peek() {
            if token == ")" {
                tokens.next();
                return Ok(Syntax { head, children });
            }
            children.push(parse_node(tokens, depth + 1)?);
        }
        bail!("unclosed expression")
    }
    let mut tokens = tokens.into_iter().peekable();
    let node = parse_node(&mut tokens, 0)?;
    ensure!(tokens.next().is_none(), "trailing expression");
    Ok(node)
}

fn index(name: &str) -> Result<usize> {
    let n = name.parse::<usize>()?;
    ensure!(n.to_string() == name, "non-canonical index");
    Ok(n)
}

fn decode(node: Syntax<'_>, r: &Registry, mode: Mode) -> Result<Term> {
    if let Some(i) = node.head.strip_prefix('$') {
        ensure!(node.children.is_empty(), "non-leaf indexed reference");
        let index = index(i)?;
        return match mode {
            Mode::Program => Ok(Term::Slot { index }),
            Mode::Lambda(n) if index < n => Ok(Term::Param {
                index: n - 1 - index,
            }),
            _ => bail!("free indexed reference in a definition"),
        };
    }
    if let Some(i) = node.head.strip_prefix("?#") {
        ensure!(
            matches!(mode, Mode::Pattern) && node.children.is_empty(),
            "unexpected pattern variable"
        );
        return Ok(Term::Param { index: index(i)? });
    }
    let ports = r
        .ports
        .get(node.head)
        .with_context(|| format!("unregistered operator {}", node.head))?;
    ensure!(
        node.children.len() == ports.inputs.len(),
        "arity mismatch at {}",
        node.head
    );
    if node.children.is_empty() && operator(node.head) {
        let sort = r.sorts[ports.output as usize].clone();
        let prefix = match sort.as_str() {
            "Integer" => "i",
            "Color" => "color",
            _ => "",
        };
        let number = match prefix {
            "" => None,
            _ => node
                .head
                .strip_prefix(prefix)
                .and_then(|s| s.parse::<i64>().ok())
                .filter(|n| format!("{prefix}{n}") == node.head),
        };
        let value = number.map_or_else(|| Value::String(node.head.to_owned()), |n| n.into());
        return Ok(Term::Const { sort, value });
    }
    let args = node
        .children
        .into_iter()
        .map(|child| decode(child, r, mode))
        .collect::<Result<_>>()?;
    Ok(Term::call(node.head, args))
}

pub fn program(text: &str, r: &Registry) -> Result<Term> {
    let term = decode(parse(text)?, r, Mode::Program)?;
    r.infer(&term, None)?;
    Ok(term)
}

pub fn definitions(pattern: &str, lambda: &str, r: &Registry, sorts: &[String]) -> Result<Term> {
    let count = sorts.len();
    let body = decode(parse(pattern)?, r, Mode::Pattern)?;
    let mut closed = parse(lambda)?;
    for _ in 0..count {
        ensure!(
            closed.head == "lam" && closed.children.len() == 1,
            "missing outer binder"
        );
        closed = closed.children.pop().unwrap();
    }
    let decoded = decode(closed, r, Mode::Lambda(count))?;
    ensure!(
        body == decoded,
        "pattern and closed lambda parameter order differ"
    );
    let inputs = sorts
        .iter()
        .map(|s| r.sort_id(s))
        .collect::<Result<Vec<_>>>()?;
    r.infer(&body, Some(&inputs))?;
    Ok(body)
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Definition {
    pub temporary_name: String,
    pub arity: usize,
    pub parameter_sorts: Vec<String>,
    pub result_sort: String,
    pub parameter_reads: Vec<usize>,
    pub body: Term,
    pub pattern_text: String,
    pub closed_lambda_text: String,
    pub dependencies: Vec<String>,
    pub body_cost: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LibraryEntry {
    pub stable_id: String,
    pub definition: Definition,
}

pub fn stable_id(def: &Definition) -> Result<String> {
    Ok(format!(
        "lib_{}",
        digest(&serde_json::to_vec(&(
            &def.parameter_sorts,
            &def.result_sort,
            def.body.show("?#"),
        ))?)
    ))
}

pub fn dependencies(body: &Term) -> Vec<String> {
    let mut names = BTreeSet::new();
    body.walk(&mut Vec::new(), &mut |_, term| {
        if let Term::Call { operator, .. } = term
            && (operator.starts_with("fn_") || operator.starts_with("lib_"))
        {
            names.insert(operator.clone());
        }
    });
    names.into_iter().collect()
}

impl Definition {
    pub fn check(&self, r: &Registry) -> Result<()> {
        let name = self
            .temporary_name
            .strip_prefix("fn_")
            .context("invalid temporary function name")?;
        index(name)?;
        ensure!(
            self.arity == self.parameter_sorts.len() && self.arity <= 8,
            "invalid definition arity"
        );
        let body = definitions(
            &self.pattern_text,
            &self.closed_lambda_text,
            r,
            &self.parameter_sorts,
        )?;
        ensure!(
            body == self.body,
            "stored definition body differs from decoded shape"
        );
        let mut reads = BTreeSet::new();
        body.walk(&mut Vec::new(), &mut |_, t| {
            if let Term::Param { index } = t {
                reads.insert(*index);
            }
        });
        ensure!(
            reads.into_iter().eq(0..self.arity)
                && self.parameter_reads.iter().copied().eq(0..self.arity),
            "definition does not preserve parameter reads"
        );
        ensure!(
            self.dependencies == dependencies(&body) && self.body_cost == body.cost().to_string(),
            "definition dependencies or cost mismatch"
        );
        let inputs = self
            .parameter_sorts
            .iter()
            .map(|s| r.sort_id(s))
            .collect::<Result<Vec<_>>>()?;
        ensure!(
            r.infer(&body, Some(&inputs))? == r.sort_id(&self.result_sort)?,
            "definition output sort mismatch"
        );
        ensure!(
            matches!(body, Term::Call { .. } | Term::Const { .. }),
            "trivial variable-only definition"
        );
        Ok(())
    }
}
