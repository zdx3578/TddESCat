use std::collections::BTreeSet;

use atddc::atdd::canonical::{Pivot, canonicalize};
use atddc::atdd::combine::{hadamard, term};
use atddc::atdd::contract::{Partial, equal_funcs, point_eval};
use atddc::atdd::linalg::{Mat, Q};
use atddc::atdd::minimize::minimize;
use atddc::atdd::{Atdd, NodeData, ops, pipeline, rotate};
use atddc::vtree::Vtree;
use num_bigint::BigInt;
use num_traits::{One, Zero};
use serde::{Deserialize, Serialize};

type Result<T> = std::result::Result<T, &'static str>;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Formula {
    Constant { value: bool },
    Cube { literals: Vec<(usize, bool)> },
    And { args: Vec<Formula> },
    Or { args: Vec<Formula> },
    Not { arg: Box<Formula> },
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
enum TreeStyle {
    Balanced,
    RightLinear,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Edit {
    Remove { bit: usize },
    Rotate { node: usize, left: bool },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Layout {
    order: Vec<usize>,
    style: TreeStyle,
    #[serde(default)]
    edits: Vec<Edit>,
}

impl Layout {
    fn tree(&self) -> Result<Option<Vtree>> {
        let count = self.order.len();
        if self.order.iter().copied().collect::<BTreeSet<_>>() != (0..count).collect() {
            return Err("variable order must be a permutation of the initial bit range");
        }
        let mut tree = if self.order.is_empty() {
            None
        } else {
            Some(match self.style {
                TreeStyle::Balanced => Vtree::balanced_order(&self.order),
                TreeStyle::RightLinear => Vtree::right_linear_order(&self.order),
            })
        };
        for edit in &self.edits {
            let current = tree.as_ref().ok_or("no remaining variable tree")?;
            tree = match *edit {
                Edit::Remove { bit } => {
                    if !current.leaf_order().contains(&bit) {
                        return Err("unknown bit");
                    }
                    (current.n_vars() > 1).then(|| current.without_var(bit).0)
                }
                Edit::Rotate { node, left } => {
                    if node >= current.num_nodes() {
                        return Err("unknown rotation node");
                    }
                    Some(if left && current.is_left_rotatable(node) {
                        current.left_rotate(node)
                    } else if !left && current.is_right_rotatable(node) {
                        current.right_rotate(node)
                    } else {
                        return Err("invalid rotation");
                    })
                }
            };
        }
        Ok(tree)
    }
}

#[derive(Clone)]
enum Function {
    Constant(bool),
    Canonical(Atdd, Vec<Vec<Pivot>>),
}

#[derive(Clone)]
pub struct Diagram {
    layout: Layout,
    tree: Option<Vtree>,
    function: Function,
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Combine {
    And,
    Or,
}

impl Diagram {
    pub fn compile(layout: Layout, formula: Formula) -> Result<Self> {
        let tree = layout.tree()?;
        let function = compile(&formula, tree.as_ref())?;
        Ok(Self {
            layout,
            tree,
            function,
        })
    }

    pub fn variables(&self) -> &[usize] {
        self.tree
            .as_ref()
            .map(Vtree::leaf_order)
            .unwrap_or_default()
    }

    fn nonzero(&self) -> bool {
        !matches!(self.function, Function::Constant(false))
    }

    pub fn count(&self) -> String {
        match &self.function {
            Function::Constant(false) => "0".into(),
            Function::Constant(true) => (BigInt::one() << self.variables().len()).to_string(),
            Function::Canonical(data, _) => {
                let count = data.model_count(self.tree.as_ref().unwrap());
                debug_assert!(count.denom().is_one() && count.numer() >= &BigInt::zero());
                count.numer().to_string()
            }
        }
    }

    pub fn evaluate(&self, assignment: &[(usize, bool)]) -> Result<bool> {
        let bits: BTreeSet<_> = assignment.iter().map(|&(bit, _)| bit).collect();
        if bits.len() != assignment.len() || bits != self.variables().iter().copied().collect() {
            return Err("a complete assignment over the active variables is required");
        }
        Ok(match &self.function {
            Function::Constant(value) => *value,
            Function::Canonical(data, _) => {
                let tree = self.tree.as_ref().unwrap();
                let mut point = Partial::default();
                for &(bit, value) in assignment {
                    point.set(bit, value);
                }
                point_eval(data, tree, tree.root(), &point)[0].is_one()
            }
        })
    }

    fn compatible(&self, other: &Self) -> Result<()> {
        match (&self.tree, &other.tree) {
            (None, None) => Ok(()),
            (Some(lhs), Some(rhs))
                if lhs.num_nodes() == rhs.num_nodes()
                    && lhs.root() == rhs.root()
                    && (0..lhs.num_nodes()).all(|id| {
                        let a = lhs.node(id);
                        let b = rhs.node(id);
                        (a.var, a.left, a.right) == (b.var, b.left, b.right)
                    }) =>
            {
                Ok(())
            }
            _ => Err("different active variable trees"),
        }
    }

    pub fn combine(&self, other: &Self, operation: Combine) -> Result<Self> {
        self.compatible(other)?;
        let function = combine(
            &self.function,
            &other.function,
            operation,
            self.tree.as_ref(),
        )?;
        Ok(Self {
            function,
            ..self.clone()
        })
    }

    pub fn negate(&self) -> Result<Self> {
        let function = negate(&self.function, self.tree.as_ref())?;
        Ok(Self {
            function,
            ..self.clone()
        })
    }

    pub fn forget_or_condition(&self, bit: usize, condition: Option<bool>) -> Result<Self> {
        let tree = self.tree.as_ref().ok_or("no remaining variables")?;
        if !tree.leaf_order().contains(&bit) {
            return Err("unknown bit");
        }
        let mut layout = self.layout.clone();
        layout.edits.push(Edit::Remove { bit });
        let new_tree = layout.tree()?;
        let function = match &self.function {
            Function::Constant(value) => Function::Constant(*value),
            Function::Canonical(data, _) => {
                if let Some(expected) = new_tree.as_ref() {
                    let (induced, raw) = if let Some(value) = condition {
                        ops::condition(data, tree, bit, value)
                    } else {
                        ops::forget(data, tree, bit)
                    };
                    debug_assert_eq!(expected.leaf_order(), induced.leaf_order());
                    normalize(raw, &induced)?
                } else {
                    let value = match condition {
                        Some(value) => self.evaluate(&[(bit, value)])?,
                        None => self.nonzero(),
                    };
                    Function::Constant(value)
                }
            }
        };
        Ok(Self {
            layout,
            tree: new_tree,
            function,
        })
    }

    pub fn equal(&self, other: &Self) -> Result<bool> {
        self.compatible(other)?;
        Ok(match (&self.function, &other.function) {
            (Function::Constant(a), Function::Constant(b)) => a == b,
            (Function::Constant(false), _) | (_, Function::Constant(false)) => false,
            (Function::Constant(true), _) => other.count() == self.count(),
            (_, Function::Constant(true)) => self.count() == other.count(),
            (Function::Canonical(a, _), Function::Canonical(b, _)) => {
                equal_funcs(a, b, self.tree.as_ref().unwrap())
            }
        })
    }

    pub fn counterexample(&self, other: &Self) -> Result<Option<Vec<(usize, bool)>>> {
        self.compatible(other)?;
        let mut remaining = self.combine(&other.negate()?, Combine::And)?;
        if !remaining.nonzero() {
            return Ok(None);
        }
        let mut witness = Vec::with_capacity(self.variables().len());
        for &bit in self.variables() {
            let low = remaining.forget_or_condition(bit, Some(false))?;
            let value = !low.nonzero();
            remaining = if value {
                remaining.forget_or_condition(bit, Some(true))?
            } else {
                low
            };
            witness.push((bit, value));
        }
        if !self.evaluate(&witness)? || other.evaluate(&witness)? {
            return Err("counterexample verification failed");
        }
        Ok(Some(witness))
    }

    pub fn rotated(&self, node: usize, left: bool) -> Result<Self> {
        let mut layout = self.layout.clone();
        layout.edits.push(Edit::Rotate { node, left });
        let tree = layout.tree()?;
        let function = match &self.function {
            Function::Constant(value) => Function::Constant(*value),
            Function::Canonical(data, pivots) => {
                let old = self.tree.as_ref().unwrap();
                let result = if left {
                    rotate::left_rotate(old, data, pivots, node)
                } else {
                    rotate::right_rotate(old, data, pivots, node)
                };
                Function::Canonical(result.atdd, result.pivots)
            }
        };
        Ok(Self {
            layout,
            tree,
            function,
        })
    }
}

fn normalize(mut data: Atdd, tree: &Vtree) -> Result<Function> {
    data.check(tree).map_err(|_| "invalid ATDD shape")?;
    if data.is_zero_function(tree) {
        return Ok(Function::Constant(false));
    }
    minimize(&mut data, tree);
    let pivots = canonicalize(&mut data, tree);
    data.check(tree)
        .map_err(|_| "invalid normalized ATDD shape")?;
    Ok(Function::Canonical(data, pivots))
}

fn compile(formula: &Formula, tree: Option<&Vtree>) -> Result<Function> {
    match formula {
        Formula::Constant { value } => Ok(Function::Constant(*value)),
        Formula::Cube { literals } => {
            let mut bits = std::collections::BTreeMap::new();
            let mut conflict = false;
            for &(bit, value) in literals {
                if !tree.is_some_and(|t| t.leaf_order().contains(&bit)) {
                    return Err("cube contains an unknown bit");
                }
                if bits.insert(bit, value).is_some_and(|old| old != value) {
                    conflict = true;
                }
            }
            if conflict || bits.is_empty() {
                return Ok(Function::Constant(!conflict));
            }
            let tree = tree.unwrap();
            normalize(term(tree, &bits.into_iter().collect::<Vec<_>>()), tree)
        }
        Formula::And { args } | Formula::Or { args } => {
            let and = matches!(formula, Formula::And { .. });
            let operation = if and { Combine::And } else { Combine::Or };
            let mut result = Function::Constant(and);
            for arg in args {
                result = combine(&result, &compile(arg, tree)?, operation, tree)?;
            }
            Ok(result)
        }
        Formula::Not { arg } => negate(&compile(arg, tree)?, tree),
    }
}

fn combine(
    left: &Function,
    right: &Function,
    operation: Combine,
    tree: Option<&Vtree>,
) -> Result<Function> {
    use Function::{Canonical, Constant};
    let identity = matches!(operation, Combine::And);
    match (left, right) {
        (Constant(value), other) | (other, Constant(value)) => Ok(if *value == identity {
            other.clone()
        } else {
            Constant(*value)
        }),
        (Canonical(a, _), Canonical(b, _)) => {
            let tree = tree.unwrap();
            let raw = match operation {
                Combine::And => hadamard(a, b, tree),
                Combine::Or => ops::disjoin(a, b, tree),
            };
            normalize(raw, tree)
        }
    }
}

fn negate(function: &Function, tree: Option<&Vtree>) -> Result<Function> {
    if let Function::Canonical(data, _) = function {
        let tree = tree.unwrap();
        normalize(ops::negate(data, tree), tree)
    } else if let Function::Constant(value) = function {
        Ok(Function::Constant(!value))
    } else {
        unreachable!()
    }
}

#[derive(Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct Matrix {
    rows: usize,
    columns: usize,
    entries: Vec<(String, String)>,
}

impl TryFrom<Matrix> for Mat {
    type Error = &'static str;

    fn try_from(matrix: Matrix) -> Result<Self> {
        if matrix.rows.checked_mul(matrix.columns) != Some(matrix.entries.len()) {
            return Err("invalid matrix size");
        }
        let entries: Vec<Q> = matrix
            .entries
            .into_iter()
            .map(|(n, d)| {
                let numerator: BigInt = n.parse().map_err(|_| "invalid numerator")?;
                let denominator: BigInt = d.parse().map_err(|_| "invalid denominator")?;
                if denominator <= BigInt::zero() {
                    return Err("non-positive denominator");
                }
                let value = Q::new(numerator, denominator);
                if value.numer().to_string() != n || value.denom().to_string() != d {
                    return Err("noncanonical rational coefficient");
                }
                Ok(value)
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(Mat::from_fn(matrix.rows, matrix.columns, |row, col| {
            entries[row * matrix.columns + col].clone()
        }))
    }
}

impl From<&Mat> for Matrix {
    fn from(matrix: &Mat) -> Self {
        let mut entries = Vec::with_capacity(matrix.r * matrix.c);
        for row in 0..matrix.r {
            for col in 0..matrix.c {
                let value = matrix.at(row, col);
                entries.push((value.numer().to_string(), value.denom().to_string()));
            }
        }
        Self {
            rows: matrix.r,
            columns: matrix.c,
            entries,
        }
    }
}

#[derive(Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Block {
    Leaf { matrix: Matrix },
    Internal { slices: Vec<Matrix> },
}

impl From<&NodeData> for Block {
    fn from(node: &NodeData) -> Self {
        match node {
            NodeData::Leaf(matrix) => Self::Leaf {
                matrix: matrix.into(),
            },
            NodeData::Internal(slices) => Self::Internal {
                slices: slices.iter().map(Matrix::from).collect(),
            },
        }
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum CanonicalData {
    Constant {
        value: bool,
    },
    Diagram {
        blocks: Vec<Block>,
        pivots: Vec<Vec<Vec<bool>>>,
    },
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Artifact {
    schema_version: u8,
    layout: Layout,
    body: CanonicalData,
}

impl Diagram {
    pub fn export(&self) -> Artifact {
        let body = match &self.function {
            Function::Constant(value) => CanonicalData::Constant { value: *value },
            Function::Canonical(diagram, pivots) => CanonicalData::Diagram {
                blocks: diagram.node.iter().map(Block::from).collect(),
                pivots: pivots
                    .iter()
                    .map(|group| group.iter().map(|p| p.0.clone()).collect())
                    .collect(),
            },
        };
        Artifact {
            schema_version: 1,
            layout: self.layout.clone(),
            body,
        }
    }

    pub fn restore(artifact: Artifact) -> Result<Self> {
        if artifact.schema_version != 1 {
            return Err("unknown artifact version");
        }
        let tree = artifact.layout.tree()?;
        let function = match artifact.body {
            CanonicalData::Constant { value } => Function::Constant(value),
            CanonicalData::Diagram { blocks, pivots } => {
                let tree = tree.as_ref().ok_or("non-scalar artifact has no tree")?;
                let nodes = blocks
                    .into_iter()
                    .map(|block| match block {
                        Block::Leaf { matrix } => Ok(NodeData::Leaf(matrix.try_into()?)),
                        Block::Internal { slices } => {
                            let slices = slices
                                .into_iter()
                                .map(Mat::try_from)
                                .collect::<Result<_>>()?;
                            Ok(NodeData::Internal(slices))
                        }
                    })
                    .collect::<Result<_>>()?;
                let original = Atdd { node: nodes };
                original
                    .check(tree)
                    .map_err(|_| "malformed diagram artifact")?;
                if !pipeline::is_boolean(&original, tree) {
                    return Err("imported function is not Boolean");
                }
                let function = normalize(original.clone(), tree)?;
                let Function::Canonical(diagram, computed) = &function else {
                    return Err("zero functions require a constant artifact");
                };
                if diagram != &original
                    || computed.len() != pivots.len()
                    || computed
                        .iter()
                        .zip(pivots)
                        .any(|(a, b)| a.len() != b.len() || a.iter().zip(b).any(|(p, q)| p.0 != q))
                {
                    return Err("malformed canonical matrices or pivots");
                }
                function
            }
        };
        Ok(Self {
            layout: artifact.layout,
            tree,
            function,
        })
    }
}
