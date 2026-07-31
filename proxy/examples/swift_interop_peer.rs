use std::{
    fs::OpenOptions,
    io::Write,
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    sync::Arc,
};

use agent_remote_device_proxy::{
    nested_tls::{
        confirmation_record, server_config, server_exporter_binding, verify_peer_confirmation,
        GenerationIdentity, GenerationMaterial, NestedTlsRole, CONFIRMATION_RECORD_BYTES,
    },
    protocol::{Action, ActionRequest, Platform, RequestContext, MAX_FRAME_BYTES},
};
use chrono::{Duration, Utc};
use clap::Parser;
use serde::{Deserialize, Serialize};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};
use tokio_rustls::TlsAcceptor;
use uuid::Uuid;

#[derive(Debug, Parser)]
struct Args {
    #[arg(long)]
    peer_spki: String,
    #[arg(long)]
    exporter_context: String,
    #[arg(long)]
    generation: u64,
    #[arg(long)]
    user_id: Uuid,
    #[arg(long)]
    device_id: Uuid,
    #[arg(long)]
    tool_session_id: Uuid,
    #[arg(long)]
    device_session_id: Uuid,
    #[arg(long)]
    node_id: Uuid,
    #[arg(long)]
    ready_file: PathBuf,
}

#[derive(Serialize)]
struct ReadyRecord {
    port: u16,
    spki_sha256: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct InteropResponse {
    request_id: Uuid,
    monotonic_sequence: u64,
    screenshot_generation: u64,
    status: String,
    message: String,
    image: Option<serde_json::Value>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    let identity = GenerationIdentity::generate()?;
    let material =
        GenerationMaterial::from_hex(args.generation, &args.peer_spki, &args.exporter_context)?;
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    write_ready_file(
        &args.ready_file,
        &ReadyRecord {
            port: listener.local_addr()?.port(),
            spki_sha256: identity.spki_sha256_hex(),
        },
    )?;

    let (stream, _) = listener.accept().await?;
    let acceptor = TlsAcceptor::from(Arc::new(server_config(&identity, &material)?));
    let mut tls = acceptor.accept(stream).await?;
    let exporter = server_exporter_binding(tls.get_ref().1, &material)?;
    let mut peer_confirmation = [0_u8; CONFIRMATION_RECORD_BYTES];
    tls.read_exact(&mut peer_confirmation).await?;
    verify_peer_confirmation(
        &peer_confirmation,
        &exporter,
        NestedTlsRole::Proxy,
        args.generation,
        args.device_session_id,
    )?;
    let confirmation = confirmation_record(
        &exporter,
        NestedTlsRole::Proxy,
        args.generation,
        args.device_session_id,
    );
    tls.write_all(&confirmation).await?;
    tls.flush().await?;

    let request = ActionRequest {
        version: 1,
        request_id: Uuid::new_v4(),
        context: RequestContext {
            user_id: args.user_id,
            device_id: args.device_id,
            tool_session_id: args.tool_session_id,
            device_session_id: args.device_session_id,
            node_id: args.node_id,
            platform: Platform::Macos,
            generation: args.generation,
            monotonic_sequence: 1,
            current_screenshot_generation: 0,
        },
        lease_until: Utc::now() + Duration::seconds(60),
        action: Action::Screenshot,
    };
    let payload = serde_json::to_vec(&serde_json::json!({"request": request}))?;
    if payload.len() > MAX_FRAME_BYTES {
        return Err("interop request exceeds frame limit".into());
    }
    tls.write_u32(payload.len() as u32).await?;
    tls.write_all(&payload).await?;
    tls.flush().await?;

    let response_length = tls.read_u32().await? as usize;
    if response_length == 0 || response_length > MAX_FRAME_BYTES {
        return Err("interop response has invalid length".into());
    }
    let mut response = vec![0_u8; response_length];
    tls.read_exact(&mut response).await?;
    let value: InteropResponse = serde_json::from_slice(&response)?;
    if value.request_id != request.request_id
        || value.monotonic_sequence != 1
        || value.screenshot_generation != 1
        || value.status != "success"
        || value.message != "swift-network-framework-ok"
        || value.image.is_some()
    {
        return Err("Swift response does not match the Rust request".into());
    }
    Ok(())
}

fn write_ready_file(path: &Path, value: &ReadyRecord) -> Result<(), Box<dyn std::error::Error>> {
    let temporary = path.with_extension("tmp");
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    file.write_all(&serde_json::to_vec(value)?)?;
    file.sync_all()?;
    std::fs::rename(temporary, path)?;
    Ok(())
}
