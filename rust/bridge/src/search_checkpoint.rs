use crate::protocol::{BUILD_SHA, atomic_json};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::{BufReader, BufWriter, Read, Write},
    path::{Path, PathBuf},
};

#[derive(Serialize, Deserialize)]
struct Manifest {
    schema_version: u8,
    build: String,
    input: String,
    graph: String,
    heap_pops: usize,
    frontier: usize,
    bytes: u64,
    sha256: String,
}

pub struct SearchStore<'a> {
    pub output: &'a Path,
    pub resume: Option<&'a Path>,
    pub input: &'a str,
    pub round: usize,
    pub pause_after: Option<usize>,
}

fn digest_file(path: &Path) -> Result<(u64, String)> {
    let mut file = File::open(path)?;
    let mut hash = Sha256::new();
    let size = file.metadata()?.len();
    let mut buffer = [0; 64 * 1024];
    loop {
        let size = file.read(&mut buffer)?;
        if size == 0 {
            break;
        }
        hash.update(&buffer[..size]);
    }
    Ok((size, format!("{:x}", hash.finalize())))
}

impl SearchStore<'_> {
    fn round_directory(&self, root: &Path) -> PathBuf {
        root.join(format!("round-{:06}", self.round))
    }

    fn state_path(directory: &Path, heap_pops: usize) -> PathBuf {
        directory.join(format!("state-{heap_pops:012}.json"))
    }

    pub fn load<T: DeserializeOwned>(&self, graph: &str) -> Result<Option<(T, usize)>> {
        let Some(resume) = self.resume else {
            return Ok(None);
        };
        let directory = self.round_directory(resume);
        let pointer = directory.join("latest.json");
        if !pointer.is_file() {
            return Ok(None);
        }
        let latest: Manifest = serde_json::from_reader(BufReader::new(File::open(pointer)?))?;
        ensure!(
            latest.schema_version == 1
                && latest.build == BUILD_SHA
                && latest.input == self.input
                && latest.graph == graph,
            "best-first snapshot has a different frozen input, graph or build"
        );
        let data = Self::state_path(&directory, latest.heap_pops);
        let (bytes, sha256) = digest_file(&data).context("digest best-first snapshot")?;
        ensure!(
            latest.bytes == bytes && latest.sha256 == sha256,
            "best-first snapshot content mismatch"
        );
        let state = serde_json::from_reader(BufReader::new(File::open(data)?))?;
        Ok(Some((state, latest.heap_pops)))
    }

    pub fn save<T: Serialize>(
        &self,
        graph: &str,
        state: &T,
        heap_pops: usize,
        frontier: usize,
    ) -> Result<()> {
        let output = self.output.join("search-state");
        let directory = self.round_directory(&output);
        fs::create_dir_all(&directory)?;
        let data = Self::state_path(&directory, heap_pops);
        let temporary = data.with_extension("json.tmp");
        let mut file = BufWriter::new(File::create_new(&temporary)?);
        serde_json::to_writer(&mut file, state)?;
        file.flush()?;
        file.get_ref().sync_all()?;
        drop(file);
        let (bytes, sha256) = digest_file(&temporary)?;
        let previous = File::open(directory.join("latest.json"))
            .ok()
            .and_then(|file| serde_json::from_reader::<_, Manifest>(BufReader::new(file)).ok());
        fs::rename(temporary, data)?;
        atomic_json(
            &directory,
            "latest.json",
            &Manifest {
                schema_version: 1,
                build: BUILD_SHA.into(),
                input: self.input.into(),
                graph: graph.into(),
                heap_pops,
                frontier,
                bytes,
                sha256,
            },
        )?;
        File::open(&output)?.sync_all()?;
        if let Some(previous) = previous
            && previous.heap_pops != heap_pops
        {
            fs::remove_file(Self::state_path(&directory, previous.heap_pops))?;
        }
        Ok(())
    }
}
