mod diagram;

use std::collections::{HashMap, HashSet};
use std::io::{self, BufRead, Write};
use std::time::{SystemTime, UNIX_EPOCH};

use diagram::{Artifact, Combine, Diagram, Formula, Layout};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

const PROTOCOL: &str = "compute/v1";
type OperationResult = Result<Value, (&'static str, &'static str)>;

#[derive(Clone, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct Lease {
    session: String,
    object: u64,
    lease_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(
    tag = "operation",
    content = "payload",
    rename_all = "snake_case",
    deny_unknown_fields
)]
enum Operation {
    Capabilities,
    CompileBool {
        layout: Layout,
        formula: Formula,
    },
    ApplyBool {
        left: Lease,
        right: Lease,
        op: Combine,
    },
    NegateBool {
        value: Lease,
        domain: Lease,
    },
    ConditionBool {
        value: Lease,
        bit: usize,
        selected: bool,
    },
    ProjectBool {
        value: Lease,
        bits: Vec<usize>,
    },
    CountModels {
        value: Lease,
    },
    EvaluateBool {
        value: Lease,
        assignment: Vec<(usize, bool)>,
    },
    EvaluateBoolBatch {
        value: Lease,
        assignments: Vec<Vec<(usize, bool)>>,
    },
    EqualBool {
        left: Lease,
        right: Lease,
    },
    EntailsBool {
        left: Lease,
        right: Lease,
    },
    RotateBool {
        value: Lease,
        node: usize,
        left: bool,
    },
    Describe {
        value: Lease,
    },
    ExportCanonical {
        value: Lease,
    },
    ImportCanonical {
        artifact: Artifact,
    },
    Acquire {
        value: Lease,
        lease_id: String,
    },
    Release {
        value: Lease,
    },
}

struct Entry {
    diagram: Diagram,
    leases: HashSet<String>,
}

struct Session {
    name: String,
    next_id: u64,
    objects: HashMap<u64, Entry>,
    released: HashSet<Lease>,
}

fn input_error(reason: &'static str) -> (&'static str, &'static str) {
    ("invalid_input", reason)
}

fn compatibility_error(reason: &'static str) -> (&'static str, &'static str) {
    if reason == "different active variable trees" {
        ("unsupported", reason)
    } else {
        input_error(reason)
    }
}

impl Session {
    fn new() -> Self {
        let time = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        Self {
            name: format!("{}-{time}", std::process::id()),
            next_id: 0,
            objects: HashMap::new(),
            released: HashSet::new(),
        }
    }

    fn put(&mut self, diagram: Diagram) -> Value {
        let object = self.next_id;
        self.next_id += 1;
        let lease_id = "initial".to_string();
        self.objects.insert(
            object,
            Entry {
                diagram,
                leases: HashSet::from([lease_id.clone()]),
            },
        );
        json!(Lease {
            session: self.name.clone(),
            object,
            lease_id
        })
    }

    fn get(&self, lease: &Lease) -> Result<&Diagram, (&'static str, &'static str)> {
        if lease.session != self.name {
            return Err(("invalidated", "different worker session"));
        }
        self.objects
            .get(&lease.object)
            .filter(|entry| entry.leases.contains(&lease.lease_id))
            .map(|entry| &entry.diagram)
            .ok_or(("invalidated", "object or lease expired"))
    }

    fn dispatch(&mut self, operation: Operation) -> OperationResult {
        use Operation::*;
        Ok(match operation {
            Capabilities => json!({
                "session":self.name, "backend":"atddc",
                "algebra":"finite_complete_bool", "numeric":"exact_rational",
                "tree_conversion":"checked_local_rotation",
                "artifact_schema":1
            }),
            CompileBool { layout, formula } => {
                self.put(Diagram::compile(layout, formula).map_err(input_error)?)
            }
            ApplyBool { left, right, op } => self.put(
                self.get(&left)?
                    .combine(self.get(&right)?, op)
                    .map_err(compatibility_error)?,
            ),
            NegateBool { value, domain } => {
                let not = self.get(&value)?.negate().map_err(input_error)?;
                self.put(
                    not.combine(self.get(&domain)?, Combine::And)
                        .map_err(compatibility_error)?,
                )
            }
            ConditionBool {
                value,
                bit,
                selected,
            } => self.put(
                self.get(&value)?
                    .forget_or_condition(bit, Some(selected))
                    .map_err(input_error)?,
            ),
            ProjectBool { value, bits } => {
                let mut diagram = self.get(&value)?.clone();
                for bit in bits {
                    diagram = diagram
                        .forget_or_condition(bit, None)
                        .map_err(input_error)?;
                }
                self.put(diagram)
            }
            CountModels { value } => json!(self.get(&value)?.count()),
            EvaluateBool { value, assignment } => {
                json!(
                    self.get(&value)?
                        .evaluate(&assignment)
                        .map_err(input_error)?
                )
            }
            EvaluateBoolBatch { value, assignments } => {
                let diagram = self.get(&value)?;
                let answers = assignments
                    .iter()
                    .map(|point| diagram.evaluate(point))
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(input_error)?;
                json!(answers)
            }
            EqualBool { left, right } => json!(
                self.get(&left)?
                    .equal(self.get(&right)?)
                    .map_err(compatibility_error)?
            ),
            EntailsBool { left, right } => {
                let counterexample = self
                    .get(&left)?
                    .counterexample(self.get(&right)?)
                    .map_err(compatibility_error)?;
                json!({"entailed":counterexample.is_none(),"counterexample":counterexample})
            }
            RotateBool { value, node, left } => {
                self.put(self.get(&value)?.rotated(node, left).map_err(input_error)?)
            }
            Describe { value } => json!({"variables":self.get(&value)?.variables()}),
            ExportCanonical { value } => json!(self.get(&value)?.export()),
            ImportCanonical { artifact } => {
                self.put(Diagram::restore(artifact).map_err(input_error)?)
            }
            Acquire { value, lease_id } => {
                self.get(&value)?;
                if lease_id.is_empty() {
                    return Err(input_error("missing lease identity"));
                }
                let acquired = Lease { lease_id, ..value };
                if self.released.contains(&acquired) {
                    return Err(("invalidated", "lease already released"));
                }
                self.objects
                    .get_mut(&acquired.object)
                    .unwrap()
                    .leases
                    .insert(acquired.lease_id.clone());
                json!(acquired)
            }
            Release { value } => {
                if self.released.contains(&value) {
                    return Ok(json!(true));
                }
                self.get(&value)?;
                let entry = self.objects.get_mut(&value.object).unwrap();
                entry.leases.remove(&value.lease_id);
                if entry.leases.is_empty() {
                    self.objects.remove(&value.object);
                }
                self.released.insert(value);
                json!(true)
            }
        })
    }
}

fn request(session: &mut Session, line: &str) -> Value {
    let Ok(Value::Object(mut request)) = serde_json::from_str::<Value>(line) else {
        return outcome(
            Value::Null,
            Value::Null,
            Err(input_error("invalid request JSON")),
        );
    };
    let id = request.remove("request_id").unwrap_or(Value::Null);
    let snapshot = request.remove("snapshot").unwrap_or(Value::Null);
    let result = if id.as_u64().is_some()
        && snapshot.as_str().is_some_and(|s| !s.is_empty())
        && request.remove("protocol") == Some(json!(PROTOCOL))
    {
        match serde_json::from_value::<Operation>(Value::Object(request)) {
            Ok(operation) => session.dispatch(operation),
            Err(_) => Err(input_error("invalid operation payload")),
        }
    } else {
        Err(input_error("invalid request envelope"))
    };
    outcome(id, snapshot, result)
}

fn outcome(id: Value, snapshot: Value, result: OperationResult) -> Value {
    let (execution, coverage, answer, value, detail) = match result {
        Ok(value) => ("completed", "complete", "value", value, Value::Null),
        Err((status, reason)) => (status, "unavailable", "unknown", Value::Null, json!(reason)),
    };
    json!({
        "protocol":PROTOCOL,"request_id":id,"snapshot":snapshot,
        "execution":execution,"answer":answer,"coverage":coverage,"value":value,"detail":detail
    })
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut session = Session::new();
    let mut output = io::stdout().lock();
    for line in io::stdin().lock().lines() {
        serde_json::to_writer(&mut output, &request(&mut session, &line?))?;
        writeln!(output)?;
        output.flush()?;
    }
    Ok(())
}
