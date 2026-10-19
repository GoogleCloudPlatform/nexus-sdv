// Generates Rust types from the shared telemetry schema at build time. The
// vehicle side hand-writes the wire format because Soong has no proto codegen;
// here there is Cargo, so generated types are the right call.
fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-changed=proto/telemetry.proto");
    prost_build::compile_protos(&["proto/telemetry.proto"], &["proto/"])?;
    Ok(())
}
