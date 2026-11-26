use crate::protocol::{BUILD_SHA, atomic_json};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::{BufReader, BufWriter, Read},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

const SCHEMA_VERSION: u8 = 2;
const MIN_SEARCH_BETWEEN_SAVES: Duration = Duration::from_secs(30);
const SEARCH_TO_SAVE_RATIO: u32 = 12;

pub struct SaveSchedule {
    last_pop: usize,
    next_save: Instant,
}

impl SaveSchedule {
    pub fn new(heap_pops: usize, started: Instant) -> Self {
        Self {
            last_pop: heap_pops,
            next_save: started + MIN_SEARCH_BETWEEN_SAVES,
        }
    }

    pub fn due(&self, heap_pops: usize, pause: bool, sample: bool, now: Instant) -> bool {
        heap_pops > self.last_pop && (pause || (sample && now >= self.next_save))
    }

    pub fn saved(&mut self, heap_pops: usize, started: Instant, finished: Instant) {
        self.last_pop = heap_pops;
        let elapsed = finished.duration_since(started);
        self.next_save =
            finished + MIN_SEARCH_BETWEEN_SAVES.max(elapsed.saturating_mul(SEARCH_TO_SAVE_RATIO));
    }
}

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
        directory.join(format!("state-{heap_pops:012}.json.zst"))
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
            latest.schema_version == SCHEMA_VERSION
                && latest.build == BUILD_SHA
                && latest.input == self.input
                && latest.graph == graph,
            "best-first snapshot has a different format, frozen input, graph or build"
        );
        let data = Self::state_path(&directory, latest.heap_pops);
        let (bytes, sha256) = digest_file(&data).context("digest best-first snapshot")?;
        ensure!(
            latest.bytes == bytes && latest.sha256 == sha256,
            "best-first snapshot content mismatch"
        );
        let decoder = zstd::stream::read::Decoder::new(File::open(data)?)?;
        let state = serde_json::from_reader(BufReader::new(decoder))?;
        Ok(Some((state, latest.heap_pops)))
    }

    pub fn save<T: Serialize>(
        &self,
        graph: &str,
        state: &T,
        heap_pops: usize,
        frontier: usize,
    ) -> Result<u64> {
        let output = self.output.join("search-state");
        let directory = self.round_directory(&output);
        fs::create_dir_all(&directory)?;
        let data = Self::state_path(&directory, heap_pops);
        let temporary = data.with_extension("zst.tmp");
        let file = File::create_new(&temporary)?;
        let encoder = zstd::stream::write::Encoder::new(file, 1)?;
        let mut stream = BufWriter::with_capacity(128 * 1024, encoder);
        serde_json::to_writer(&mut stream, state)?;
        let encoder = stream.into_inner().map_err(|error| error.into_error())?;
        encoder.finish()?.sync_all()?;
        let (bytes, sha256) = digest_file(&temporary)?;
        let previous = File::open(directory.join("latest.json"))
            .ok()
            .and_then(|file| serde_json::from_reader::<_, Manifest>(BufReader::new(file)).ok());
        fs::rename(temporary, data)?;
        atomic_json(
            &directory,
            "latest.json",
            &Manifest {
                schema_version: SCHEMA_VERSION,
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
        Ok(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn automatic_saves_leave_time_for_search_and_explicit_pause_is_immediate() {
        let started = Instant::now();
        let mut schedule = SaveSchedule::new(0, started);
        assert!(!schedule.due(2048, false, true, started));
        assert!(schedule.due(1, true, false, started));
        let first = started + Duration::from_secs(30);
        assert!(!schedule.due(2047, false, false, first));
        assert!(schedule.due(2048, false, true, first));
        let finished = first + Duration::from_secs(10);
        schedule.saved(2048, first, finished);
        assert!(!schedule.due(2048, true, true, finished));
        assert!(schedule.due(2049, true, false, finished));
        assert!(!schedule.due(4096, false, true, finished + Duration::from_secs(119)));
        assert!(schedule.due(4096, false, true, finished + Duration::from_secs(120)));
    }
}
