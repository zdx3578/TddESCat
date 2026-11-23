mod codec;
mod engine;
mod proof;
mod protocol;

use anyhow::{Context, Result, ensure};
use clap::Parser;
use codec::{Definition, Registry, Term};
use egg_stitch::lang::SearchBudgetStop;
use protocol::{CODEC, Config, Manifest, Origin, PROTOCOL, commit};
use serde::Serialize;
use std::{
    collections::BTreeSet,
    fs,
    io::{self, Write},
    panic::{AssertUnwindSafe, catch_unwind},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

#[derive(Parser)]
struct Arguments {
    #[arg(long)]
    manifest: PathBuf,
    #[arg(long)]
    output: PathBuf,
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
    match_support_exact: bool,
    apply_complete: bool,
    round_committed: bool,
    stop_reason: &'static str,
}

struct BoundedOutput {
    data: Vec<u8>,
    limit: usize,
}

impl Write for BoundedOutput {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if self.data.len().saturating_add(buf.len()) > self.limit {
            std::panic::panic_any(SearchBudgetStop("output_budget"));
        }
        self.data.extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

struct Job {
    manifest: Manifest,
    input_sha: String,
    config: Config,
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
            !text.is_empty() && text.len() == manifest.program_count && text.len() <= 2048,
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
            registry,
            original,
            origins,
            library,
            order,
            old_cost,
        })
    }

    fn run(mut self, output: &Path, start: Instant, committed: &mut usize) -> Result<()> {
        let deadline = start + Duration::from_millis(self.config.budget.wall_ms);
        let mut steps_left = self.config.max_steps;
        let pre = engine::corpus_cost(&self.original);
        let input_load = pre.saturating_mul(256);
        if input_load > self.config.budget.managed_bytes as u64 {
            std::panic::panic_any(SearchBudgetStop("managed_bytes"));
        }
        let mut programs = self.original.clone();
        let mut parent = None;
        let mut new_cost = 0u64;
        let mut definitions = Vec::new();
        for round_index in 1..=self.config.rounds {
            let result = engine::search(
                &self.config,
                self.registry.clone(),
                &programs,
                &self.library,
                &self.order,
                deadline,
                steps_left,
                round_index,
            )?;
            steps_left = steps_left
                .checked_sub(result.expansions)
                .context("invalid expansion counter")?;
            if !result.exhausted && result.found.is_none() && result.programs == programs {
                std::panic::panic_any(SearchBudgetStop("step_budget"));
            }
            let stop_reason = if !result.exhausted {
                "step_budget"
            } else if result.found.is_none() {
                "exhausted"
            } else {
                "requested_rounds"
            };
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
            let (proofs, calls) = proof::verify(
                &self.original,
                &programs,
                &self.origins,
                &self.library,
                self.config.budget.max_relation_nodes,
                deadline,
            )?;
            let corpus = engine::corpus_cost(&programs);
            let total = corpus
                .checked_add(self.old_cost)
                .and_then(|n| n.checked_add(new_cost))
                .context("total cost overflow")?;
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
                parent_checkpoint_sha256: parent.as_deref(),
                search_exhausted: result.exhausted,
                match_support_exact: true,
                apply_complete: true,
                round_committed: true,
                stop_reason,
            };
            let mut bytes = BoundedOutput {
                data: Vec::new(),
                limit: self.config.budget.max_output_bytes,
            };
            serde_json::to_writer(&mut bytes, &data)?;
            if Instant::now() >= deadline {
                std::panic::panic_any(SearchBudgetStop("deadline"));
            }
            parent = Some(commit(
                output,
                round_index,
                &self.input_sha,
                parent.as_deref(),
                &bytes.data,
                result.expansions,
            )?);
            *committed = round_index;
            if !result.exhausted {
                std::panic::panic_any(SearchBudgetStop("step_budget"));
            }
            if stop_reason == "exhausted" {
                break;
            }
        }
        Ok(())
    }
}

fn main() {
    let args = Arguments::parse();
    let start = Instant::now();
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |panic| {
        if !panic.payload().is::<SearchBudgetStop>() {
            default_hook(panic);
        }
    }));
    let mut committed = 0;
    let code = match Job::load(&args) {
        Err(err) => {
            eprintln!("invalid_input: {err:#}");
            20
        }
        Ok(job) => match catch_unwind(AssertUnwindSafe(|| {
            job.run(&args.output, start, &mut committed)
        })) {
            Ok(Ok(())) => 0,
            Ok(Err(err)) => {
                eprintln!("invariant_violation: {err:#}");
                21
            }
            Err(payload) => match payload.downcast::<SearchBudgetStop>() {
                Ok(reason) => {
                    eprintln!("{}: {committed} committed rounds", reason.0);
                    if committed == 0 { 22 } else { 10 }
                }
                Err(_) => 21,
            },
        },
    };
    std::process::exit(code);
}
