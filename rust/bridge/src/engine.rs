use crate::{
    codec::{
        Definition, LibraryEntry, Registry, Term, definitions, dependencies, program, stable_id,
    },
    protocol::Config,
    resources::{self, Phase},
};
use anyhow::{Context, Result, ensure};
use egg::{Applier, EGraph, FromOp, Id, Pattern, PatternAst, Rewrite, Subst, Symbol, Var};
use egg_stitch::{
    Args, best_first, cost, io,
    lang::{Op, OpChildren, OpChildrenLanguage, OpDB, StitchAnalysis, TypedSearch, Weights},
    shared::SharedData,
};
use std::{collections::BTreeMap, sync::Arc};

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
        registry.register_definition(&item.stable_id, &d)?;
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
    loop {
        let mut changes = false;
        for rule in rules {
            limits.check();
            let matches = rule.search(graph);
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
}

fn make_graph(
    c: &Config,
    r: &Registry,
    terms: &[Term],
    library: &Library,
    order: &[String],
) -> Result<Data> {
    let limits = Arc::new(TypedSearch {
        ports: r.ports.clone(),
        deadline: None,
        max_egraph_nodes: None,
        max_live_states: None,
        max_relation_nodes: None,
        apply_chunk_rows: c.processing.apply_chunk_rows,
        check_managed: resources::check,
        observe_rows: resources::observe_rows,
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
    let _span = resources::phase(Phase::Saturation);
    saturate(&mut graph, &refinements(r, library, order)?);
    Ok(SharedData::new(graph, root))
}

pub struct Round {
    pub baseline_cost: u64,
    pub programs: Vec<Term>,
    pub found: Option<(String, Definition)>,
    pub exhausted: bool,
    pub expansions: usize,
    pub heap_pops: usize,
    pub arena_peak: usize,
    pub frontier_peak: usize,
    pub egraph_nodes: usize,
    pub egraph_classes: usize,
}

pub fn corpus_cost(terms: &[Term]) -> u64 {
    terms
        .iter()
        .try_fold(1u64, |n, t| n.checked_add(t.cost()))
        .expect("corpus cost overflow")
}

pub fn search_args(config: &Config) -> Result<Args> {
    use clap::Parser;
    let options = &config.search_options;
    let rows = options.decompose_min_rows.to_string();
    let flags = [
        "egg-stitch",
        "--search",
        "best-first",
        "--priority",
        &options.priority,
        "--freeze-rule",
        &options.freeze_rule,
        "--var-order",
        &options.var_order,
        "--lower-bound",
        &options.lower_bound,
        "--decompose-min-rows",
        &rows,
    ];
    let mut args = Args::try_parse_from(flags)?;
    args.opt_seen = options.opt_seen;
    args.opt_dedup_by_match = options.opt_dedup_by_match;
    args.opt_dominance_reuse = options.opt_dominance_reuse;
    args.opt_useless_frozen = options.opt_useless_frozen;
    args.opt_useless_inline = options.opt_useless_inline;
    args.allow_useless_vars = options.allow_useless_vars;
    args.no_zero_arity = options.no_zero_arity;
    args.max_arity = config.max_arity;
    args.normalize();
    Ok(args)
}

pub fn effective_search_options(args: &Args) -> serde_json::Value {
    use clap::ValueEnum;
    serde_json::json!({
        "priority": args.priority.to_possible_value().unwrap().get_name(),
        "freeze_rule": args.freeze_rule.resolve(true),
        "var_order": args.var_order.to_possible_value().unwrap().get_name(),
        "lower_bound": args.lower_bound.resolve(true),
        "opt_seen": args.opt_seen,
        "opt_dedup_by_match": args.opt_dedup_by_match,
        "opt_dominance_reuse": args.opt_dominance_reuse,
        "opt_useless_frozen": args.opt_useless_frozen,
        "opt_useless_inline": args.opt_useless_inline,
        "allow_useless_vars": args.allow_useless_vars,
        "no_zero_arity": args.no_zero_arity,
        "decompose_min_rows": args.decompose_min_rows,
        "max_arity": args.max_arity,
    })
}

#[cfg(test)]
mod search_options_tests {
    use super::*;

    #[test]
    fn all_boolean_combinations_reach_the_actual_args() {
        let mut config = Config::load(include_bytes!("../../../config/stitch.toml")).unwrap();
        let expected = serde_json::json!({
            "priority": "cost", "freeze_rule": true, "var_order": "mean-nodes-per-class",
            "lower_bound": true, "opt_seen": true, "opt_dedup_by_match": false,
            "opt_dominance_reuse": false, "opt_useless_frozen": false,
            "opt_useless_inline": false, "allow_useless_vars": false, "no_zero_arity": false,
            "decompose_min_rows": 48, "max_arity": 1000
        });
        assert_eq!(
            effective_search_options(&search_args(&config).unwrap()),
            expected
        );

        for mask in 0u32..32 {
            let flags = std::array::from_fn::<_, 5, _>(|bit| mask & (1 << bit) != 0);
            let options = &mut config.search_options;
            [
                options.opt_seen,
                options.opt_dedup_by_match,
                options.opt_dominance_reuse,
                options.opt_useless_frozen,
                options.opt_useless_inline,
            ] = flags;
            options.allow_useless_vars = false;
            let args = search_args(&config).unwrap();
            assert_eq!(
                [
                    args.opt_seen,
                    args.opt_dedup_by_match,
                    args.opt_dominance_reuse,
                    args.opt_useless_frozen,
                    args.opt_useless_inline,
                ],
                flags
            );

            config.search_options.allow_useless_vars = true;
            config.search_options.no_zero_arity = true;
            let args = search_args(&config).unwrap();
            assert!(args.allow_useless_vars && args.no_zero_arity);
            assert_eq!(args.opt_seen, flags[0]);
            assert_eq!(args.opt_dedup_by_match, flags[1]);
            assert!(
                !(args.opt_dominance_reuse || args.opt_useless_frozen || args.opt_useless_inline)
            );
        }
    }
}

pub fn search(
    config: &Config,
    args: &Args,
    mut registry: Registry,
    input: &[Term],
    library: &Library,
    order: &[String],
    round: usize,
) -> Result<Round> {
    let graph_phase = resources::phase(Phase::Graph);
    let data = make_graph(config, &registry, input, library, order)?;
    let egraph_nodes = data.egraph.total_size();
    let egraph_classes = data.egraph.number_of_classes();
    drop(graph_phase);
    let search_phase = resources::phase(Phase::Search);
    let mut heap_pops = 0;
    let mut arena_peak = 0;
    let mut frontier_peak = 0;
    let result = best_first::best_first_with_progress(data, args, |pops, arena, frontier| {
        heap_pops = pops;
        arena_peak = arena_peak.max(arena);
        frontier_peak = frontier_peak.max(frontier);
        if config
            .progress
            .search_pop_checkpoints
            .binary_search(&pops)
            .is_ok()
        {
            println!("progress round={round} heap_pops={pops} arena={arena} frontier={frontier}");
        }
    });
    drop(search_phase);
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
            semantic_digest: registry.definition_semantics(&body)?,
            dependencies: dependencies(&body),
            body,
            pattern_text,
            closed_lambda_text,
        };
        def.check(&registry)?;
        registry.register_definition(&temporary_name, &def)?;
        Arc::make_mut(data.egraph.analysis.typed.as_mut().unwrap()).ports = registry.ports.clone();
        let apply_phase = resources::phase(Phase::Apply);
        data.egraph = cost::build_rewritten_egraph(
            data.egraph,
            &selection.state,
            &selection.selection.candidate,
            &temporary_name,
        );
        drop(apply_phase);
        expected = cost as u64 - def.body.cost();
        found = Some((temporary_name, def));
    }
    assert_expense(&data.egraph);
    let extract_phase = resources::phase(Phase::Extract);
    let programs = io::extract_programs(&data.egraph, data.root)
        .iter()
        .map(|text| program(text, &registry))
        .collect::<Result<Vec<_>>>()?;
    ensure!(
        programs.len() == input.len() && corpus_cost(&programs) == expected,
        "engine and independent output cost disagree"
    );
    resources::check();
    drop(extract_phase);
    Ok(Round {
        baseline_cost,
        programs,
        found,
        exhausted: result.heap_size_at_end == 0,
        expansions: result.num_expansions,
        heap_pops,
        arena_peak,
        frontier_peak,
        egraph_nodes,
        egraph_classes,
    })
}
