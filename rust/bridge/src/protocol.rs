use crate::codec::{Registry, Term};
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File},
    io::{self, BufWriter, Read, Write},
    path::{Component, Path},
};

pub const PROTOCOL: &str = "tddescat.learn.v3";
pub const BUILD_SHA: &str = env!("TDDESC_BUILD_SHA256");
pub const CODEC: &str = "typed-free-slots.v1";

pub fn digest(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}

pub fn running_binary_sha() -> Result<String> {
    let mut input = File::open(std::env::current_exe()?)?;
    let mut digest = Sha256::new();
    let mut buf = [0u8; 65_536];
    loop {
        let len = input.read(&mut buf)?;
        if len == 0 {
            break;
        }
        digest.update(&buf[..len]);
    }
    Ok(format!("{:x}", digest.finalize()))
}

pub fn identifier(value: &str) -> bool {
    value.len() <= 256
        && value
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphanumeric)
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"_.-".contains(&c))
}

pub fn operator(value: &str) -> bool {
    identifier(value)
        && value != "programs"
        && value != "lam"
        && !value.starts_with("fn_")
        && !value.starts_with("lib_")
}

fn read_exact_file(path: &Path, expected: Option<usize>) -> Result<Vec<u8>> {
    let mut file = File::open(path)?;
    let attrs = file.metadata()?;
    ensure!(attrs.is_file(), "input is not a file: {path:?}");
    let size = usize::try_from(attrs.len())?;
    ensure!(
        expected.is_none_or(|n| n == size),
        "input length differs: {path:?}"
    );
    let mut bytes = Vec::new();
    bytes.try_reserve_exact(size)?;
    (&mut file).take(attrs.len()).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() == size && file.read(&mut [0])? == 0,
        "file changed size: {path:?}"
    );
    Ok(bytes)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileRef {
    path: String,
    sha256: String,
    bytes: usize,
}

impl FileRef {
    pub fn read(&self, root: &Path) -> Result<Vec<u8>> {
        let relative = Path::new(&self.path);
        ensure!(
            !relative.is_absolute()
                && relative
                    .components()
                    .all(|c| matches!(c, Component::Normal(_)))
                && self
                    .path
                    .split('/')
                    .all(|part| !matches!(part, "" | "." | "..")),
            "unsafe input path: {}",
            self.path
        );
        let absolute = root.join(relative).canonicalize()?;
        ensure!(
            absolute.starts_with(root),
            "input path escapes frozen work directory"
        );
        let bytes = read_exact_file(&absolute, Some(self.bytes))?;
        ensure!(
            bytes.len() == self.bytes && digest(&bytes) == self.sha256,
            "input content mismatch: {}",
            self.path
        );
        Ok(bytes)
    }

    pub fn json<T: DeserializeOwned>(&self, root: &Path) -> Result<T> {
        serde_json::from_slice(&self.read(root)?).with_context(|| self.path.clone())
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub protocol_version: String,
    pub codec_version: String,
    pub job_id: String,
    pub evidence_snapshot_id: String,
    pub library_base_version: String,
    pub signature_file: FileRef,
    pub programs_file: FileRef,
    pub origins_file: FileRef,
    pub semantic_context_file: FileRef,
    pub initial_library_file: FileRef,
    pub rules_file: FileRef,
    pub config_file: FileRef,
    pub program_count: usize,
    pub input_scope_complete: bool,
    pub slot_context: Vec<SlotSpec>,
    pub engine_pin: EnginePin,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EnginePin {
    upstream_commit: String,
    source_git_tree: String,
    cargo_lock_sha256: String,
    rust_version: String,
    protocol_version: String,
    build_sha256: String,
    binary_sha256: String,
}

impl Manifest {
    pub fn scope_refs(&self) -> serde_json::Value {
        serde_json::json!({
            "signature": self.signature_file.sha256,
            "programs": self.programs_file.sha256,
            "origins": self.origins_file.sha256,
            "semantic_context": self.semantic_context_file.sha256,
            "base_library": self.initial_library_file.sha256,
            "equations": self.rules_file.sha256,
            "policy": self.config_file.sha256,
            "binary": self.engine_pin.binary_sha256,
            "build": self.engine_pin.build_sha256,
        })
    }

    pub fn load(path: &Path) -> Result<(Self, String)> {
        let data = read_exact_file(path, None)?;
        let job: Manifest = serde_json::from_slice(&data)?;
        ensure!(
            job.protocol_version == PROTOCOL && job.codec_version == CODEC,
            "unsupported learning protocol or codec"
        );
        ensure!(
            [
                &job.job_id,
                &job.library_base_version,
                &job.evidence_snapshot_id
            ]
            .into_iter()
            .all(|name| identifier(name)),
            "invalid job identity"
        );
        let upstream: toml::Value = toml::from_str(include_str!(
            "../../../third_party/egg-stitch/UPSTREAM.toml"
        ))?;
        let pin = &job.engine_pin;
        ensure!(
            pin.protocol_version == PROTOCOL
                && upstream["revision"].as_str() == Some(&pin.upstream_commit)
                && upstream["tree_sha1"].as_str() == Some(&pin.source_git_tree)
                && pin.cargo_lock_sha256 == digest(include_bytes!("../../../Cargo.lock"))
                && pin.rust_version == "1.90.0"
                && pin.build_sha256 == BUILD_SHA
                && pin.binary_sha256 == running_binary_sha()?,
            "worker source or ABI pin mismatch"
        );
        Ok((job, digest(&data)))
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SlotSpec {
    pub index: usize,
    pub sort: String,
    pub time_role: String,
    pub role_constraints: Vec<serde_json::Value>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    schema_version: u32,
    language: String,
    search: String,
    pub max_arity: usize,
    sym_var_cost: u32,
    pub search_options: SearchOptions,
    pub processing: Processing,
    pub termination: Termination,
    pub progress: Progress,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SearchOptions {
    pub priority: String,
    pub freeze_rule: String,
    pub var_order: String,
    pub lower_bound: String,
    pub opt_seen: bool,
    pub opt_dedup_by_match: bool,
    pub opt_dominance_reuse: bool,
    pub opt_useless_frozen: bool,
    pub opt_useless_inline: bool,
    pub allow_useless_vars: bool,
    pub no_zero_arity: bool,
    pub decompose_min_rows: usize,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Processing {
    pub apply_chunk_rows: usize,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Termination {
    learning: String,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Progress {
    pub accepted_definition_checkpoints: Vec<usize>,
    pub search_pop_checkpoints: Vec<usize>,
}

impl Config {
    pub fn load(data: &[u8]) -> Result<Self> {
        let c: Self = toml::from_str(std::str::from_utf8(data)?)?;
        ensure!(
            c.schema_version == 2
                && c.language == "typed-op-children-db-v1"
                && c.search == "best-first"
                && c.sym_var_cost == 1
                && c.termination.learning == "verified_compression_fixed_point",
            "unsupported search or cost profile"
        );
        ensure!(
            c.processing.apply_chunk_rows > 0 && c.search_options.decompose_min_rows > 0,
            "invalid processing granularity"
        );
        for points in [
            &c.progress.accepted_definition_checkpoints,
            &c.progress.search_pop_checkpoints,
        ] {
            ensure!(
                points.first().is_none_or(|n| *n > 0) && points.windows(2).all(|w| w[0] < w[1]),
                "progress points must be distinct and increasing"
            );
        }
        Ok(c)
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Origin {
    pub program_index: usize,
    pub expression_path: Vec<usize>,
    pub occurrence_id: String,
    pub event_ref: String,
    pub interpretation_ref: String,
    pub slot_bindings_ref: String,
    pub support_ref: String,
    pub source_kind: String,
}

pub type OriginSites = BTreeMap<Vec<usize>, String>;

impl Origin {
    pub fn index(origins: &[Origin], sites: &[BTreeSet<Vec<usize>>]) -> Result<Vec<OriginSites>> {
        let mut index = vec![BTreeMap::new(); sites.len()];
        let mut ids = BTreeSet::new();
        for o in origins {
            ensure!(
                o.program_index < sites.len()
                    && sites[o.program_index].contains(&o.expression_path)
                    && identifier(&o.occurrence_id)
                    && ids.insert(o.occurrence_id.clone())
                    && [
                        &o.event_ref,
                        &o.interpretation_ref,
                        &o.slot_bindings_ref,
                        &o.support_ref
                    ]
                    .into_iter()
                    .all(|name| !name.is_empty()),
                "invalid or duplicate occurrence"
            );
            ensure!(
                index[o.program_index]
                    .insert(o.expression_path.clone(), o.occurrence_id.clone())
                    .is_none(),
                "duplicate occurrence position"
            );
        }
        ensure!(
            index
                .iter()
                .zip(sites)
                .all(|(origins, paths)| origins.len() == paths.len()),
            "a syntax occurrence is missing"
        );
        Ok(index)
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SemanticContext {
    schema_version: u64,
    intent: String,
    consumer: String,
    obligation_refs: Vec<String>,
    programs: Vec<ProgramScope>,
    constructions: Vec<Construction>,
}

#[derive(Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct ProgramScope {
    program_index: usize,
    sort: String,
    event_refs: Vec<String>,
    scope_refs: Vec<String>,
}

#[derive(Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct Construction {
    id: String,
    operator: String,
    parents: Vec<String>,
    scope: String,
}

impl SemanticContext {
    pub fn check(&self, terms: &[Term], registry: &Registry, origins: &[Origin]) -> Result<()> {
        ensure!(
            self.schema_version == 3
                && identifier(&self.consumer)
                && matches!(
                    self.intent.as_str(),
                    "effect" | "relation" | "program" | "symbolic"
                )
                && self
                    .obligation_refs
                    .iter()
                    .all(|reference| identifier(reference))
                && self.obligation_refs.iter().collect::<BTreeSet<_>>().len()
                    == self.obligation_refs.len()
                && self.programs.len() == terms.len(),
            "invalid learning intent or semantic context"
        );
        let sites = origins
            .iter()
            .map(|origin| {
                (
                    (origin.program_index, origin.expression_path.as_slice()),
                    origin,
                )
            })
            .collect::<BTreeMap<_, _>>();
        let mut constructions = Vec::new();
        for (i, (term, declared)) in terms.iter().zip(&self.programs).enumerate() {
            let sort = registry.sorts[registry.infer(term, None)? as usize].clone();
            ensure!(
                match self.intent.as_str() {
                    "relation" => sort.starts_with("rel_"),
                    "program" => sort.starts_with("prog_"),
                    "effect" => sort == "Relation",
                    _ => true,
                },
                "program result is outside the frozen learning intent"
            );
            let mut scope = ProgramScope {
                program_index: i,
                sort,
                event_refs: Vec::new(),
                scope_refs: Vec::new(),
            };
            let first = constructions.len();
            let mut invalid = false;
            let mut seen_events = BTreeSet::new();
            let mut seen_scopes = BTreeSet::new();
            term.walk(&mut Vec::new(), &mut |path, node| {
                let origin = sites[&(i, path.as_slice())];
                if seen_events.insert(&origin.event_ref) {
                    scope.event_refs.push(origin.event_ref.clone());
                }
                if seen_scopes.insert(&origin.slot_bindings_ref) {
                    scope.scope_refs.push(origin.slot_bindings_ref.clone());
                }
                if let Term::Call { operator, args } = node
                    && registry.is_constructed(operator)
                {
                    invalid |= origin.source_kind != "constructed";
                    let mut child = path.clone();
                    child.push(0);
                    let parents = (0..args.len())
                        .map(|index| {
                            child[path.len()] = index;
                            sites[&(i, child.as_slice())].occurrence_id.clone()
                        })
                        .collect();
                    constructions.push(Construction {
                        id: origin.occurrence_id.clone(),
                        operator: operator.clone(),
                        parents,
                        scope: origin.slot_bindings_ref.clone(),
                    });
                } else {
                    invalid |= origin.source_kind != "observed";
                }
            });
            ensure!(
                !invalid && scope == *declared,
                "semantic source scope differs"
            );
            constructions[first..].reverse();
        }
        ensure!(
            constructions == self.constructions,
            "frozen construction provenance differs"
        );
        Ok(())
    }
}

#[derive(Serialize)]
struct Checkpoint<'a> {
    round_index: usize,
    input_sha256: &'a str,
    parent_checkpoint_sha256: Option<&'a str>,
    result_sha256: String,
    result_bytes: usize,
    search_expansions: usize,
}

struct HashedWriter {
    output: BufWriter<File>,
    hash: Sha256,
    bytes: usize,
}

impl Write for HashedWriter {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        crate::resources::check();
        let count = self.output.write(data)?;
        self.bytes = self.bytes.checked_add(count).expect("output size overflow");
        self.hash.update(&data[..count]);
        Ok(count)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.output.flush()
    }
}

pub fn commit<T: Serialize>(
    output: &Path,
    round: usize,
    input: &str,
    parent: Option<&str>,
    result: &T,
    expansions: usize,
    before_manifest: impl FnOnce(),
) -> Result<String> {
    let name = format!("round-{round:06}");
    let temporary = output.join(format!("{name}.tmp"));
    let finished = output.join(name);
    if finished.exists() {
        bail!("immutable checkpoint already exists");
    }
    fs::create_dir(&temporary)?;
    let span = crate::resources::phase(crate::resources::Phase::Serialize);
    let mut writer = HashedWriter {
        output: BufWriter::new(File::create_new(temporary.join("result.json"))?),
        hash: Sha256::new(),
        bytes: 0,
    };
    serde_json::to_writer(&mut writer, result)?;
    writer.flush()?;
    writer.output.get_ref().sync_all()?;
    before_manifest();
    drop(span);
    let _span = crate::resources::phase(crate::resources::Phase::Commit);
    let checkpoint = serde_json::to_vec(&Checkpoint {
        round_index: round,
        input_sha256: input,
        parent_checkpoint_sha256: parent,
        result_sha256: format!("{:x}", writer.hash.finalize()),
        result_bytes: writer.bytes,
        search_expansions: expansions,
    })?;
    sync_file(&temporary.join("manifest.json"), &checkpoint)?;
    File::open(&temporary)?.sync_all()?;
    fs::rename(&temporary, finished)?;
    File::open(output)?.sync_all()?;
    Ok(digest(&checkpoint))
}

fn sync_file(path: &Path, data: &[u8]) -> Result<()> {
    let mut file = File::create_new(path)?;
    file.write_all(data)?;
    file.sync_all()?;
    Ok(())
}

pub fn atomic_json<T: Serialize>(output: &Path, name: &str, value: &T) -> Result<()> {
    let temporary = output.join(format!("{name}.tmp"));
    sync_file(&temporary, &serde_json::to_vec(value)?)?;
    fs::rename(&temporary, output.join(name))?;
    File::open(output)?.sync_all()?;
    Ok(())
}
