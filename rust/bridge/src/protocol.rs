use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File},
    io::{Read, Write},
    path::{Component, Path},
};

pub const PROTOCOL: &str = "tddescat.learn.v1";
pub const BUILD_SHA: &str = env!("TDDESC_BUILD_SHA256");
pub const CODEC: &str = "typed-free-slots.v1";
const MAX_DOCUMENT_BYTES: usize = 4 * 1024 * 1024;

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

pub fn read_limited(path: &Path, limit: usize) -> Result<Vec<u8>> {
    let file = File::open(path)?;
    let attrs = file.metadata()?;
    ensure!(
        attrs.is_file() && attrs.len() <= limit as u64,
        "file size exceeds limit: {path:?}"
    );
    let mut bytes = Vec::with_capacity(attrs.len() as usize);
    file.take(limit as u64 + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= limit, "file changed size: {path:?}");
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
        ensure!(
            self.bytes <= MAX_DOCUMENT_BYTES,
            "input exceeds worker document limit"
        );
        let absolute = root.join(relative).canonicalize()?;
        ensure!(
            absolute.starts_with(root),
            "input path escapes frozen work directory"
        );
        let bytes = read_limited(&absolute, self.bytes)?;
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
    pub initial_library_file: FileRef,
    pub rules_file: FileRef,
    pub config_file: FileRef,
    pub program_count: usize,
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
    pub fn load(path: &Path) -> Result<(Self, String)> {
        let data = read_limited(path, MAX_DOCUMENT_BYTES)?;
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

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    schema_version: u32,
    language: String,
    search: String,
    seed: u64,
    pub rounds: usize,
    pub max_steps: usize,
    pub max_arity: usize,
    sym_var_cost: u32,
    pub budget: Budget,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Budget {
    pub wall_ms: u64,
    pub managed_bytes: usize,
    pub max_egraph_nodes: usize,
    pub max_live_states: usize,
    pub max_relation_nodes: usize,
    pub max_output_bytes: usize,
    #[serde(default = "default_apply_chunk_rows")]
    pub apply_chunk_rows: usize,
    check_every_work_units: usize,
}

fn default_apply_chunk_rows() -> usize {
    128
}

impl Config {
    pub fn load(data: &[u8]) -> Result<Self> {
        let c: Self = toml::from_str(std::str::from_utf8(data)?)?;
        ensure!(
            c.schema_version == 1
                && c.language == "typed-op-children-db-v1"
                && c.search == "best-first"
                && c.sym_var_cost == 1
                && c.seed == 1729,
            "unsupported search or cost profile"
        );
        ensure!(
            (1..=16).contains(&c.rounds)
                && (1..=8).contains(&c.max_arity)
                && (1..=1_000_000).contains(&c.max_steps)
                && (1..=600_000).contains(&c.budget.wall_ms)
                && (1..=2_000_000).contains(&c.budget.max_egraph_nodes)
                && (1..=1_000_000).contains(&c.budget.max_live_states)
                && (1..=2_000_000).contains(&c.budget.max_relation_nodes)
                && (1..=MAX_DOCUMENT_BYTES).contains(&c.budget.max_output_bytes)
                && (1..=1_073_741_824).contains(&c.budget.managed_bytes)
                && (1..=8192).contains(&c.budget.apply_chunk_rows)
                && c.budget.check_every_work_units == 128,
            "unsupported budget range"
        );
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
}

pub type OriginSites = BTreeMap<Vec<usize>, String>;

impl Origin {
    pub fn index(origins: Vec<Origin>, sites: &[BTreeSet<Vec<usize>>]) -> Result<Vec<OriginSites>> {
        let mut index = vec![BTreeMap::new(); sites.len()];
        let mut ids = BTreeSet::new();
        for o in origins {
            ensure!(
                o.program_index < sites.len()
                    && sites[o.program_index].contains(&o.expression_path)
                    && identifier(&o.occurrence_id)
                    && ids.insert(o.occurrence_id.clone())
                    && [
                        o.event_ref,
                        o.interpretation_ref,
                        o.slot_bindings_ref,
                        o.support_ref
                    ]
                    .into_iter()
                    .all(|name| !name.is_empty()),
                "invalid or duplicate occurrence"
            );
            ensure!(
                index[o.program_index]
                    .insert(o.expression_path, o.occurrence_id)
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

#[derive(Serialize)]
struct Checkpoint<'a> {
    round_index: usize,
    input_sha256: &'a str,
    parent_checkpoint_sha256: Option<&'a str>,
    result_sha256: String,
    result_bytes: usize,
    search_expansions: usize,
}

pub fn commit(
    output: &Path,
    round: usize,
    input: &str,
    parent: Option<&str>,
    bytes: &[u8],
    expansions: usize,
) -> Result<String> {
    let name = format!("round-{round:06}");
    let temporary = output.join(format!("{name}.tmp"));
    let finished = output.join(name);
    if finished.exists() {
        bail!("immutable checkpoint already exists");
    }
    fs::create_dir(&temporary)?;
    sync_file(&temporary.join("result.json"), bytes)?;
    let checkpoint = serde_json::to_vec(&Checkpoint {
        round_index: round,
        input_sha256: input,
        parent_checkpoint_sha256: parent,
        result_sha256: digest(bytes),
        result_bytes: bytes.len(),
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
