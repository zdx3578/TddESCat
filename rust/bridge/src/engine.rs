use crate::{
    codec::{
        Definition, LibraryEntry, Registry, Term, definitions, dependencies, program, stable_id,
    },
    protocol::Config,
};
use anyhow::{Context, Result, ensure};
use egg::{Applier, EGraph, FromOp, Id, Pattern, PatternAst, Rewrite, Subst, Symbol, Var};
use egg_stitch::{
    Args, best_first, cost, io,
    lang::{
        Op, OpChildren, OpChildrenLanguage, OpDB, SearchBudgetStop, StitchAnalysis, TypedSearch,
        Weights,
    },
    shared::SharedData,
};
use std::{collections::BTreeMap, sync::Arc, time::Instant};

type Operator = OpDB<Op>;
type Language = OpChildrenLanguage<Operator>;
type Graph = EGraph<Language, StitchAnalysis>;
type Data = SharedData<OpChildren, Operator>;
type Rule = Rewrite<Language, StitchAnalysis>;
pub type Library = BTreeMap<String, Definition>;

pub fn import(
    registry: &mut Registry,
    entries: Vec<LibraryEntry>,
) -> Result<(Library, Vec<String>, u64)> {
    let mut library = Library::new();
    let mut order = Vec::new();
    let mut total = 0u64;
    for item in entries {
        let d = item.definition;
        ensure!(
            item.stable_id == stable_id(&d)?,
            "library content ID mismatch"
        );
        ensure!(
            d.dependencies.iter().all(|id| library.contains_key(id)),
            "missing or non-topological dependency"
        );
        d.check(registry)?;
        registry.register(&item.stable_id, &d.parameter_sorts, &d.result_sort)?;
        total = total
            .checked_add(d.body.cost())
            .context("library cost overflow")?;
        order.push(item.stable_id.clone());
        library.insert(item.stable_id, d);
    }
    Ok((library, order, total))
}

fn add(term: &Term, args: &[Id], graph: &mut Graph) -> Id {
    if let Term::Param { index } = term {
        return args[*index];
    }
    let (head, nodes) = match term {
        Term::Call {
            operator,
            args: children,
        } => (
            operator.clone(),
            children
                .iter()
                .map(|child| add(child, args, graph))
                .collect(),
        ),
        _ => (term.show("?m"), Vec::new()),
    };
    graph.add(Language::from_op(&head, nodes).expect("validated worker expression"))
}

struct TypedApplier {
    right: Term,
    variables: Vec<(Var, u32)>,
    sort: u32,
}

impl Applier<Language, StitchAnalysis> for TypedApplier {
    fn vars(&self) -> Vec<Var> {
        self.variables.iter().map(|&(v, _)| v).collect()
    }

    fn apply_one(
        &self,
        graph: &mut Graph,
        class: Id,
        subst: &Subst,
        _: Option<&PatternAst<Language>>,
        _: Symbol,
    ) -> Vec<Id> {
        let class = graph.find(class);
        assert_eq!(graph[class].data.sort, Some(self.sort));
        let args = self
            .variables
            .iter()
            .map(|&(v, sort)| {
                let id = graph.find(subst[v]);
                assert_eq!(graph[id].data.sort, Some(sort));
                id
            })
            .collect::<Vec<_>>();
        let right = add(&self.right, &args, graph);
        assert_eq!(graph[class].data.sort, graph[right].data.sort);
        assert_eq!(graph[class].data.fv, graph[right].data.fv);
        if graph.union(class, right) {
            vec![right]
        } else {
            Vec::new()
        }
    }
}

fn refinements(registry: &Registry, library: &Library, order: &[String]) -> Result<Vec<Rule>> {
    let mut rules = Vec::new();
    for name in order {
        let d = &library[name];
        let call = Term::call(
            name,
            (0..d.arity).map(|index| Term::Param { index }).collect(),
        );
        for (direction, source, target) in [("unfold", &call, &d.body), ("fold", &d.body, &call)] {
            let variables = d
                .parameter_sorts
                .iter()
                .enumerate()
                .map(|(i, sort)| Ok((format!("?m{i}").parse()?, registry.sort_id(sort)?)))
                .collect::<Result<Vec<_>>>()?;
            let left: Pattern<Language> = source.show("?m").parse()?;
            rules.push(
                Rewrite::new(
                    format!("def.{name}.{direction}"),
                    left,
                    TypedApplier {
                        right: target.clone(),
                        variables,
                        sort: registry.sort_id(&d.result_sort)?,
                    },
                )
                .map_err(anyhow::Error::msg)?,
            );
        }
    }
    Ok(rules)
}

fn assert_expense(graph: &Graph) {
    let limits = graph.analysis.typed.as_ref().unwrap();
    limits.check_graph(graph.total_size());
}

fn saturate(graph: &mut Graph, rules: &[Rule]) {
    let limits = Arc::clone(graph.analysis.typed.as_ref().unwrap());
    for _ in 0..32 {
        let mut changes = false;
        for rule in rules {
            limits.check();
            let matches = rule.search_with_limit(graph, limits.max_relation_nodes + 1);
            let count = matches.iter().map(|m| m.substs.len()).sum();
            limits.check_rows(count);
            changes |= !rule.apply(graph, &matches).is_empty();
            graph.rebuild();
            assert_expense(graph);
        }
        if !changes {
            return;
        }
    }
    std::panic::panic_any(SearchBudgetStop("step_budget"));
}

fn make_graph(
    c: &Config,
    r: &Registry,
    terms: &[Term],
    library: &Library,
    order: &[String],
    deadline: Instant,
) -> Result<Data> {
    let limits = Arc::new(TypedSearch {
        ports: r.ports.clone(),
        deadline,
        max_egraph_nodes: c.budget.max_egraph_nodes,
        max_live_states: c.budget.max_live_states,
        max_relation_nodes: c.budget.max_relation_nodes,
    });
    let mut graph = Graph::new(StitchAnalysis {
        weights: Weights::default(),
        typed: Some(limits),
    });
    let checked = terms
        .iter()
        .map(|term| {
            r.infer(term, None)?;
            Ok(add(term, &[], &mut graph))
        })
        .collect::<Result<Vec<_>>>()?;
    let root = graph.add(Language::from_op("programs", checked)?);
    graph.rebuild();
    saturate(&mut graph, &refinements(r, library, order)?);
    Ok(SharedData::new(graph, root))
}

pub struct Round {
    pub baseline_cost: u64,
    pub programs: Vec<Term>,
    pub found: Option<(String, Definition)>,
    pub exhausted: bool,
    pub expansions: usize,
}

pub fn corpus_cost(terms: &[Term]) -> u64 {
    terms
        .iter()
        .try_fold(1u64, |n, t| n.checked_add(t.cost()))
        .expect("corpus cost overflow")
}

#[allow(clippy::too_many_arguments)]
pub fn search(
    config: &Config,
    mut registry: Registry,
    input: &[Term],
    library: &Library,
    order: &[String],
    deadline: Instant,
    step_limit: usize,
    round: usize,
) -> Result<Round> {
    use clap::Parser;
    let mut args = Args::try_parse_from([
        "egg-stitch",
        "--search",
        "best-first",
        "--opt-seen",
        "--no-opt-dedup-by-match",
        "--no-opt-dominance-reuse",
        "--no-opt-useless-frozen",
        "--no-opt-useless-inline",
    ])?;
    args.max_arity = config.max_arity;
    args.num_steps = Some(step_limit);
    args.normalize();
    let data = make_graph(config, &registry, input, library, order, deadline)?;
    let result = best_first::best_first(data, &args);
    let mut data = result.data;
    let mut found = None;
    let baseline_cost = result.original_size as u64;
    let mut expected = baseline_cost;
    if let Some((cost, selection)) = result.best
        && (cost as u64) < baseline_cost
    {
        let pattern = &selection.state.pattern;
        let variables = &selection.selection.candidate.variable_indices;
        ensure!(
            variables.iter().all(Vec::is_empty),
            "unexpected binder capture in first-order search"
        );
        let sorts = selection.state.sorts(&data.egraph);
        let parameter_sorts = sorts[1..]
            .iter()
            .map(|&sort| registry.sorts[sort as usize].clone())
            .collect::<Vec<_>>();
        let result_sort = registry.sorts[sorts[0] as usize].clone();
        let pattern_text = pattern.display_with_ho(variables);
        let closed_lambda_text = pattern.display_as_lambda(variables);
        let body = definitions(
            &pattern_text,
            &closed_lambda_text,
            &registry,
            &parameter_sorts,
        )?;
        let temporary_name = format!("fn_{}", round - 1);
        let def = Definition {
            arity: parameter_sorts.len(),
            parameter_reads: (0..parameter_sorts.len()).collect(),
            temporary_name: temporary_name.clone(),
            parameter_sorts,
            result_sort,
            body_cost: body.cost().to_string(),
            dependencies: dependencies(&body),
            body,
            pattern_text,
            closed_lambda_text,
        };
        def.check(&registry)?;
        registry.register(&temporary_name, &def.parameter_sorts, &def.result_sort)?;
        Arc::make_mut(data.egraph.analysis.typed.as_mut().unwrap()).ports = registry.ports.clone();
        data.egraph = cost::build_rewritten_egraph(
            data.egraph,
            &selection.state,
            &selection.selection.candidate,
            &temporary_name,
        );
        expected = cost as u64 - def.body.cost();
        found = Some((temporary_name, def));
    }
    assert_expense(&data.egraph);
    let programs = io::extract_programs(&data.egraph, data.root)
        .iter()
        .map(|text| program(text, &registry))
        .collect::<Result<Vec<_>>>()?;
    ensure!(
        programs.len() == input.len() && corpus_cost(&programs) == expected,
        "engine and independent output cost disagree"
    );
    Ok(Round {
        baseline_cost,
        programs,
        found,
        exhausted: result.heap_size_at_end == 0,
        expansions: result.num_expansions,
    })
}
