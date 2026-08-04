use std::{
    fs::OpenOptions,
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::Path,
    sync::Arc,
    time::Duration,
};

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::UnixStream,
    sync::Mutex,
    time::{sleep, timeout, Instant},
};
use tokio_rustls::{client::TlsStream, TlsConnector};
use uuid::Uuid;

use crate::{
    nested_tls::{
        client_config, confirmation_record, exporter_binding, verify_peer_confirmation,
        GenerationIdentity, GenerationMaterial, NestedTlsError, NestedTlsRole,
        CONFIRMATION_RECORD_BYTES,
    },
    protocol::{
        Action, ActionRequest, Platform, RequestContext, MAX_ACTIVE_DEVICE_SESSION_GENERATION,
        MAX_FRAME_BYTES,
    },
};

const MAX_CONTEXT_BYTES: u64 = 16 * 1024;
const MAX_BRIDGE_CONTROL_BYTES: usize = 4096;
const BRIDGE_PROTOCOL_VERSION: u8 = 1;
const MAX_ACTION_RESPONSE_WAIT: Duration = Duration::from_secs(30);
const LIFECYCLE_RESPONSE_WAIT: Duration = Duration::from_secs(15);
const CONTEXT_READY_WAIT: Duration = Duration::from_secs(10);
const CONTEXT_RETRY_INTERVAL: Duration = Duration::from_millis(100);

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ManagedContext {
    pub user_id: Uuid,
    pub device_id: Uuid,
    pub tool_session_id: Uuid,
    pub device_session_id: Uuid,
    pub node_id: Uuid,
    pub platform: Platform,
    pub generation: u64,
    pub next_sequence: u64,
    pub current_screenshot_generation: u64,
    pub lease_until: DateTime<Utc>,
}

impl ManagedContext {
    pub fn load(path: &Path) -> Result<Self, TransportError> {
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
            .map_err(|source| TransportError::ContextIo {
                operation: "open",
                source,
            })?;
        let metadata = file
            .metadata()
            .map_err(|source| TransportError::ContextIo {
                operation: "metadata inspection",
                source,
            })?;
        if !metadata.file_type().is_file()
            || metadata.len() > MAX_CONTEXT_BYTES
            || metadata.mode() & 0o077 != 0
            || metadata.uid() != unsafe { libc::geteuid() }
        {
            return Err(TransportError::UnsafeContextFile);
        }
        let mut bytes = Vec::with_capacity(metadata.len() as usize);
        file.take(MAX_CONTEXT_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|source| TransportError::ContextIo {
                operation: "read",
                source,
            })?;
        if bytes.len() as u64 > MAX_CONTEXT_BYTES {
            return Err(TransportError::UnsafeContextFile);
        }
        let context: Self = serde_json::from_slice(&bytes)?;
        if context.generation == 0
            || context.generation > MAX_ACTIVE_DEVICE_SESSION_GENERATION
            || context.next_sequence == 0
            || context.platform != Platform::Macos
        {
            return Err(TransportError::InvalidContext);
        }
        Ok(context)
    }

    fn same_binding_and_generation(&self, other: &Self) -> bool {
        self.user_id == other.user_id
            && self.device_id == other.device_id
            && self.tool_session_id == other.tool_session_id
            && self.device_session_id == other.device_session_id
            && self.node_id == other.node_id
            && self.platform == other.platform
            && self.generation == other.generation
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceResult {
    pub message: String,
    pub screenshot: Option<Screenshot>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Screenshot {
    pub base64_data: String,
    pub mime_type: String,
}

#[async_trait]
pub trait DeviceTransport: Send + Sync + 'static {
    async fn execute(&self, action: Action) -> Result<DeviceResult, TransportError>;
}

#[derive(Debug)]
pub struct UnixDeviceTransport {
    socket_path: Arc<Path>,
    state: Mutex<TransportState>,
}

#[derive(Debug)]
pub struct ActivatedUnixDeviceTransport {
    managed_context_path: Arc<Path>,
    bridge_socket_path: Arc<Path>,
    active: Mutex<Option<(ManagedContext, Arc<UnixDeviceTransport>)>>,
}

#[derive(Debug)]
struct TransportState {
    context: ManagedContext,
    poisoned: bool,
    connection: Option<TlsStream<UnixStream>>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct BridgeHello {
    protocol_version: u8,
    user_id: Uuid,
    device_id: Uuid,
    tool_session_id: Uuid,
    device_session_id: Uuid,
    node_id: Uuid,
    platform: Platform,
    generation: u64,
    spki_sha256: String,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct BridgeMaterial {
    protocol_version: u8,
    generation: u64,
    peer_spki_sha256: String,
    exporter_context: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ActionResponse {
    request_id: Uuid,
    monotonic_sequence: u64,
    screenshot_generation: u64,
    status: ResponseStatus,
    message: String,
    image: Option<ImagePayload>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ResponseStatus {
    Success,
    Failed,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ImagePayload {
    base64_data: String,
    mime_type: String,
}

#[derive(Debug, Serialize)]
struct FramedRequest<'a> {
    request: &'a ActionRequest,
}

/// Trusted Claude lifecycle events forwarded over the authenticated device channel.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LifecycleEvent {
    TurnStop,
    SessionEnd,
}

#[derive(Debug, Serialize)]
struct LifecycleContext {
    user_id: Uuid,
    device_id: Uuid,
    tool_session_id: Uuid,
    device_session_id: Uuid,
    node_id: Uuid,
    platform: Platform,
    generation: u64,
}

#[derive(Debug, Serialize)]
struct LifecycleRequest {
    version: u8,
    request_id: Uuid,
    context: LifecycleContext,
    event: LifecycleEvent,
}

#[derive(Debug, Serialize)]
struct FramedLifecycle<'a> {
    lifecycle: &'a LifecycleRequest,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct LifecycleResponse {
    request_id: Uuid,
    status: ResponseStatus,
}

#[derive(Debug, Error)]
pub enum TransportError {
    #[error("managed context file is not owner-only regular data")]
    UnsafeContextFile,
    #[error("managed device control is not active")]
    NotActivated,
    #[error("managed context is invalid")]
    InvalidContext,
    #[error("managed context binding changed within a generation")]
    ContextBinding,
    #[error("device transport is stopped after a prior failure")]
    Poisoned,
    #[error("device response does not match the request binding")]
    ResponseBinding,
    #[error("device rejected the action: {0}")]
    DeviceRejected(String),
    #[error("device frame exceeds the protocol limit")]
    FrameTooLarge,
    #[error("device session lease has expired")]
    LeaseExpired,
    #[error("device transport operation timed out")]
    OperationTimedOut,
    #[error("device transport counter is exhausted")]
    CounterExhausted,
    #[error("managed context {operation} failed: {source}")]
    ContextIo {
        operation: &'static str,
        #[source]
        source: std::io::Error,
    },
    #[error("local device bridge connection failed: {0}")]
    BridgeConnect(#[source] std::io::Error),
    #[error("local device bridge handshake {operation} failed: {source}")]
    BridgeHandshakeIo {
        operation: &'static str,
        #[source]
        source: std::io::Error,
    },
    #[error("nested TLS handshake failed: {0}")]
    TlsHandshakeIo(#[source] std::io::Error),
    #[error("encrypted device channel {operation} failed: {source}")]
    ChannelIo {
        operation: &'static str,
        #[source]
        source: std::io::Error,
    },
    #[error("managed context JSON is invalid: {0}")]
    Json(#[from] serde_json::Error),
    #[error("nested TLS setup or verification failed: {0}")]
    NestedTls(#[from] NestedTlsError),
}

impl UnixDeviceTransport {
    pub fn new(socket_path: &Path, context: ManagedContext) -> Self {
        Self {
            socket_path: Arc::from(socket_path),
            state: Mutex::new(TransportState {
                context,
                poisoned: false,
                connection: None,
            }),
        }
    }

    async fn ensure_connected(&self) -> Result<(), TransportError> {
        let mut state = self.state.lock().await;
        if state.poisoned {
            return Err(TransportError::Poisoned);
        }
        if state.context.lease_until <= Utc::now() {
            poison(&mut state);
            return Err(TransportError::LeaseExpired);
        }
        if state.connection.is_none() {
            state.connection = Some(establish_nested_tls(&self.socket_path, &state.context).await?);
        }
        Ok(())
    }

    async fn exchange(
        &self,
        state: &mut TransportState,
        request: &ActionRequest,
    ) -> Result<ActionResponse, TransportError> {
        let payload = serde_json::to_vec(&FramedRequest { request })?;
        let response_bytes = exchange_payload(&self.socket_path, state, &payload).await?;
        Ok(serde_json::from_slice(&response_bytes)?)
    }

    async fn notify_lifecycle(&self, event: LifecycleEvent) -> Result<(), TransportError> {
        let mut state = self.state.lock().await;
        if state.poisoned {
            return Err(TransportError::Poisoned);
        }
        let request = LifecycleRequest {
            version: 1,
            request_id: Uuid::new_v4(),
            context: LifecycleContext {
                user_id: state.context.user_id,
                device_id: state.context.device_id,
                tool_session_id: state.context.tool_session_id,
                device_session_id: state.context.device_session_id,
                node_id: state.context.node_id,
                platform: state.context.platform,
                generation: state.context.generation,
            },
            event,
        };
        let payload = serde_json::to_vec(&FramedLifecycle {
            lifecycle: &request,
        })?;
        let response = match timeout(
            LIFECYCLE_RESPONSE_WAIT,
            exchange_payload(&self.socket_path, &mut state, &payload),
        )
        .await
        {
            Ok(Ok(response)) => match serde_json::from_slice::<LifecycleResponse>(&response) {
                Ok(response) => response,
                Err(error) => {
                    poison(&mut state);
                    return Err(error.into());
                }
            },
            Ok(Err(error)) => {
                poison(&mut state);
                return Err(error);
            }
            Err(_) => {
                poison(&mut state);
                return Err(TransportError::OperationTimedOut);
            }
        };
        if response.request_id != request.request_id
            || !matches!(response.status, ResponseStatus::Success)
        {
            poison(&mut state);
            return Err(TransportError::ResponseBinding);
        }
        if matches!(event, LifecycleEvent::SessionEnd) {
            poison(&mut state);
        }
        Ok(())
    }

    async fn refresh_lease(&self, context: &ManagedContext) -> Result<(), TransportError> {
        let mut state = self.state.lock().await;
        if !state.context.same_binding_and_generation(context) {
            return Err(TransportError::ContextBinding);
        }
        if context.lease_until < state.context.lease_until {
            return Err(TransportError::InvalidContext);
        }
        state.context.lease_until = context.lease_until;
        Ok(())
    }
}

impl ActivatedUnixDeviceTransport {
    pub fn new(managed_context_path: &Path, bridge_socket_path: &Path) -> Self {
        Self {
            managed_context_path: Arc::from(managed_context_path),
            bridge_socket_path: Arc::from(bridge_socket_path),
            active: Mutex::new(None),
        }
    }

    /// Forwards one lifecycle event using the active generation binding.
    pub async fn notify_lifecycle(&self, event: LifecycleEvent) -> Result<(), TransportError> {
        let context = load_managed_context(&self.managed_context_path, CONTEXT_READY_WAIT).await?;
        let transport = self.transport_for_context(context).await?;
        transport.notify_lifecycle(event).await
    }

    /// Establishes the generation-bound relay before the first MCP action arrives.
    pub async fn ensure_connected(&self) -> Result<(), TransportError> {
        let context = load_managed_context(&self.managed_context_path, CONTEXT_READY_WAIT).await?;
        let transport = self.transport_for_context(context).await?;
        transport.ensure_connected().await
    }

    async fn transport_for_context(
        &self,
        context: ManagedContext,
    ) -> Result<Arc<UnixDeviceTransport>, TransportError> {
        let mut active = self.active.lock().await;
        if let Some((current, transport)) = active.as_mut() {
            if current.device_session_id == context.device_session_id {
                if current.generation > context.generation {
                    return Err(TransportError::InvalidContext);
                }
                if current.generation == context.generation {
                    if !current.same_binding_and_generation(&context) {
                        return Err(TransportError::ContextBinding);
                    }
                    transport.refresh_lease(&context).await?;
                    current.lease_until = context.lease_until;
                    return Ok(Arc::clone(transport));
                }
            }
        }
        let transport = Arc::new(UnixDeviceTransport::new(
            &self.bridge_socket_path,
            context.clone(),
        ));
        *active = Some((context, Arc::clone(&transport)));
        Ok(transport)
    }
}

async fn load_managed_context(
    path: &Path,
    wait: Duration,
) -> Result<ManagedContext, TransportError> {
    let deadline = Instant::now() + wait;
    loop {
        match ManagedContext::load(path) {
            Err(TransportError::ContextIo { source, .. })
                if source.kind() == std::io::ErrorKind::NotFound =>
            {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return Err(TransportError::NotActivated);
                }
                sleep(CONTEXT_RETRY_INTERVAL.min(remaining)).await;
            }
            result => return result,
        }
    }
}

async fn exchange_payload(
    socket_path: &Path,
    state: &mut TransportState,
    payload: &[u8],
) -> Result<Vec<u8>, TransportError> {
    if payload.is_empty() || payload.len() > MAX_FRAME_BYTES {
        return Err(TransportError::FrameTooLarge);
    }
    if state.connection.is_none() {
        state.connection = Some(establish_nested_tls(socket_path, &state.context).await?);
    }
    let stream = state
        .connection
        .as_mut()
        .ok_or(TransportError::InvalidContext)?;
    stream
        .write_u32(payload.len() as u32)
        .await
        .map_err(|source| TransportError::ChannelIo {
            operation: "write length",
            source,
        })?;
    stream
        .write_all(payload)
        .await
        .map_err(|source| TransportError::ChannelIo {
            operation: "write payload",
            source,
        })?;
    stream
        .flush()
        .await
        .map_err(|source| TransportError::ChannelIo {
            operation: "flush request",
            source,
        })?;
    let response_length = stream
        .read_u32()
        .await
        .map_err(|source| TransportError::ChannelIo {
            operation: "read response length",
            source,
        })? as usize;
    if response_length == 0 || response_length > MAX_FRAME_BYTES {
        return Err(TransportError::FrameTooLarge);
    }
    let mut response = vec![0; response_length];
    stream
        .read_exact(&mut response)
        .await
        .map_err(|source| TransportError::ChannelIo {
            operation: "read response payload",
            source,
        })?;
    Ok(response)
}

#[async_trait]
impl DeviceTransport for ActivatedUnixDeviceTransport {
    async fn execute(&self, action: Action) -> Result<DeviceResult, TransportError> {
        let context = load_managed_context(&self.managed_context_path, CONTEXT_READY_WAIT).await?;
        let transport = self.transport_for_context(context).await?;
        transport.execute(action).await
    }
}

#[async_trait]
impl DeviceTransport for UnixDeviceTransport {
    async fn execute(&self, action: Action) -> Result<DeviceResult, TransportError> {
        let mut state = self.state.lock().await;
        if state.poisoned {
            return Err(TransportError::Poisoned);
        }
        if state.context.lease_until <= Utc::now() {
            poison(&mut state);
            return Err(TransportError::LeaseExpired);
        }
        if state.context.next_sequence == u64::MAX
            || state.context.current_screenshot_generation == u64::MAX
        {
            poison(&mut state);
            return Err(TransportError::CounterExhausted);
        }
        let request = ActionRequest {
            version: 1,
            request_id: Uuid::new_v4(),
            context: RequestContext {
                user_id: state.context.user_id,
                device_id: state.context.device_id,
                tool_session_id: state.context.tool_session_id,
                device_session_id: state.context.device_session_id,
                node_id: state.context.node_id,
                platform: state.context.platform,
                generation: state.context.generation,
                monotonic_sequence: state.context.next_sequence,
                current_screenshot_generation: state.context.current_screenshot_generation,
            },
            lease_until: state.context.lease_until,
            action,
        };
        let remaining_lease = match (state.context.lease_until - Utc::now()).to_std() {
            Ok(remaining) => remaining,
            Err(_) => {
                poison(&mut state);
                return Err(TransportError::LeaseExpired);
            }
        };
        let response = match timeout(
            remaining_lease.min(MAX_ACTION_RESPONSE_WAIT),
            self.exchange(&mut state, &request),
        )
        .await
        {
            Ok(Ok(response)) => response,
            Ok(Err(error)) => {
                poison(&mut state);
                return Err(error);
            }
            Err(_) => {
                poison(&mut state);
                return Err(TransportError::OperationTimedOut);
            }
        };
        if response.request_id != request.request_id
            || response.monotonic_sequence != request.context.monotonic_sequence
            || response.screenshot_generation < request.context.current_screenshot_generation
        {
            poison(&mut state);
            return Err(TransportError::ResponseBinding);
        }
        if matches!(response.status, ResponseStatus::Failed) {
            return Err(TransportError::DeviceRejected(response.message));
        }
        state.context.next_sequence += 1;
        state.context.current_screenshot_generation = response.screenshot_generation;
        let screenshot = response.image.map(|image| Screenshot {
            base64_data: image.base64_data,
            mime_type: image.mime_type,
        });
        Ok(DeviceResult {
            message: response.message,
            screenshot,
        })
    }
}

fn poison(state: &mut TransportState) {
    state.poisoned = true;
    state.connection = None;
}

async fn establish_nested_tls(
    socket_path: &Path,
    context: &ManagedContext,
) -> Result<TlsStream<UnixStream>, TransportError> {
    let mut stream = UnixStream::connect(socket_path)
        .await
        .map_err(TransportError::BridgeConnect)?;
    let identity = GenerationIdentity::generate()?;
    write_bridge_control(
        &mut stream,
        &BridgeHello {
            protocol_version: BRIDGE_PROTOCOL_VERSION,
            user_id: context.user_id,
            device_id: context.device_id,
            tool_session_id: context.tool_session_id,
            device_session_id: context.device_session_id,
            node_id: context.node_id,
            platform: context.platform,
            generation: context.generation,
            spki_sha256: identity.spki_sha256_hex(),
        },
    )
    .await?;
    let bridge_material: BridgeMaterial = read_bridge_control(&mut stream).await?;
    if bridge_material.protocol_version != BRIDGE_PROTOCOL_VERSION
        || bridge_material.generation != context.generation
    {
        return Err(TransportError::InvalidContext);
    }
    let material = GenerationMaterial::from_hex(
        bridge_material.generation,
        &bridge_material.peer_spki_sha256,
        &bridge_material.exporter_context,
    )?;
    let connector = TlsConnector::from(Arc::new(client_config(&identity, &material)?));
    let server_name = rustls::pki_types::ServerName::try_from("agent-remote-device.invalid")
        .map_err(NestedTlsError::ServerName)?
        .to_owned();
    let mut tls = connector
        .connect(server_name, stream)
        .await
        .map_err(TransportError::TlsHandshakeIo)?;
    let exporter = exporter_binding(tls.get_ref().1, &material)?;
    let local_confirmation = confirmation_record(
        &exporter,
        NestedTlsRole::Proxy,
        context.generation,
        context.device_session_id,
    );
    tls.write_all(&local_confirmation)
        .await
        .map_err(|source| TransportError::ChannelIo {
            operation: "write TLS confirmation",
            source,
        })?;
    tls.flush()
        .await
        .map_err(|source| TransportError::ChannelIo {
            operation: "flush TLS confirmation",
            source,
        })?;
    let mut peer_confirmation = [0_u8; CONFIRMATION_RECORD_BYTES];
    tls.read_exact(&mut peer_confirmation)
        .await
        .map_err(|source| TransportError::ChannelIo {
            operation: "read TLS confirmation",
            source,
        })?;
    verify_peer_confirmation(
        &peer_confirmation,
        &exporter,
        NestedTlsRole::Proxy,
        context.generation,
        context.device_session_id,
    )?;
    Ok(tls)
}

async fn write_bridge_control<T: Serialize>(
    stream: &mut UnixStream,
    value: &T,
) -> Result<(), TransportError> {
    let payload = serde_json::to_vec(value)?;
    if payload.is_empty() || payload.len() > MAX_BRIDGE_CONTROL_BYTES {
        return Err(TransportError::FrameTooLarge);
    }
    stream
        .write_u32(payload.len() as u32)
        .await
        .map_err(|source| TransportError::BridgeHandshakeIo {
            operation: "write length",
            source,
        })?;
    stream
        .write_all(&payload)
        .await
        .map_err(|source| TransportError::BridgeHandshakeIo {
            operation: "write payload",
            source,
        })?;
    stream
        .flush()
        .await
        .map_err(|source| TransportError::BridgeHandshakeIo {
            operation: "flush request",
            source,
        })?;
    Ok(())
}

async fn read_bridge_control<T: for<'de> Deserialize<'de>>(
    stream: &mut UnixStream,
) -> Result<T, TransportError> {
    let length = stream
        .read_u32()
        .await
        .map_err(|source| TransportError::BridgeHandshakeIo {
            operation: "read response length",
            source,
        })? as usize;
    if length == 0 || length > MAX_BRIDGE_CONTROL_BYTES {
        return Err(TransportError::FrameTooLarge);
    }
    let mut payload = vec![0_u8; length];
    stream
        .read_exact(&mut payload)
        .await
        .map_err(|source| TransportError::BridgeHandshakeIo {
            operation: "read response payload",
            source,
        })?;
    Ok(serde_json::from_slice(&payload)?)
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use tempfile::tempdir;
    use tokio::net::UnixListener;
    use tokio_rustls::TlsAcceptor;

    use super::*;
    use crate::nested_tls::{
        server_config, server_exporter_binding, GenerationIdentity, GenerationMaterial,
    };

    #[test]
    fn managed_context_rejects_group_readable_file() {
        let directory = tempdir().expect("temp directory");
        let path = directory.path().join("context.json");
        std::fs::write(&path, b"{}").expect("write context");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640))
            .expect("set permissions");
        assert!(matches!(
            ManagedContext::load(&path),
            Err(TransportError::UnsafeContextFile)
        ));
    }

    #[test]
    fn managed_context_rejects_symlinks() {
        use std::os::unix::fs::symlink;

        let directory = tempdir().expect("temp directory");
        let target = directory.path().join("target.json");
        let link = directory.path().join("context.json");
        std::fs::write(&target, b"{}").expect("write context target");
        std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o600))
            .expect("set target permissions");
        symlink(&target, &link).expect("create context symlink");

        assert!(ManagedContext::load(&link).is_err());
    }

    #[tokio::test]
    async fn activated_transport_remains_discoverable_before_context_exists() {
        let directory = tempdir().expect("temp directory");
        let path = directory.path().join("missing-context.json");

        assert!(matches!(
            load_managed_context(&path, Duration::ZERO).await,
            Err(TransportError::NotActivated)
        ));
    }

    #[tokio::test]
    async fn activated_transport_waits_for_context_creation() {
        let directory = tempdir().expect("temp directory");
        let path = directory.path().join("context.json");
        let context = test_context(1, Utc::now() + chrono::Duration::seconds(30));
        let writer_path = path.clone();
        let writer_context = context.clone();
        let writer = tokio::spawn(async move {
            sleep(Duration::from_millis(25)).await;
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&writer_path)
                .expect("create context");
            serde_json::to_writer(&mut file, &writer_context).expect("write context");
        });

        let loaded = load_managed_context(&path, Duration::from_secs(1))
            .await
            .expect("context should become available");
        assert_eq!(loaded, context);
        writer.await.expect("context writer");
    }

    #[tokio::test]
    async fn activated_transport_renews_without_resetting_action_state() {
        let directory = tempdir().expect("temp directory");
        let activated = ActivatedUnixDeviceTransport::new(
            &directory.path().join("context.json"),
            &directory.path().join("bridge.sock"),
        );
        let initial = test_context(1, Utc::now() + chrono::Duration::seconds(30));
        let transport = activated
            .transport_for_context(initial.clone())
            .await
            .expect("initial transport");
        {
            let mut state = transport.state.lock().await;
            state.context.next_sequence = 8;
            state.context.current_screenshot_generation = 4;
        }

        let mut renewed = initial;
        renewed.lease_until += chrono::Duration::seconds(30);
        let reused = activated
            .transport_for_context(renewed.clone())
            .await
            .expect("renewed transport");
        assert!(Arc::ptr_eq(&transport, &reused));
        let state = reused.state.lock().await;
        assert_eq!(state.context.next_sequence, 8);
        assert_eq!(state.context.current_screenshot_generation, 4);
        assert_eq!(state.context.lease_until, renewed.lease_until);
    }

    #[tokio::test]
    async fn activated_transport_rejects_same_generation_binding_changes() {
        let directory = tempdir().expect("temp directory");
        let activated = ActivatedUnixDeviceTransport::new(
            &directory.path().join("context.json"),
            &directory.path().join("bridge.sock"),
        );
        let context = test_context(1, Utc::now() + chrono::Duration::seconds(30));
        activated
            .transport_for_context(context.clone())
            .await
            .expect("initial transport");
        let mut changed = context;
        changed.device_id = Uuid::new_v4();
        assert!(matches!(
            activated.transport_for_context(changed).await,
            Err(TransportError::ContextBinding)
        ));
    }

    #[tokio::test]
    async fn activated_transport_replaces_a_rebound_device_session() {
        let directory = tempdir().expect("temp directory");
        let activated = ActivatedUnixDeviceTransport::new(
            &directory.path().join("context.json"),
            &directory.path().join("bridge.sock"),
        );
        let initial = test_context(7, Utc::now() + chrono::Duration::seconds(30));
        let old_transport = activated
            .transport_for_context(initial.clone())
            .await
            .expect("initial transport");
        {
            let mut state = old_transport.state.lock().await;
            state.context.next_sequence = 8;
            state.context.current_screenshot_generation = 4;
        }

        let rebound = ManagedContext {
            device_id: Uuid::new_v4(),
            device_session_id: Uuid::new_v4(),
            generation: 1,
            next_sequence: 1,
            current_screenshot_generation: 0,
            ..initial
        };
        let new_transport = activated
            .transport_for_context(rebound.clone())
            .await
            .expect("rebound transport");

        assert!(!Arc::ptr_eq(&old_transport, &new_transport));
        let state = new_transport.state.lock().await;
        assert_eq!(state.context, rebound);
        assert_eq!(state.context.next_sequence, 1);
        assert_eq!(state.context.current_screenshot_generation, 0);
    }

    #[test]
    fn managed_context_io_reports_the_failed_operation() {
        let directory = tempdir().expect("temp directory");
        let error = ManagedContext::load(&directory.path().join("missing.json"))
            .expect_err("missing context must fail");

        assert!(matches!(
            &error,
            TransportError::ContextIo {
                operation: "open",
                ..
            }
        ));
        let message = error.to_string();
        assert!(message.starts_with("managed context open failed: "));
        assert!(message.contains("No such file") || message.contains("not found"));
    }

    #[test]
    fn rejected_device_action_preserves_the_concrete_reason() {
        let error = TransportError::DeviceRejected(
            "screen_recording_permission_missing: grant access in System Settings".to_owned(),
        );

        assert_eq!(
            error.to_string(),
            "device rejected the action: screen_recording_permission_missing: grant access in System Settings"
        );
    }

    #[tokio::test]
    async fn bridge_connection_error_is_not_reported_as_context_io() {
        let directory = tempdir().expect("temp directory");
        let transport = UnixDeviceTransport::new(
            &directory.path().join("missing-bridge.sock"),
            test_context(1, Utc::now() + chrono::Duration::seconds(30)),
        );
        let error = transport
            .ensure_connected()
            .await
            .expect_err("missing bridge must fail");

        assert!(matches!(&error, TransportError::BridgeConnect(_)));
        assert!(error
            .to_string()
            .starts_with("local device bridge connection failed: "));
    }

    #[test]
    fn managed_context_rejects_terminal_only_generation() {
        use std::os::unix::fs::PermissionsExt;

        let directory = tempdir().expect("temp directory");
        let path = directory.path().join("context.json");
        let context = test_context(i64::MAX as u64, Utc::now() + chrono::Duration::seconds(30));
        std::fs::write(
            &path,
            serde_json::to_vec(&context).expect("serialize context"),
        )
        .expect("write context");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .expect("set permissions");

        assert!(matches!(
            ManagedContext::load(&path),
            Err(TransportError::InvalidContext)
        ));
    }

    #[tokio::test]
    async fn action_wait_is_bounded_by_the_remaining_lease() {
        let directory = tempdir().expect("temp directory");
        let socket_path = directory.path().join("bridge.sock");
        let listener = UnixListener::bind(&socket_path).expect("bind bridge socket");
        let server = tokio::spawn(async move {
            let (_stream, _) = listener.accept().await.expect("accept proxy");
            tokio::time::sleep(Duration::from_secs(1)).await;
        });
        let transport = UnixDeviceTransport::new(
            &socket_path,
            test_context(1, Utc::now() + chrono::Duration::milliseconds(250)),
        );

        assert!(matches!(
            transport.execute(Action::Screenshot).await,
            Err(TransportError::OperationTimedOut)
        ));
        let state = transport.state.lock().await;
        assert!(state.poisoned);
        assert!(state.connection.is_none());
        drop(state);
        server.abort();
    }

    #[tokio::test]
    async fn exhausted_counters_fail_before_opening_the_bridge() {
        for context in [
            ManagedContext {
                next_sequence: u64::MAX,
                ..test_context(1, Utc::now() + chrono::Duration::seconds(30))
            },
            ManagedContext {
                current_screenshot_generation: u64::MAX,
                ..test_context(1, Utc::now() + chrono::Duration::seconds(30))
            },
        ] {
            let directory = tempdir().expect("temp directory");
            let transport =
                UnixDeviceTransport::new(&directory.path().join("missing.sock"), context);

            assert!(matches!(
                transport.execute(Action::Screenshot).await,
                Err(TransportError::CounterExhausted)
            ));
            let state = transport.state.lock().await;
            assert!(state.poisoned);
            assert!(state.connection.is_none());
        }
    }

    #[tokio::test]
    async fn unix_transport_sends_actions_only_after_nested_tls_confirmation() {
        let directory = tempdir().expect("temp directory");
        let socket_path = directory.path().join("bridge.sock");
        let listener = UnixListener::bind(&socket_path).expect("bind bridge");
        let context = test_context(3, Utc::now() + chrono::Duration::seconds(60));
        let server_context = context.clone();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.expect("accept proxy");
            let hello: BridgeHello = read_bridge_control(&mut stream)
                .await
                .expect("bridge hello");
            assert_eq!(hello.device_session_id, server_context.device_session_id);
            assert_eq!(hello.generation, server_context.generation);
            let identity = GenerationIdentity::generate().expect("device identity");
            let exporter_context = hex::encode([0x5a_u8; 32]);
            write_bridge_control(
                &mut stream,
                &BridgeMaterial {
                    protocol_version: BRIDGE_PROTOCOL_VERSION,
                    generation: server_context.generation,
                    peer_spki_sha256: identity.spki_sha256_hex(),
                    exporter_context: exporter_context.clone(),
                },
            )
            .await
            .expect("bridge material");
            let material = GenerationMaterial::from_hex(
                server_context.generation,
                &hello.spki_sha256,
                &exporter_context,
            )
            .expect("generation material");
            let acceptor = TlsAcceptor::from(Arc::new(
                server_config(&identity, &material).expect("server config"),
            ));
            let mut tls = acceptor.accept(stream).await.expect("nested TLS handshake");
            let exporter =
                server_exporter_binding(tls.get_ref().1, &material).expect("server exporter");
            let confirmation = confirmation_record(
                &exporter,
                NestedTlsRole::Device,
                server_context.generation,
                server_context.device_session_id,
            );
            tls.write_all(&confirmation)
                .await
                .expect("device confirmation");
            tls.flush().await.expect("flush confirmation");
            let mut peer_confirmation = [0_u8; CONFIRMATION_RECORD_BYTES];
            tls.read_exact(&mut peer_confirmation)
                .await
                .expect("proxy confirmation");
            verify_peer_confirmation(
                &peer_confirmation,
                &exporter,
                NestedTlsRole::Device,
                server_context.generation,
                server_context.device_session_id,
            )
            .expect("verify proxy confirmation");

            let request_length = tls.read_u32().await.expect("request length") as usize;
            let mut request_bytes = vec![0_u8; request_length];
            tls.read_exact(&mut request_bytes)
                .await
                .expect("request bytes");
            let request: serde_json::Value =
                serde_json::from_slice(&request_bytes).expect("request JSON");
            let request = &request["request"];
            let response = serde_json::json!({
                "request_id": request["request_id"],
                "monotonic_sequence": request["context"]["monotonic_sequence"],
                "screenshot_generation": 0,
                "status": "success",
                "message": "nested TLS ok",
                "image": null
            });
            let response_bytes = serde_json::to_vec(&response).expect("response JSON");
            tls.write_u32(response_bytes.len() as u32)
                .await
                .expect("response length");
            tls.write_all(&response_bytes)
                .await
                .expect("response bytes");
            tls.flush().await.expect("flush response");

            let lifecycle_length = tls.read_u32().await.expect("lifecycle length") as usize;
            let mut lifecycle_bytes = vec![0_u8; lifecycle_length];
            tls.read_exact(&mut lifecycle_bytes)
                .await
                .expect("lifecycle bytes");
            let lifecycle: serde_json::Value =
                serde_json::from_slice(&lifecycle_bytes).expect("lifecycle JSON");
            assert_eq!(lifecycle["lifecycle"]["event"], "turn_stop");
            assert_eq!(
                lifecycle["lifecycle"]["context"]["device_session_id"],
                server_context.device_session_id.to_string()
            );
            let lifecycle_response = serde_json::json!({
                "request_id": lifecycle["lifecycle"]["request_id"],
                "status": "success"
            });
            let lifecycle_response_bytes =
                serde_json::to_vec(&lifecycle_response).expect("lifecycle response JSON");
            tls.write_u32(lifecycle_response_bytes.len() as u32)
                .await
                .expect("lifecycle response length");
            tls.write_all(&lifecycle_response_bytes)
                .await
                .expect("lifecycle response bytes");
            tls.flush().await.expect("flush lifecycle response");
        });

        let transport = UnixDeviceTransport::new(&socket_path, context);
        transport
            .ensure_connected()
            .await
            .expect("nested TLS connection");
        let result = transport
            .execute(Action::Screenshot)
            .await
            .expect("nested TLS action");
        assert_eq!(result.message, "nested TLS ok");
        transport
            .notify_lifecycle(LifecycleEvent::TurnStop)
            .await
            .expect("nested TLS lifecycle");
        let state = transport.state.lock().await;
        assert_eq!(state.context.next_sequence, 2);
        assert_eq!(state.context.current_screenshot_generation, 0);
        drop(state);
        server.await.expect("bridge server");
    }

    fn test_context(generation: u64, lease_until: DateTime<Utc>) -> ManagedContext {
        ManagedContext {
            user_id: Uuid::new_v4(),
            device_id: Uuid::new_v4(),
            tool_session_id: Uuid::new_v4(),
            device_session_id: Uuid::new_v4(),
            node_id: Uuid::new_v4(),
            platform: Platform::Macos,
            generation,
            next_sequence: 1,
            current_screenshot_generation: 0,
            lease_until,
        }
    }
}
