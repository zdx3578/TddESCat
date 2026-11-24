use sha2::{Digest, Sha256};
use std::{
    env, fs,
    path::{Path, PathBuf},
};

const FILES: [&str; 8] = [
    "Cargo.toml",
    "Cargo.lock",
    "rust-toolchain.toml",
    "rust/bridge/Cargo.toml",
    "rust/bridge/build.rs",
    "third_party/egg-stitch/Cargo.toml",
    "third_party/egg-stitch/UPSTREAM.toml",
    "third_party/egg/Cargo.toml",
];
const TREES: [&str; 3] = [
    "rust/bridge/src",
    "third_party/egg-stitch/src",
    "third_party/egg/src",
];

fn append_tree(root: &Path, directory: &Path, files: &mut Vec<PathBuf>) {
    for entry in fs::read_dir(root.join(directory)).expect("source directory") {
        let entry = entry.expect("source entry");
        let path = directory.join(entry.file_name());
        match entry.file_type().expect("source entry type") {
            kind if kind.is_file() => files.push(path),
            kind if kind.is_dir() => append_tree(root, &path, files),
            _ => panic!("unsupported build input: {}", path.display()),
        }
    }
}

fn main() {
    let root = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap()).join("../..");
    let mut files = FILES.into_iter().map(PathBuf::from).collect::<Vec<_>>();
    for dir in TREES {
        println!("cargo:rerun-if-changed={}", root.join(dir).display());
        append_tree(&root, Path::new(dir), &mut files);
    }
    files.sort();
    let mut overall = Sha256::new();
    for file in files {
        let path = root.join(&file);
        println!("cargo:rerun-if-changed={}", path.display());
        overall.update(file.to_str().expect("UTF-8 source path").as_bytes());
        overall.update([0]);
        overall.update(Sha256::digest(fs::read(path).expect("build input")));
    }
    println!(
        "cargo:rustc-env=TDDESC_BUILD_SHA256={:x}",
        overall.finalize()
    );
}
