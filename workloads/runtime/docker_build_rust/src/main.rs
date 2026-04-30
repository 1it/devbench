use anyhow::Result;
use clap::Parser;
use serde::{Deserialize, Serialize};

/// A tiny binary we build in-container to exercise a representative dev Docker workflow.
/// The point is to build it, not to run it; entrypoint exists so the image is valid.
#[derive(Parser, Debug)]
#[command(name = "devbench-dockerload", about = "devbench dummy binary")]
struct Args {
    /// Echo this back as JSON
    #[arg(long, default_value = "hello")]
    msg: String,
}

#[derive(Serialize, Deserialize)]
struct Payload<'a> {
    msg: &'a str,
    tokio_runtime: &'static str,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    let args = Args::parse();
    let payload = Payload {
        msg: &args.msg,
        tokio_runtime: "multi-thread",
    };
    println!("{}", serde_json::to_string(&payload)?);
    Ok(())
}
