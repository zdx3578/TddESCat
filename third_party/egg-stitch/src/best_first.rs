use clap::ValueEnum;
use colored::Colorize;
use serde::{Deserialize, Serialize};
use std::cmp::Reverse;
use std::collections::{BinaryHeap, HashMap};
use std::time::{Duration, Instant};

use crate::cost::{CostScratch, CostSelection, SearchStateWithCostSelection, compute_cost_and_select};
use crate::footprint::FootprintTracker;
use crate::lang::{LanguageFamily, OpWithVar, StitchDisc, StitchEgraph, StitchOp};
use crate::lower_bound::{LowerBoundPruner, PruneResult};
use crate::search::{SearchState, SeenTracker, SharedSearchData, SuccessorEnum, setup_search};
use egg::Language;

/// How to order the best-first search heap.
#[derive(ValueEnum, Clone, Copy, Debug)]
pub enum SearchPriority {
    /// Lowest compressed-corpus-plus-pattern cost first.
    Cost,
    /// Deepest patterns first.
    DepthFirst,
    /// Shallowest patterns first.
    BreadthFirst,
    /// Patterns with the most e-class matches first.
    MostMatches,
    /// Lexicographic `(forced-expansion, cost)`
    ForcedThenCost,
}

impl SearchPriority {
    /// Parse from the kebab-case string form used by external APIs (e.g. WASM).
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "cost" => Some(Self::Cost),
            "depth-first" => Some(Self::DepthFirst),
            "breadth-first" => Some(Self::BreadthFirst),
            "most-matches" => Some(Self::MostMatches),
            "forced-then-cost" => Some(Self::ForcedThenCost),
            _ => None,
        }
    }

    /// Kebab-case string representation.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Cost => "cost",
            Self::DepthFirst => "depth-first",
            Self::BreadthFirst => "breadth-first",
            Self::MostMatches => "most-matches",
            Self::ForcedThenCost => "forced-then-cost",
        }
    }
}

/// Computes a node's `(heap key, forced-expansion)`; lower key is popped first
/// (the key is a tuple for lexicographic ordering). `forced_lower_bound` is the
/// parent's forced-expansion, used to early-exit the `ForcedThenCost` scan
/// (forced is monotone, so no child drops below it); the returned forced value
/// is threaded down as the next level's bound. Pass `i64::MIN` when there's no
/// parent. `forced` is 0 for strategies that don't use it.
fn priority<F: LanguageFamily, O: StitchOp>(strategy: SearchPriority, cost: usize, depth: usize, state: &SearchState<F, O>, shared: &SharedSearchData<F, O>, forced_lower_bound: i64) -> ((usize, usize), i64) {
    match strategy {
        SearchPriority::Cost => ((cost, 0), 0),
        SearchPriority::DepthFirst => ((usize::MAX - depth, 0), 0),
        SearchPriority::BreadthFirst => ((depth, 0), 0),
        SearchPriority::MostMatches => ((usize::MAX - state.matches.len(), 0), 0),
        SearchPriority::ForcedThenCost => match state.forced_expansion_argmin(shared, forced_lower_bound) {
            // clamp to 0 because anything <= 0 means no forced expansion
            Some((forced, _)) => ((forced.max(0) as usize, cost), forced),
            None => ((usize::MAX, cost), i64::MAX),
        },
    }
}

/// True iff every every e-node in the e-graph has the same cost as all
/// other e-nodes in its class.
fn cost_balanced<F: LanguageFamily, O: StitchOp>(egraph: &StitchEgraph<F::Apply<O>>) -> bool {
    let weights = egraph.analysis.weights;
    egraph.classes().all(|c| c.nodes.iter().all(|n| n.discriminant().intrinsic_size(&weights) + n.children().iter().map(|&ch| egraph[ch].data.size).sum::<u32>() == c.data.size))
}

/// One "new best" event recorded during search.
#[derive(Serialize, Deserialize, Clone)]
pub struct BestHistoryEntry {
    /// Expansion index (pop count) at which this best was discovered.
    pub expansion: usize,
    /// Wall-clock seconds since search start when this best was discovered.
    pub elapsed_secs: f64,
    pub cost: usize,
    pub pattern: String,
}

/// Output of a completed best-first enumerative search.
pub struct BestFirstResult<F: LanguageFamily, O: StitchOp> {
    /// `(cost, winning state + the cost selection the optimiser picked for it)`.
    /// Threading the selection out saves `multiple_step_search` from re-running
    /// `compute_cost_and_select` just to recover it.
    pub best: Option<(usize, SearchStateWithCostSelection<F, O>)>,
    pub original_size: usize,
    /// Expansion index (pop count) at which the current best was first discovered.
    pub best_found_at: Option<usize>,
    /// Every successive "new best" event, in discovery order.
    pub best_history: Vec<BestHistoryEntry>,
    /// Total number of heap pops performed before the loop stopped.
    pub num_expansions: usize,
    /// Heap size when the loop stopped. `0` means the frontier was exhausted
    /// (the search converged); a non-zero value means it hit the `num_steps` cap.
    pub heap_size_at_end: usize,
    pub data: crate::shared::SharedData<F, O>,
}

/// One node in the in-memory search tree.
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(bound(serialize = "F::Apply<OpWithVar<O>>: serde::Serialize", deserialize = "F::Apply<OpWithVar<O>>: serde::Deserialize<'de>"))]
struct Node<F: LanguageFamily, O: StitchOp> {
    state: SearchState<F, O>,
    depth: usize,
    /// Lower bound on cost of any descendant; only set when `--lower-bound` is on.
    /// Re-checked on pop in case `best` improved between push and pop.
    lower_bound: Option<usize>,
    /// This node's ForcedExpansion (0 unless ordering by `ForcedThenCost`). Used
    /// as the monotone lower bound that early-exits its children's forced scans.
    forced: i64,
}

/// Durable search state at the boundary between two complete node expansions.
#[derive(Serialize, Deserialize)]
#[serde(bound(serialize = "F::Apply<OpWithVar<O>>: Serialize, F::Discriminant<OpWithVar<O>>: Serialize", deserialize = "F::Apply<OpWithVar<O>>: Deserialize<'de>, F::Discriminant<OpWithVar<O>>: Deserialize<'de>"))]
pub struct BestFirstCheckpoint<F: LanguageFamily, O: StitchOp> {
    nodes: HashMap<usize, Node<F, O>>,
    created: usize,
    heap: BinaryHeap<Reverse<((usize, usize), usize)>>,
    seen: Option<SeenTracker<F, O>>,
    footprints: Option<FootprintTracker>,
    best: Option<(usize, SearchState<F, O>, CostSelection)>,
    best_found_at: Option<usize>,
    best_history: Vec<BestHistoryEntry>,
    num_expansions: usize,
    heap_pops: usize,
    arena_peak: usize,
    frontier_peak: usize,
    cost_calls: usize,
    cost_time: Duration,
    dominance_hits: usize,
    lower_bound_pruner: LowerBoundPruner,
    useless_frozen_hits: usize,
    useless_inline_hits: usize,
}

impl<F: LanguageFamily, O: StitchOp> BestFirstCheckpoint<F, O> {
    fn new(args: &crate::Args) -> Self {
        Self {
            nodes: HashMap::new(),
            created: 0,
            heap: BinaryHeap::new(),
            seen: args.opt_seen.then(SeenTracker::new),
            footprints: args.opt_dedup_by_match.then(FootprintTracker::new),
            best: None,
            best_found_at: None,
            best_history: Vec::new(),
            num_expansions: 0,
            heap_pops: 0,
            arena_peak: 0,
            frontier_peak: 0,
            cost_calls: 0,
            cost_time: Duration::ZERO,
            dominance_hits: 0,
            lower_bound_pruner: LowerBoundPruner::new(args.lower_bound.resolve(true)),
            useless_frozen_hits: 0,
            useless_inline_hits: 0,
        }
    }

    pub fn heap_pops(&self) -> usize {
        self.heap_pops
    }
    pub fn frontier_len(&self) -> usize {
        self.heap.len()
    }
    pub fn peaks(&self) -> (usize, usize) {
        (self.arena_peak, self.frontier_peak)
    }
}

/// Runs best-first enumerative search to find a pattern that minimizes cost.
///
/// Maintains a min-heap keyed by `(cost, insertion_order)`. Each pop enumerates
/// every deterministic successor of the node, deduplicates against the set of
/// previously-seen canonical patterns, applies `max_arity` and `follow` filters,
/// and pushes the survivors back onto the heap. Stops at `num_steps` pops, the
/// `time_limit`, or an empty heap (completion). If neither budget is set, runs
/// to completion. (No `dead_runs` cutoff: the search is systematic, so "no
/// recent improvement" just means we're grinding through a less promising branch.)
pub fn best_first<F: LanguageFamily, O: StitchOp>(data: crate::shared::SharedData<F, O>, args: &crate::Args) -> BestFirstResult<F, O> {
    best_first_with_progress(data, args, |_, _, _| {})
}

/// Observe heap pops, retained states and queued states without changing search order.
pub fn best_first_with_progress<F: LanguageFamily, O: StitchOp>(data: crate::shared::SharedData<F, O>, args: &crate::Args, observe: impl FnMut(usize, usize, usize)) -> BestFirstResult<F, O> {
    best_first_resumable(data, args, None, observe, |_| false)
}

/// The save callback is invoked before the next pop, after all children of the
/// previous node have been committed. Returning true suspends the same search.
pub fn best_first_resumable<F: LanguageFamily, O: StitchOp>(
    data: crate::shared::SharedData<F, O>,
    args: &crate::Args,
    resumed: Option<BestFirstCheckpoint<F, O>>,
    mut observe: impl FnMut(usize, usize, usize),
    mut save_and_pause: impl FnMut(&BestFirstCheckpoint<F, O>) -> bool,
) -> BestFirstResult<F, O> {
    let (shared, cost_cache, original_size) = setup_search(data, args);
    println!("{} {}", "original size of egraph:".dimmed(), original_size.to_string().bold());

    let budget = args.num_steps;
    let time_limit = args.time_limit.map(std::time::Duration::from_secs_f64);
    let max_arity = args.max_arity;
    let no_zero_arity = args.no_zero_arity;
    // ForcedThenCost reduces to Cost when the e-graph is cost-balanced
    let strategy = if matches!(args.priority, SearchPriority::ForcedThenCost) && cost_balanced::<F, O>(&shared.egraph) {
        println!("{}", "rules are cost-balanced: ordering by cost (forced-expansion ordering not needed)".dimmed());
        SearchPriority::Cost
    } else {
        args.priority
    };
    let mut scratch = CostScratch::new(&shared.egraph);

    let initialize = resumed.is_none();
    let mut run = resumed.unwrap_or_else(|| BestFirstCheckpoint::new(args));
    if initialize {
        for initial_state in SearchState::seeds(&shared, args.freeze_rule.resolve(true)) {
            let initial_cost = compute_cost_and_select(&shared.egraph, shared.root, &cost_cache, &mut scratch, &initial_state, shared.check_slow).cost;
            let (initial_prio, initial_forced) = priority(strategy, initial_cost, 0, &initial_state, &shared, i64::MIN);
            let id = run.created;
            run.created += 1;
            run.heap.push(Reverse((initial_prio, id)));
            if let Some(s) = run.seen.as_mut() {
                s.check_typed(&initial_state.pattern, initial_state.pattern.frozen_mask(), initial_state.sorts(&shared.egraph));
            }
            if let Some(fp) = run.footprints.as_mut() {
                fp.check_state(&initial_state, &shared, id, &|i| &run.nodes[&i].state.matches[..]);
            }
            run.nodes.insert(
                id,
                Node {
                    state: initial_state,
                    depth: 0,
                    lower_bound: None,
                    forced: initial_forced,
                },
            );
        }
    }
    // The typed bridge accepts only strict improvements over this round's baseline.
    // Its cost bound is useful before a first winner exists, including the final round.
    let initial_bound = if shared.egraph.analysis.typed.is_some() && shared.follow.is_none() { original_size } else { usize::MAX };
    // Set when a new best reaches the `--compression-limit` cumulative target;
    // the search breaks after the child node is pushed (so `best`'s node id is valid).
    let mut hit_compression_limit = false;
    let search_start = Instant::now();

    'search: loop {
        if !run.heap.is_empty() && save_and_pause(&run) {
            break;
        }
        if let Some(typed) = &shared.egraph.analysis.typed {
            typed.check();
            if typed.max_live_states.is_some_and(|limit| run.nodes.len() >= limit) && !run.heap.is_empty() {
                std::panic::panic_any(crate::lang::SearchBudgetStop("state_limit"));
            }
        }
        // Check cutoffs before popping so a node isn't discarded from the frontier.
        if let Some(b) = budget
            && run.num_expansions >= b
        {
            println!("{}", format!("reached expansion budget {}", b).yellow());
            break;
        }
        if let Some(limit) = time_limit
            && search_start.elapsed() >= limit
        {
            println!("{}", format!("reached time limit {:.3}s", limit.as_secs_f64()).yellow());
            break;
        }
        let Some(Reverse((_prio, node_id))) = run.heap.pop() else {
            break;
        };
        run.heap_pops = run.heap_pops.checked_add(1).expect("heap pop count overflow");
        run.arena_peak = run.arena_peak.max(run.nodes.len());
        run.frontier_peak = run.frontier_peak.max(run.heap.len() + 1);
        observe(run.heap_pops, run.nodes.len(), run.heap.len() + 1);

        let popped;
        let parent = if run.footprints.is_some() {
            &run.nodes[&node_id]
        } else {
            popped = run.nodes.remove(&node_id).expect("queued node is live");
            &popped
        };
        // Re-check the cached lower bound: best may have improved since this node was pushed.
        if let Some(lb) = parent.lower_bound
            && run.lower_bound_pruner.recheck_cached(lb, run.best.as_ref().map_or(initial_bound, |(c, _, _)| *c))
        {
            continue;
        }

        if args.verbose || args.verbose_forced_expansion || args.verbose_match_structure {
            let tag = format!("[expansion {}]", run.num_expansions);
            let pat = parent.state.pattern.to_string();
            if args.verbose {
                println!("{} {} {}", tag.dimmed(), "expanding:".dimmed(), pat.clone().cyan());
            }
            if args.verbose_match_structure {
                crate::logging::print_match_structure(&parent.state.matches, 10);
            }
            if args.verbose_forced_expansion {
                let forced_str = match parent.state.forced_expansion_argmin(&shared, i64::MIN) {
                    Some((e, root)) => format!("[forced-expansion={} @root={}]", e, parent.state.min_term(&shared, root)),
                    None => "[forced-expansion=- (no in-extraction root)]".to_string(),
                };
                println!("{} {} {}", tag.dimmed(), pat.cyan(), forced_str.yellow());
            }
        }

        let parent_depth = parent.depth;
        // The parent's forced-expansion is a monotone lower bound on each child's,
        // so it early-exits the children's forced scans (the hot path on DSRs).
        let parent_forced = parent.forced;
        let mut successors: Vec<SearchState<F, O>> = match parent.state.enumerate_successor_actions(&shared, args.opt_dominance_reuse, args.opt_useless_inline, max_arity, &mut run.dominance_hits, &mut run.useless_inline_hits) {
            SuccessorEnum::Dominant { child, .. } => vec![child],
            SuccessorEnum::All { actions, rank } => {
                if let Some(typed) = &shared.egraph.analysis.typed
                    && typed.max_live_states.is_some_and(|limit| run.nodes.len().saturating_add(actions.len()) > limit)
                {
                    std::panic::panic_any(crate::lang::SearchBudgetStop("state_limit"));
                }
                actions.into_iter().map(|(a, _)| parent.state.apply_action(&a, &shared, true, Some(&rank))).collect()
            }
        };

        if let Some(k) = args.max_forced_expansion.0 {
            // Safe to run on the post-dominance successor set: dominance
            // short-circuits preserve forced expansion. dominant-reuse: doesn't
            // change anything about the matching term at each site. useless-inline:
            // replaces a variable with its minimal term, so preserves cost. Both
            // don't change the set of matches.
            //
            // The cap is given in symbols; scale to the family's cost units.
            let cap = k as i64 * F::symbol_cost(&shared.egraph.analysis.weights) as i64;
            successors.retain(|c| c.within_forced_expansion_cap(&shared, cap));
        }

        successors.retain(|c| c.within_match_set_cap(args.max_match_set));

        for child_state in successors {
            if let Some(ref follow) = shared.follow
                && !child_state.matches_follow(follow)
            {
                continue;
            }
            if let Some(s) = run.seen.as_mut()
                && s.check_typed(&child_state.pattern, child_state.pattern.frozen_mask(), child_state.sorts(&shared.egraph))
            {
                continue;
            }

            // Useless-frozen pruning: a frozen metavar bound to the same
            // (closed-under-pattern-binders) arg in every match adds no
            // compression. Stitch analog: argument-capture pruning.
            if args.opt_useless_frozen && child_state.is_useless_frozen(&shared) {
                run.useless_frozen_hits += 1;
                continue;
            }

            // Optimistic lower bound on this child's descendants — every match
            // collapses to one node. Skip the full cost call (and the descent)
            // when the bound already exceeds the current best.
            let cost_to_beat = run.best.as_ref().map_or(initial_bound, |(c, _, _)| *c);
            let child_lower_bound = match run.lower_bound_pruner.try_prune(&shared.egraph, shared.root, &cost_cache, &mut scratch, &child_state, cost_to_beat) {
                PruneResult::Pruned => continue,
                PruneResult::Keep(lb) => Some(lb),
                PruneResult::Disabled => None,
            };

            // Placed last as it is very expensive. `created` is the next insertion ID
            // (it is pushed unconditionally below if it survives),
            // letting a deferred representative re-read its match set on a collision.
            if let Some(fp) = run.footprints.as_mut()
                && fp.check_state(&child_state, &shared, run.created, &|i| &run.nodes[&i].state.matches[..])
            {
                continue;
            }

            let cost_t = Instant::now();
            // Capture the selection here so updates to `best` can stash it
            // without re-running the optimisation in `multiple_step_search`.
            // Cost-equal to the old `compute_cost` call — same underlying work.
            let child_selection = compute_cost_and_select(&shared.egraph, shared.root, &cost_cache, &mut scratch, &child_state, shared.check_slow);
            let child_cost = child_selection.cost;
            run.cost_time += cost_t.elapsed();
            run.cost_calls += 1;
            let child_depth = parent_depth + 1;
            let (child_prio, child_forced) = priority(strategy, child_cost, child_depth, &child_state, &shared, parent_forced);
            let child_id = run.created;
            run.created += 1;

            let cost_to_beat = run.best.as_ref().map_or(original_size, |(c, _, _)| *c);
            let arity = child_state.pattern.vars.len();
            // KNOWN DIVERGENCE FROM SMC: this update is *not* guarded by
            // `shared.follow.is_none()`, unlike its counterpart at smc.rs:135. In
            // `--follow` mode best-first therefore records the cheapest matching
            // *prefix* as `best`, whereas SMC records only an exact follow match
            // (and returns `None` if the budget runs out first). The non-prefix
            // children are already filtered out above (see :199), so `best` is
            // always a valid follow-prefix; the two backends just disagree on
            // what they report when no exact hit is reached within budget. This
            // is intentionally left as-is: follow mode is a reachability check
            // and none of the follow tests depend on which backend's
            // budget-exhaustion behaviour is used.
            if arity <= max_arity && !(no_zero_arity && arity == 0) && child_cost < cost_to_beat && (args.allow_useless_vars || !child_state.has_useless_var(&shared)) {
                let elapsed = search_start.elapsed().as_secs_f64();
                println!(
                    "{} {} {} {}",
                    format!("[expansion {}]", run.num_expansions).yellow().bold(),
                    format!("new best: {}", child_cost).green().bold(),
                    child_state.pattern.to_string().cyan(),
                    format!("(t={:.3}s)", elapsed).dimmed()
                );
                run.best = Some((child_cost, child_state.clone(), child_selection.clone()));
                run.best_found_at = Some(run.num_expansions);
                run.best_history.push(BestHistoryEntry {
                    expansion: run.num_expansions,
                    elapsed_secs: elapsed,
                    cost: child_cost,
                    pattern: child_state.pattern.to_string(),
                });
                // `--compression-limit` early stop: this best already reaches the
                // target ratio, so no better one is needed. Queue this child
                // before exiting to preserve the frontier accounting.
                if args.compression_limit.is_some_and(|limit| original_size as f64 / child_cost as f64 >= limit) {
                    hit_compression_limit = true;
                }
            }

            // Mirrors SMC's `follow exact match` exit (src/smc.rs:132): once
            // a successor is alpha-equivalent to the follow target the search
            // has reached the goal, and continuing risks overwriting `best`
            // with a cheaper non-matching pattern that slipped past the prefix
            // filter. Record this child as best and stop.
            //
            // NOTE: --follow mode is a reachability check — we only care that
            // the target pattern is constructible via the expansions BFS/SMC
            // has access to. Overwriting `best` with the follow-hit child even
            // when its cost is worse than a previously-recorded best is
            // intentional: the reported `best` in follow mode is "the follow
            // target we reached", not "the cheapest pattern seen". Do not
            // "fix" this by guarding the overwrite on `child_cost < best.cost`.
            let exact_follow_hit = shared.follow.as_ref().is_some_and(|f| crate::follow::matches_follow_serialized(&child_state, f, &shared.egraph));

            run.nodes.insert(
                child_id,
                Node {
                    state: child_state,
                    depth: child_depth,
                    lower_bound: child_lower_bound,
                    forced: child_forced,
                },
            );
            run.heap.push(Reverse((child_prio, child_id)));

            if exact_follow_hit {
                let elapsed = search_start.elapsed().as_secs_f64();
                println!(
                    "{} {} {} {}",
                    format!("[expansion {}]", run.num_expansions).yellow().bold(),
                    format!("follow exact match: {}", child_cost).green().bold(),
                    run.nodes[&child_id].state.pattern.to_string().cyan(),
                    format!("(t={:.3}s)", elapsed).dimmed()
                );
                run.best = Some((child_cost, run.nodes[&child_id].state.clone(), child_selection));
                run.best_found_at = Some(run.num_expansions);
                run.num_expansions += 1;
                break 'search;
            }

            if hit_compression_limit {
                println!("{}", format!("reached compression limit {:.3}", args.compression_limit.unwrap_or(0.0)).yellow());
                run.num_expansions += 1;
                break 'search;
            }
        }

        run.num_expansions += 1;
    }

    let total_elapsed = search_start.elapsed();
    println!("\n{}", "═══ STATS ═══".blue().bold());
    println!("{} {}", "expansions:".dimmed(), run.num_expansions.to_string().bold());
    println!("{} {}", "nodes created:".dimmed(), run.created.to_string().bold());
    println!("{} {}", "heap size at end:".dimmed(), run.heap.len().to_string().bold());
    let (seen_len, seen_hits, seen_secs) = run.seen.as_ref().map_or((0, 0, 0.0), |s| (s.len(), s.hits, s.time.as_secs_f64()));
    println!("{} {}", "seen-set size:".dimmed(), seen_len.to_string().bold());
    println!("{} {} {}", "seen-set hits:".dimmed(), seen_hits.to_string().bold(), format!("(time: {:.3}s)", seen_secs).dimmed());
    let (fp_len, fp_hits, fp_skips, fp_capped, fp_secs) = run.footprints.as_ref().map_or((0, 0, 0, 0, 0.0), |f| (f.len(), f.hits, f.proxy_skips, f.capped, f.time.as_secs_f64()));
    println!("{} {}", "footprint-set size:".dimmed(), fp_len.to_string().bold());
    println!("{} {} {}", "footprint-set hits:".dimmed(), fp_hits.to_string().bold(), format!("(proxy-skips: {}, capped: {}, time: {:.3}s)", fp_skips, fp_capped, fp_secs).dimmed());
    println!("{} {}", "dominance hits:".dimmed(), run.dominance_hits.to_string().bold());
    run.lower_bound_pruner.print_stats();
    println!("{} {}", "useless-frozen hits:".dimmed(), run.useless_frozen_hits.to_string().bold());
    println!("{} {}", "useless-inline hits:".dimmed(), run.useless_inline_hits.to_string().bold());
    println!("{} {} {}", "compute_cost calls:".dimmed(), run.cost_calls.to_string().bold(), format!("(time: {:.3}s)", run.cost_time.as_secs_f64()).dimmed());
    println!("{} {}", "total search time:".dimmed(), format!("{:.3}s", total_elapsed.as_secs_f64()).bold());

    // Canonicalize the winner's var numbering (DFS first-appearance) before it's
    // handed off for output/rewrite.
    let best_pair = run.best.map(|(cost, state, selection)| {
        let mut pair = SearchStateWithCostSelection { state, selection };
        pair.canonicalize();
        (cost, pair)
    });

    println!("\n{}", "═══ RESULT ═══".green().bold());
    if let (Some(iter), Some((cost, pair))) = (run.best_found_at, best_pair.as_ref()) {
        println!("{} {}", "best found at expansion:".dimmed(), iter.to_string().yellow());
        println!("{} {}", "pattern:".dimmed(), pair.state.pattern.to_string().cyan().bold());
        println!("{} {}", "cost:".dimmed(), cost.to_string().green().bold());
        println!("{} {}", "compression ratio:".dimmed(), format!("{:.2}x", original_size as f64 / *cost as f64).green().bold());
    }

    BestFirstResult {
        best: best_pair,
        original_size,
        best_history: run.best_history,
        best_found_at: run.best_found_at,
        num_expansions: run.num_expansions,
        heap_size_at_end: run.heap.len(),
        data: shared.into_data(),
    }
}
