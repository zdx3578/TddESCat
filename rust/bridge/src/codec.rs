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
    descriptor: Option<Value>,
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
    semantic_version: String,
    descriptor: Option<Value>,
}

impl Operator {
    fn semantic_digest(&self) -> Result<String> {
        let material = serde_json::json!([
            "operator-v1",
            self.inputs,
            self.output,
            self.read_rule,
            self.semantic_version,
            self.descriptor
        ]);
        let identity = if self.descriptor.is_some() {
            material
        } else {
            serde_json::json!([self.symbol, material])
        };
        Ok(digest(&serde_json::to_vec(&identity)?))
    }
}

#[derive(Clone, Debug)]
pub struct Registry {
    pub sorts: Vec<String>,
    pub ports: BTreeMap<String, PortTypes>,
    pub slots: Vec<u32>,
    semantics: BTreeMap<String, String>,
    constructed: BTreeSet<String>,
}

impl Registry {
    pub fn new(signature: Signature, slots: &[SlotSpec]) -> Result<Self> {
        ensure!(
            signature.schema_version == 3 && identifier(&signature.signature_id),
            "invalid signature identity"
        );
        for sort in &signature.sorts {
            let prefix = sort
                .id
                .strip_prefix("rel_")
                .map(|id| (id, "relation"))
                .or_else(|| sort.id.strip_prefix("prog_").map(|id| (id, "program")));
            match (prefix, &sort.descriptor) {
                (Some((id, kind)), Some(descriptor)) => ensure!(
                    descriptor["kind"] == kind && id == digest(&serde_json::to_vec(descriptor)?),
                    "invalid sort descriptor identity"
                ),
                (None, None) => {}
                _ => bail!("missing or unexpected sort descriptor"),
            }
        }
        let sorts = signature
            .sorts
            .into_iter()
            .map(|sort| sort.id)
            .collect::<Vec<_>>();
        ensure!(
            !sorts.is_empty()
                && sorts.iter().all(|s| identifier(s))
                && sorts.iter().collect::<BTreeSet<_>>().len() == sorts.len(),
            "invalid sorts"
        );
        let mut r = Registry {
            sorts,
            ports: BTreeMap::new(),
            slots: Vec::new(),
            semantics: BTreeMap::new(),
            constructed: BTreeSet::new(),
        };
        for o in signature.operators {
            ensure!(
                operator(&o.symbol)
                    && identifier(&o.semantic_version)
                    && o.purity == "pure"
                    && o.binder_children.is_empty()
                    && o.read_rule.iter().copied().eq(0..o.inputs.len()),
                "unsupported operator {}",
                o.symbol
            );
            let semantic_digest = o.semantic_digest()?;
            ensure!(
                if o.descriptor.is_some() {
                    o.symbol == format!("op_{semantic_digest}")
                } else {
                    !o.symbol.starts_with("op_")
                },
                "operator descriptor identity differs"
            );
            r.register(&o.symbol, &o.inputs, &o.output)?;
            if o.descriptor.as_ref().is_some_and(|d| d["kind"] != "Atom") {
                r.constructed.insert(o.symbol.clone());
            }
            r.semantics.insert(o.symbol, semantic_digest);
        }
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
                    "RoleBefore" | "SceneBefore" => slot.time_role == "before",
                    "RoleAfter" | "SceneAfter" => slot.time_role == "after",
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
            .with_context(|| format!("unknown sort {name}"))
            .and_then(|i| Ok(u32::try_from(i)?))
    }

    pub fn definition_semantics(&self, body: &Term) -> Result<String> {
        let mut used = BTreeSet::new();
        let mut missing = false;
        body.walk(&mut Vec::new(), &mut |_, term| {
            let op = match term {
                Term::Call { operator, .. } => std::borrow::Cow::Borrowed(operator.as_str()),
                Term::Const { .. } => std::borrow::Cow::Owned(term.show("?#")),
                _ => return,
            };
            if let Some(signature) = self.semantics.get(op.as_ref()) {
                used.insert(signature);
            } else {
                missing = true;
            }
        });
        ensure!(
            !missing,
            "definition uses an operation without semantic identity"
        );
        Ok(digest(&serde_json::to_vec(&used)?))
    }

    pub fn register_definition(&mut self, name: &str, definition: &Definition) -> Result<()> {
        self.register(name, &definition.parameter_sorts, &definition.result_sort)?;
        self.semantics
            .insert(name.to_owned(), definition.semantic_digest.clone());
        self.constructed.insert(name.to_owned());
        Ok(())
    }

    pub fn is_constructed(&self, name: &str) -> bool {
        self.constructed.contains(name)
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

fn tokenize(text: &str) -> Result<Vec<&str>> {
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
    Ok(tokens)
}

fn parse_tokens<'a>(tokens: &[&'a str]) -> Result<Syntax<'a>> {
    let mut tokens = tokens.iter().copied();
    let mut stack: Vec<Syntax<'a>> = Vec::new();
    let mut root = None;
    while let Some(token) = tokens.next() {
        ensure!(root.is_none(), "trailing expression");
        let node = match token {
            "(" => {
                let head = tokens.next().context("missing operator")?;
                ensure!(!matches!(head, "(" | ")"), "invalid operator");
                stack.push(Syntax {
                    head,
                    children: Vec::new(),
                });
                // Each call consumes two JSON container levels in a wire term.
                // Reserve room for the enclosing library/proof records under serde_json's 128.
                ensure!(
                    2 * stack.len() + 8 < 128,
                    "wire JSON body depth is unsupported"
                );
                continue;
            }
            ")" => stack.pop().context("unexpected closing parenthesis")?,
            _ => Syntax {
                head: token,
                children: Vec::new(),
            },
        };
        if let Some(parent) = stack.last_mut() {
            parent.children.push(node);
        } else {
            root = Some(node);
        }
    }
    ensure!(stack.is_empty(), "unclosed expression");
    root.context("missing expression")
}

fn parse(text: &str) -> Result<Syntax<'_>> {
    parse_tokens(&tokenize(text)?)
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
    let tokens = tokenize(lambda)?;
    let mut closed = tokens.as_slice();
    for _ in 0..count {
        closed = closed
            .strip_prefix(&["(", "lam"])
            .context("missing outer binder")?;
        closed = closed
            .strip_suffix(&[")"])
            .context("unclosed outer binder")?;
    }
    let decoded = decode(parse_tokens(closed)?, r, Mode::Lambda(count))?;
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
    pub semantic_digest: String,
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
            &def.semantic_digest,
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
            self.arity == self.parameter_sorts.len(),
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
        ensure!(
            self.semantic_digest == r.definition_semantics(&body)?,
            "definition semantic digest differs"
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

#[cfg(test)]
mod tests {
    use super::*;

    fn balanced(parts: &[String]) -> String {
        if parts.len() == 1 {
            return parts[0].clone();
        }
        let middle = parts.len() / 2;
        format!(
            "(combine {} {})",
            balanced(&parts[..middle]),
            balanced(&parts[middle..])
        )
    }

    #[test]
    fn wide_first_order_interfaces() -> Result<()> {
        for width in [0, 1, 8, 9, 19, 64, 65, 1000] {
            let slots = (0..width)
                .map(|index| SlotSpec {
                    index,
                    sort: "Atom".into(),
                    time_role: "timeless".into(),
                    role_constraints: vec![],
                })
                .collect::<Vec<_>>();
            let mut registry = Registry::new(
                serde_json::from_str(
                    r#"{
                    "schema_version":3,"signature_id":"codec","sorts":[{"id":"Atom"}],
                    "operators":[
                        {"symbol":"a","inputs":[],"output":"Atom","purity":"pure","read_rule":[],"binder_children":[],"semantic_version":"symbolic-v1"},
                        {"symbol":"wrap","inputs":["Atom"],"output":"Atom","purity":"pure","read_rule":[0],"binder_children":[],"semantic_version":"symbolic-v1"},
                        {"symbol":"combine","inputs":["Atom","Atom"],"output":"Atom","purity":"pure","read_rule":[0,1],"binder_children":[],"semantic_version":"symbolic-v1"}
                    ]
                }"#,
                )?,
                &slots,
            )?;
            let sorts = vec!["Atom".to_owned(); width];
            let pattern = if width == 0 {
                "a".into()
            } else if width == 1 {
                "(wrap ?#0)".into()
            } else {
                balanced(&(0..width).map(|i| format!("?#{i}")).collect::<Vec<_>>())
            };
            let bound = if width == 0 {
                "a".into()
            } else if width == 1 {
                "(wrap $0)".into()
            } else {
                balanced(
                    &(0..width)
                        .rev()
                        .map(|i| format!("${i}"))
                        .collect::<Vec<_>>(),
                )
            };
            let lambda = format!("{}{bound}{}", "(lam ".repeat(width), ")".repeat(width));
            let body = definitions(&pattern, &lambda, &registry, &sorts)?;
            let d = Definition {
                temporary_name: "fn_0".into(),
                arity: width,
                parameter_sorts: sorts.clone(),
                result_sort: "Atom".into(),
                parameter_reads: (0..width).collect(),
                body_cost: body.cost().to_string(),
                semantic_digest: registry.definition_semantics(&body)?,
                body,
                pattern_text: pattern.clone(),
                closed_lambda_text: lambda.clone(),
                dependencies: vec![],
            };
            d.check(&registry)?;
            let wire: Definition = serde_json::from_slice(&serde_json::to_vec(&d)?)?;
            wire.check(&registry)?;
            registry.register_definition("fn_0", &d)?;
            let call = Term::call(
                "fn_0",
                (0..width).map(|index| Term::Slot { index }).collect(),
            );
            assert_eq!(program(&call.show("?#"), &registry)?, call);
            assert!(definitions(&pattern, &format!("(lam {lambda})"), &registry, &sorts).is_err());
            if width > 0 {
                let invalid = lambda.replacen(&format!("${}", width - 1), &format!("${width}"), 1);
                assert!(definitions(&pattern, &invalid, &registry, &sorts).is_err());
            }
        }
        Ok(())
    }
}
