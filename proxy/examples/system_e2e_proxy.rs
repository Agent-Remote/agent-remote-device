use std::path::PathBuf;

use agent_remote_device_proxy::{
    protocol_v2::{ActionV2, ObservationPolicy},
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
    if !transport.supports_v2().await? {
        return Err("system E2E context did not negotiate Computer Use v2".into());
    }
    let result = transport
        .execute_v2(
            ActionV2::Observe { application: None },
            ObservationPolicy::default(),
        )
        .await?;
    if result.message != "system-e2e-v2-ok"
        || result.state_generation != 1
        || result.screenshot_generation != 0
        || result.screenshot.is_some()
        || !result
            .observation
            .as_ref()
            .is_some_and(|observation| observation.reset && observation.nodes.is_empty())
    {
        return Err("system E2E response did not match the Swift peer".into());
    }
    println!("Server -> Node -> Rust -> Swift Computer Use v2 E2E passed");
    Ok(())
}
