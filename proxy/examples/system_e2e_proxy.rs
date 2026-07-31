use std::path::PathBuf;

use agent_remote_device_proxy::{
    protocol::Action,
    transport::{ActivatedUnixDeviceTransport, DeviceTransport},
};
use clap::Parser;

#[derive(Debug, Parser)]
struct Args {
    #[arg(long)]
    managed_context: PathBuf,
    #[arg(long)]
    bridge_socket: PathBuf,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    let transport = ActivatedUnixDeviceTransport::new(&args.managed_context, &args.bridge_socket);
    let result = transport.execute(Action::Screenshot).await?;
    if result.message != "system-e2e-ok" || result.screenshot.is_some() {
        return Err("system E2E response did not match the Swift peer".into());
    }
    println!("Server -> Node -> Rust -> Swift device-control E2E passed");
    Ok(())
}
