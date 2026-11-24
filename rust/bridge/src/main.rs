mod codec;
mod engine;
mod proof;
mod protocol;
mod resources;

use anyhow::{Context, Result, ensure};
use clap::{Parser, ValueEnum};
use codec::{Definition, Registry, Term};
use egg_stitch::lang::SearchBudgetStop;
use protocol::{CODEC, Config, Manifest, Origin, PROTOCOL, atomic_json, commit};
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    collections::BTreeSet,
    fs,
    panic::{AssertUnwindSafe, catch_unwind},
    path::PathBuf,
};

#[derive(Parser)]
struct Arguments {
    #[arg(long)]
    manifest: PathBuf,
    #[arg(long)]
    output: PathBuf,
    #[arg(long, hide = true, value_enum)]
    test_fault: Option<Fault>,
}

#[derive(Clone, Copy, PartialEq, Eq, ValueEnum)]
enum Fault {
    BeforeFirstCommit,
    AfterFirstCommit,
    DuringFirstWrite,
    ResourceLoad,
}

fn test_interrupt(phase: resources::Phase, reason: &'static str) -> ! {
    let _span = resources::phase(phase);
    std::panic::panic_any(SearchBudgetStop(reason));
}

#[derive(Serialize)]
struct Cost {
    pre_rewrite_input: String,
    post_rewrite_baseline: String,
    output_programs: String,
    initial_library: String,
    new_definitions: String,
    final_total: String,
    ratio_numerator: String,
    ratio_denominator: String,
}

#[derive(Serialize)]
struct LearningResult<'a> {
    protocol_version: &'static str,
    codec_version: &'static str,
    job_id: &'a str,
    round_index: usize,
    definitions: &'a [Definition],
    rewritten_programs: Vec<String>,
    calls: Vec<proof::CallSite>,
    proofs: Vec<proof::Proof>,
    cost: Cost,
    input_sha256: &'a str,
    parent_checkpoint_sha256: Option<&'a str>,
    search_exhausted: bool,
    saturation_complete: bool,
    input_scope_complete: bool,
    match_support_exact: bool,
    apply_complete: bool,
    round_committed: bool,
    round_outcome: &'static str,
    round_metrics: RoundMetrics,
}

#[derive(Serialize)]
struct RoundMetrics {
    heap_pops: usize,
    arena_peak: usize,
    frontier_peak: usize,
    egraph_nodes: usize,
    egraph_classes: usize,
    proof_visits: usize,
}

#[derive(Default)]
struct JobProgress {
    searches: usize,
    committed: usize,
    accepted: usize,
    heap_pops: usize,
    last_checkpoint: Option<String>,
    input_sha: Option<String>,
    scope: Value,
    policy: Value,
}

struct Job {
    manifest: Manifest,
    input_sha: String,
    config: Config,
    search_args: egg_stitch::Args,
    registry: Registry,
    original: Vec<Term>,
    origins: Vec<protocol::OriginSites>,
    library: engine::Library,
    order: Vec<String>,
    old_cost: u64,
}

impl Job {
    fn load(args: &Arguments) -> Result<Self> {
        let parent = args
            .manifest
            .parent()
            .context("manifest needs an input directory")?;
        let root = parent.canonicalize()?;
        let (manifest, input_sha) = Manifest::load(&args.manifest)?;
        let config = Config::load(&manifest.config_file.read(&root)?)?;
        let search_args = engine::search_args(&config)?;
        resources::check();
        let mut registry =
            Registry::new(manifest.signature_file.json(&root)?, &manifest.slot_context)?;
        let rules: Vec<serde_json::Value> = manifest.rules_file.json(&root)?;
        ensure!(
            rules.is_empty(),
            "only registered definitional equalities are supported"
        );
        let (library, order, old_cost) =
            engine::import(&mut registry, manifest.initial_library_file.json(&root)?)?;
        let text: Vec<String> = manifest.programs_file.json(&root)?;
        ensure!(
            text.len() == manifest.program_count,
            "invalid program count"
        );
        let original = text
            .iter()
            .map(|s| codec::program(s, &registry))
            .collect::<Result<Vec<_>>>()?;
        let paths = original
            .iter()
            .map(|term| {
                let mut paths = BTreeSet::new();
                term.walk(&mut Vec::new(), &mut |path, _| {
                    paths.insert(path.clone());
                });
                paths
            })
            .collect::<Vec<_>>();
        let origins = Origin::index(manifest.origins_file.json(&root)?, &paths)?;
        ensure!(
            fs::read_dir(&args.output)?.next().is_none(),
            "output directory must be empty"
        );
        Ok(Self {
            manifest,
            input_sha,
            config,
            search_args,
            registry,
            original,
            origins,
            library,
            order,
            old_cost,
        })
    }

    fn run(mut self, args: &Arguments, progress: &mut JobProgress) -> Result<&'static str> {
        progress.input_sha = Some(self.input_sha.clone());
        progress.scope = self.manifest.scope_refs();
        progress.policy = serde_json::to_value(&self.config)?;
        if self.original.is_empty() {
            return Ok("no_eligible_corpus");
        }
        let pre = engine::corpus_cost(&self.original);
        resources::check();
        let mut programs = self.original.clone();
        let mut new_cost = 0u64;
        let mut definitions = Vec::new();
        let mut previous_cost = pre
            .checked_add(self.old_cost)
            .context("initial cost overflow")?;
        loop {
            resources::check();
            let round_index = progress
                .searches
                .checked_add(1)
                .context("round count overflow")?;
            progress.searches = round_index;
            let result = engine::search(
                &self.config,
                &self.search_args,
                self.registry.clone(),
                &programs,
                &self.library,
                &self.order,
                round_index,
            )?;
            progress.heap_pops = progress
                .heap_pops
                .checked_add(result.heap_pops)
                .context("pop count overflow")?;
            if !result.exhausted {
                return Ok("search_incomplete");
            }
            let accepted = result.found.is_some();
            if let Some((name, def)) = result.found {
                self.registry
                    .register(&name, &def.parameter_sorts, &def.result_sort)?;
                self.order.push(name.clone());
                self.library.insert(name, def.clone());
                new_cost = new_cost
                    .checked_add(def.body.cost())
                    .context("definition cost overflow")?;
                definitions.push(def);
            }
            programs = result.programs;
            let span = resources::phase(resources::Phase::Proof);
            let (proofs, calls, proof_visits) =
                proof::verify(&self.original, &programs, &self.origins, &self.library)?;
            drop(span);
            resources::check();
            let corpus = engine::corpus_cost(&programs);
            let total = corpus
                .checked_add(self.old_cost)
                .and_then(|n| n.checked_add(new_cost))
                .context("total cost overflow")?;
            ensure!(
                total < previous_cost || (!accepted && total == previous_cost),
                "round did not improve the full structural cost"
            );
            let ratio = pre
                .checked_add(self.old_cost)
                .context("input cost overflow")?;
            let cost = Cost {
                pre_rewrite_input: pre.to_string(),
                post_rewrite_baseline: result.baseline_cost.to_string(),
                output_programs: corpus.to_string(),
                initial_library: self.old_cost.to_string(),
                new_definitions: new_cost.to_string(),
                final_total: total.to_string(),
                ratio_numerator: ratio.to_string(),
                ratio_denominator: total.to_string(),
            };
            let data = LearningResult {
                protocol_version: PROTOCOL,
                codec_version: CODEC,
                job_id: &self.manifest.job_id,
                round_index,
                definitions: &definitions,
                rewritten_programs: programs.iter().map(|t| t.show("?#")).collect(),
                calls,
                proofs,
                cost,
                input_sha256: &self.input_sha,
                parent_checkpoint_sha256: progress.last_checkpoint.as_deref(),
                search_exhausted: result.exhausted,
                saturation_complete: true,
                input_scope_complete: self.manifest.input_scope_complete,
                match_support_exact: true,
                apply_complete: true,
                round_committed: true,
                round_outcome: if accepted {
                    "definition_accepted"
                } else {
                    "no_positive_gain"
                },
                round_metrics: RoundMetrics {
                    heap_pops: result.heap_pops,
                    arena_peak: result.arena_peak,
                    frontier_peak: result.frontier_peak,
                    egraph_nodes: result.egraph_nodes,
                    egraph_classes: result.egraph_classes,
                    proof_visits,
                },
            };
            if round_index == 1 && args.test_fault == Some(Fault::BeforeFirstCommit) {
                test_interrupt(resources::Phase::Commit, "cancelled");
            }
            resources::check();
            let checkpoint = commit(
                &args.output,
                round_index,
                &self.input_sha,
                progress.last_checkpoint.as_deref(),
                &data,
                result.expansions,
                || {
                    if round_index == 1 && args.test_fault == Some(Fault::DuringFirstWrite) {
                        test_interrupt(resources::Phase::Serialize, "cancelled");
                    }
                    resources::check();
                },
            )?;
            progress.last_checkpoint = Some(checkpoint);
            progress.committed = round_index;
            progress.accepted = definitions.len();
            previous_cost = total;
            if accepted
                && self
                    .config
                    .progress
                    .accepted_definition_checkpoints
                    .binary_search(&progress.accepted)
                    .is_ok()
            {
                atomic_json(
                    &args.output,
                    &format!("accepted-{:06}.json", progress.accepted),
                    &json!({
                        "accepted_definitions": progress.accepted, "round_index": round_index,
                        "checkpoint_sha256": progress.last_checkpoint, "final_total": total.to_string(),
                    }),
                )?;
            }
            if round_index == 1 && args.test_fault == Some(Fault::AfterFirstCommit) {
                test_interrupt(resources::Phase::Commit, "cancelled");
            }
            resources::check();
            if !accepted {
                return Ok(if self.manifest.input_scope_complete {
                    "verified_compression_fixed_point"
                } else {
                    "input_scope_incomplete"
                });
            }
        }
    }
}

fn main() {
    if std::env::args().skip(1).eq(["--identity".to_owned()]) {
        let identity = serde_json::json!({
            "build_sha256": protocol::BUILD_SHA,
            "binary_sha256": protocol::running_binary_sha().expect("worker binary"),
        });
        println!("{identity}");
        return;
    }
    let args = Arguments::parse();
    resources::install_cancel_handler();
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |panic| {
        if !panic.payload().is::<SearchBudgetStop>() {
            default_hook(panic);
        }
    }));
    let mut progress = JobProgress::default();
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<(&'static str, i32)> {
        let span = resources::phase(resources::Phase::Load);
        if args.test_fault == Some(Fault::ResourceLoad) {
            test_interrupt(resources::Phase::Load, "resource_failure");
        }
        let job = match Job::load(&args) {
            Ok(job) => job,
            Err(error) => {
                eprintln!("invalid_input: {error:#}");
                return Ok(("invalid_input", 20));
            }
        };
        drop(span);
        let reason = job.run(&args, &mut progress)?;
        let code = match reason {
            "verified_compression_fixed_point" | "no_eligible_corpus" => 0,
            _ if progress.committed > 0 => 10,
            _ => 22,
        };
        Ok((reason, code))
    }));
    let (reason, code) = match result {
        Ok(Ok(outcome)) => outcome,
        Ok(Err(error)) => {
            eprintln!("invariant_violation: {error:#}");
            ("validation_failed", 21)
        }
        Err(payload) => match payload.downcast::<SearchBudgetStop>() {
            Ok(stop) => {
                eprintln!("{}: {} committed rounds", stop.0, progress.committed);
                (stop.0, if progress.committed == 0 { 22 } else { 10 })
            }
            Err(_) => ("validation_failed", 21),
        },
    };
    let profile = resources::report(code, Some(reason), progress.committed);
    if args.output.is_dir() {
        let summary = json!({
            "protocol_version": PROTOCOL, "input_sha256": progress.input_sha,
            "termination_reason": reason, "search_rounds": progress.searches,
            "accepted_definitions": progress.accepted, "total_heap_pops": progress.heap_pops,
            "last_checkpoint": progress.last_checkpoint.map(|sha| json!({
                "round_index": progress.committed, "sha256": sha
            })),
            "fixed_point": reason == "verified_compression_fixed_point",
            "scope_refs": progress.scope, "effective_policy": progress.policy,
            "effective_limits": {
                "search_steps": null, "wall_ms": null, "max_relation_nodes": null,
                "max_egraph_nodes": null, "max_arena_states": null, "proof_visits": null,
                "managed_bytes": null, "output_bytes": null, "rounds": null, "library_size": null
            },
            "interrupted_phase": if code == 0 || reason == "input_scope_incomplete" { None }
                else { Some(resources::last_phase()) },
        });
        if let Err(error) = atomic_json(&args.output, "metrics.json", &profile)
            .and_then(|_| atomic_json(&args.output, "learning-summary.json", &summary))
        {
            eprintln!("Unable to save learning summary: {error}");
            std::process::exit(21);
        }
    }
    std::process::exit(code);
}
