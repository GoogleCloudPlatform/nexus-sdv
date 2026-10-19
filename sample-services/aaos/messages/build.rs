//! Generates the Rust types from the same .proto files the vehicle side is generated from.
//! Ours come straight from the VSIDL catalog — one source for both sides; Google's tyre
//! pressure is an excerpt kept beside this crate, because its tree is not in this repository.
use std::path::Path;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let here = Path::new(env!("CARGO_MANIFEST_DIR"));
    let catalog = here.join("../../../aaos/nexus-sdv-sample/catalog");
    let sdk = here.join("../../../aaos/nexus-sdk-catalog");
    let excerpts = here.join("proto");
    let files = [
        catalog.join("nexus_sample.proto"),
        sdk.join("nexus_sdk.proto"),
        excerpts.join("google_quickstart_tire.proto"),
    ];
    for f in &files {
        println!("cargo:rerun-if-changed={}", f.display());
    }
    let descriptors = protox::compile(&files, [&catalog, &sdk, &excerpts])?;
    prost_build::Config::new().compile_fds(descriptors)?;
    Ok(())
}
