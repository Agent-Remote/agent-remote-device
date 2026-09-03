use std::path::PathBuf;

use agent_remote_device_proxy::{
    protocol_v2::{
        ActionV2, ObservationPolicy, CAPABILITY_APPLICATION_LAUNCH_V1,
        CAPABILITY_GLOBAL_CLIPBOARD_V1, CAPABILITY_SESSION_FULL_TRUST_V1,
    },
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
    for capability in [
        CAPABILITY_SESSION_FULL_TRUST_V1,
        CAPABILITY_APPLICATION_LAUNCH_V1,
        CAPABILITY_GLOBAL_CLIPBOARD_V1,
    ] {
        if !transport.supports_capability(capability).await? {
            return Err(format!("system E2E context did not negotiate {capability}").into());
        }
    }
    let clipboard = transport
        .execute_v2(ActionV2::ReadClipboard, ObservationPolicy::default())
        .await?;
    if clipboard.message != "system-e2e-clipboard"
        || clipboard.state_generation != 0
        || clipboard.state_id.is_some()
        || clipboard.observation.is_some()
        || clipboard.screenshot.is_some()
    {
        return Err("system E2E global clipboard response was not stateless".into());
    }
    let launched = transport
        .execute_v2(
            ActionV2::LaunchApplication {
                application: "TextEdit".to_owned(),
            },
            ObservationPolicy::default(),
        )
        .await?;
    if launched.message != "system-e2e-launch-ok"
        || launched.state_generation != 1
        || launched.screenshot_generation != 0
        || launched.state_id.is_none()
        || launched.observation.is_none()
        || launched.screenshot.is_some()
    {
        return Err("system E2E launch response did not contain its first observation".into());
    }
    let result = transport
        .execute_v2(
            ActionV2::Observe { application: None },
            ObservationPolicy::default(),
        )
        .await?;
    if result.message != "system-e2e-observe-ok"
        || result.state_generation != 2
        || result.screenshot_generation != 0
        || result.screenshot.is_some()
        || !result
            .observation
            .as_ref()
            .is_some_and(|observation| observation.reset && observation.nodes.is_empty())
    {
        return Err("system E2E response did not match the Swift peer".into());
    }
    println!("Server -> Node -> Rust -> Swift full-trust E2E passed");
    Ok(())
}
