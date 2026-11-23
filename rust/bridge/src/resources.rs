use std::{
    alloc::{GlobalAlloc, Layout, System},
    sync::atomic::{AtomicU64, AtomicUsize, Ordering::Relaxed},
    time::Instant,
};

pub struct MeasuredAllocator;

#[global_allocator]
static ALLOCATOR: MeasuredAllocator = MeasuredAllocator;

static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);
static ALLOCATED: AtomicU64 = AtomicU64::new(0);
static LIMIT: AtomicUsize = AtomicUsize::new(usize::MAX);
static CURRENT: AtomicUsize = AtomicUsize::new(0);
const NAMES: [&str; 8] = [
    "load",
    "graph",
    "search",
    "apply",
    "extract",
    "proof",
    "serialize",
    "commit",
];
static STAGE_PEAK: [AtomicUsize; NAMES.len()] = [const { AtomicUsize::new(0) }; NAMES.len()];
static STAGE_TIME: [AtomicU64; NAMES.len()] = [const { AtomicU64::new(0) }; NAMES.len()];

fn added(size: usize) {
    ALLOCATED.fetch_add(size as u64, Relaxed);
    let live = LIVE.fetch_add(size, Relaxed) + size;
    PEAK.fetch_max(live, Relaxed);
    if let Some(phase) = STAGE_PEAK.get(CURRENT.load(Relaxed).wrapping_sub(1)) {
        phase.fetch_max(live, Relaxed);
    }
}

unsafe impl GlobalAlloc for MeasuredAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let ptr = unsafe { System.alloc(layout) };
        if !ptr.is_null() {
            added(layout.size());
        }
        ptr
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let ptr = unsafe { System.alloc_zeroed(layout) };
        if !ptr.is_null() {
            added(layout.size());
        }
        ptr
    }

    unsafe fn realloc(&self, original: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let ptr = unsafe { System.realloc(original, layout, new_size) };
        if !ptr.is_null() {
            if new_size >= layout.size() {
                added(new_size - layout.size());
            } else {
                LIVE.fetch_sub(layout.size() - new_size, Relaxed);
            }
        }
        ptr
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) };
        LIVE.fetch_sub(layout.size(), Relaxed);
    }
}

#[derive(Clone, Copy)]
pub enum Phase {
    Load,
    Graph,
    Search,
    Apply,
    Extract,
    Proof,
    Serialize,
    Commit,
}

pub struct Span {
    phase: usize,
    previous: usize,
    start: Instant,
}

pub fn phase(which: Phase) -> Span {
    let phase = which as usize;
    let previous = CURRENT.swap(phase + 1, Relaxed);
    STAGE_PEAK[phase].fetch_max(live(), Relaxed);
    Span {
        phase,
        previous,
        start: Instant::now(),
    }
}

impl Drop for Span {
    fn drop(&mut self) {
        STAGE_TIME[self.phase].fetch_add(self.start.elapsed().as_nanos() as u64, Relaxed);
        CURRENT.store(self.previous, Relaxed);
    }
}

pub fn limit(bytes: usize) {
    LIMIT.store(bytes, Relaxed);
}

pub fn live() -> usize {
    LIVE.load(Relaxed)
}

pub fn check() {
    if live() > LIMIT.load(Relaxed) {
        std::panic::panic_any(egg_stitch::lang::SearchBudgetStop("managed_bytes"));
    }
}

pub fn report(exit_code: i32, stop_reason: Option<&str>, committed: usize) -> serde_json::Value {
    let stages: serde_json::Map<_, _> = NAMES
        .iter()
        .enumerate()
        .map(|(i, name)| {
            (
                (*name).to_owned(),
                serde_json::json!({
                    "peak_live_bytes": STAGE_PEAK[i].load(Relaxed),
                    "wall_ns": STAGE_TIME[i].load(Relaxed),
                }),
            )
        })
        .collect();
    serde_json::json!({
        "exit_code": exit_code, "stop_reason": stop_reason,
        "complete_rounds": committed, "managed_byte_limit": LIMIT.load(Relaxed),
        "peak_live_bytes": PEAK.load(Relaxed), "total_added_bytes": ALLOCATED.load(Relaxed),
        "phases": stages,
    })
}
