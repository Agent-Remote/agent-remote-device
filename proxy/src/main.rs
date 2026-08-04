use std::{
    io::Read,
    os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::Arc,
};

use agent_remote_device_proxy::{
    mcp::DeviceMcp,
    transport::{ActivatedUnixDeviceTransport, LifecycleEvent, TransportError},
};
use clap::{Parser, ValueEnum};
use rmcp::ServiceExt;
use serde::{Deserialize, Serialize};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{UnixListener, UnixStream},
    time::sleep,
};

const MAX_HOOK_INPUT_BYTES: u64 = 64 * 1024;
const MAX_LOCAL_FRAME_BYTES: usize = 1024;

#[derive(Debug, Clone, Copy, ValueEnum)]
enum NotifyEvent {
    TurnStop,
    SessionEnd,
}

impl From<NotifyEvent> for LifecycleEvent {
    fn from(value: NotifyEvent) -> Self {
        match value {
            NotifyEvent::TurnStop => Self::TurnStop,
            NotifyEvent::SessionEnd => Self::SessionEnd,
        }
    }
}

#[derive(Debug, Parser)]
#[command(name = "agent-remote-device-proxy", version)]
struct Args {
    #[arg(long)]
    managed_context: Option<PathBuf>,
    #[arg(long)]
    bridge_socket: Option<PathBuf>,
    #[arg(long)]
    lifecycle_socket: PathBuf,
    #[arg(long, value_enum)]
    notify: Option<NotifyEvent>,
}

#[derive(Debug, Deserialize)]
struct ClaudeHookInput {
    hook_event_name: String,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct LocalLifecycleRequest {
    event: LifecycleEvent,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct LocalLifecycleResponse {
    status: LocalLifecycleStatus,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum LocalLifecycleStatus {
    Success,
    Failed,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    disable_core_dumps()?;
    let args = Args::parse();
    if let Some(event) = args.notify {
        if args.managed_context.is_some() || args.bridge_socket.is_some() {
            return Err("notify mode does not accept transport paths".into());
        }
        validate_hook_input(event)?;
        notify_running_proxy(&args.lifecycle_socket, event.into()).await?;
        return Ok(());
    }

    let managed_context = args
        .managed_context
        .ok_or("managed context is required in MCP mode")?;
    let bridge_socket = args
        .bridge_socket
        .ok_or("bridge socket is required in MCP mode")?;
    let transport = Arc::new(ActivatedUnixDeviceTransport::new(
        &managed_context,
        &bridge_socket,
    ));
    let listener = bind_lifecycle_socket(&args.lifecycle_socket)?;
    let lifecycle_path = args.lifecycle_socket.clone();
    let lifecycle_transport = Arc::clone(&transport);
    let lifecycle_task = tokio::spawn(async move {
        serve_lifecycle(listener, lifecycle_transport).await;
    });
    let warmup_transport = Arc::clone(&transport);
    let warmup_task = tokio::spawn(async move {
        warm_connection(warmup_transport).await;
    });
    let server = DeviceMcp::new(transport)
        .serve(rmcp::transport::stdio())
        .await?;
    let result = server.waiting().await;
    warmup_task.abort();
    lifecycle_task.abort();
    let _ = std::fs::remove_file(lifecycle_path);
    let _ = result?;
    Ok(())
}

async fn warm_connection(transport: Arc<ActivatedUnixDeviceTransport>) {
    loop {
        match transport.ensure_connected().await {
            Ok(()) => return,
            Err(TransportError::NotActivated | TransportError::BridgeConnect(_)) => {
                sleep(std::time::Duration::from_millis(100)).await;
            }
            Err(_) => return,
        }
    }
}

fn disable_core_dumps() -> std::io::Result<()> {
    let limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    if unsafe { libc::setrlimit(libc::RLIMIT_CORE, &limit) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn validate_hook_input(event: NotifyEvent) -> Result<(), Box<dyn std::error::Error>> {
    let mut input = Vec::new();
    std::io::stdin()
        .take(MAX_HOOK_INPUT_BYTES + 1)
        .read_to_end(&mut input)?;
    if input.is_empty() || input.len() as u64 > MAX_HOOK_INPUT_BYTES {
        return Err("Claude hook input is missing or oversized".into());
    }
    validate_hook_event(event, &input)
}

fn validate_hook_event(event: NotifyEvent, input: &[u8]) -> Result<(), Box<dyn std::error::Error>> {
    let hook: ClaudeHookInput = serde_json::from_slice(input)?;
    let matches = match event {
        NotifyEvent::TurnStop => matches!(hook.hook_event_name.as_str(), "Stop" | "StopFailure"),
        NotifyEvent::SessionEnd => hook.hook_event_name == "SessionEnd",
    };
    if !matches {
        return Err("Claude hook event does not match the managed notification".into());
    }
    Ok(())
}

fn bind_lifecycle_socket(path: &Path) -> Result<UnixListener, Box<dyn std::error::Error>> {
    if !path.is_absolute()
        || path.file_name().and_then(|name| name.to_str()) != Some("lifecycle.sock")
    {
        return Err("lifecycle socket path is invalid".into());
    }
    if let Ok(metadata) = std::fs::symlink_metadata(path) {
        if !metadata.file_type().is_socket() || metadata.uid() != unsafe { libc::geteuid() } {
            return Err("lifecycle socket path is occupied by an unsafe entry".into());
        }
        std::fs::remove_file(path)?;
    }
    let listener = UnixListener::bind(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

async fn serve_lifecycle(listener: UnixListener, transport: Arc<ActivatedUnixDeviceTransport>) {
    while let Ok((stream, _)) = listener.accept().await {
        let transport = Arc::clone(&transport);
        tokio::spawn(async move {
            let _ = handle_lifecycle(stream, transport).await;
        });
    }
}

async fn handle_lifecycle(
    mut stream: UnixStream,
    transport: Arc<ActivatedUnixDeviceTransport>,
) -> Result<(), Box<dyn std::error::Error>> {
    let request: LocalLifecycleRequest = read_local_frame(&mut stream).await?;
    let status = if transport.notify_lifecycle(request.event).await.is_ok() {
        LocalLifecycleStatus::Success
    } else {
        LocalLifecycleStatus::Failed
    };
    write_local_frame(&mut stream, &LocalLifecycleResponse { status }).await?;
    Ok(())
}

async fn notify_running_proxy(
    path: &Path,
    event: LifecycleEvent,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut stream = UnixStream::connect(path).await?;
    write_local_frame(&mut stream, &LocalLifecycleRequest { event }).await?;
    let response: LocalLifecycleResponse = read_local_frame(&mut stream).await?;
    if !matches!(response.status, LocalLifecycleStatus::Success) {
        return Err("managed lifecycle notification failed".into());
    }
    Ok(())
}

async fn read_local_frame<T: for<'de> Deserialize<'de>>(
    stream: &mut UnixStream,
) -> Result<T, Box<dyn std::error::Error>> {
    let length = stream.read_u32().await? as usize;
    if length == 0 || length > MAX_LOCAL_FRAME_BYTES {
        return Err("local lifecycle frame is invalid".into());
    }
    let mut payload = vec![0_u8; length];
    stream.read_exact(&mut payload).await?;
    Ok(serde_json::from_slice(&payload)?)
}

async fn write_local_frame<T: Serialize>(
    stream: &mut UnixStream,
    value: &T,
) -> Result<(), Box<dyn std::error::Error>> {
    let payload = serde_json::to_vec(value)?;
    if payload.is_empty() || payload.len() > MAX_LOCAL_FRAME_BYTES {
        return Err("local lifecycle frame is invalid".into());
    }
    stream.write_u32(payload.len() as u32).await?;
    stream.write_all(&payload).await?;
    stream.flush().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;

    #[test]
    fn hook_event_must_match_the_fixed_notification() {
        assert!(validate_hook_event(
            NotifyEvent::TurnStop,
            br#"{"hook_event_name":"Stop","untrusted":"ignored"}"#,
        )
        .is_ok());
        assert!(
            validate_hook_event(NotifyEvent::SessionEnd, br#"{"hook_event_name":"Stop"}"#,)
                .is_err()
        );
        assert!(validate_hook_event(
            NotifyEvent::TurnStop,
            br#"{"hook_event_name":"StopFailure"}"#,
        )
        .is_ok());
    }

    #[tokio::test]
    async fn notifier_uses_one_bounded_strict_local_frame() {
        let directory = tempdir().expect("temporary directory");
        let socket_path = directory.path().join("lifecycle.sock");
        let listener = UnixListener::bind(&socket_path).expect("bind lifecycle socket");
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.expect("accept notifier");
            let request: LocalLifecycleRequest = read_local_frame(&mut stream)
                .await
                .expect("read notification");
            assert_eq!(request.event, LifecycleEvent::SessionEnd);
            write_local_frame(
                &mut stream,
                &LocalLifecycleResponse {
                    status: LocalLifecycleStatus::Success,
                },
            )
            .await
            .expect("write notification response");
        });

        notify_running_proxy(&socket_path, LifecycleEvent::SessionEnd)
            .await
            .expect("notify running proxy");
        server.await.expect("notifier server");
    }

    #[test]
    fn lifecycle_socket_refuses_non_socket_entries() {
        let directory = tempdir().expect("temporary directory");
        let socket_path = directory.path().join("lifecycle.sock");
        std::fs::write(&socket_path, b"occupied").expect("write occupied path");
        assert!(bind_lifecycle_socket(&socket_path).is_err());
    }
}
