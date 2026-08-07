use std::{
    collections::BTreeSet,
    fs::OpenOptions,
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::Path,
    sync::Arc,
    time::Duration,
};

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize};
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
    protocol_v2::{
        AccessibilityObservation, AccessibilityObservationKind, ActionRequestV2, ActionResponseV2,
        ActionV2, ImageProfile, ObservationMode, ObservationPolicy, RequestContextV2,
        ResponseStatusV2, SettleResult, CAPABILITY_ADAPTIVE_SETTLE_V2, CAPABILITY_AX_STATE_V2,
        CAPABILITY_OBSERVATION_MODE_V2, PROTOCOL_VERSION_V2,
    },
};

const MAX_CONTEXT_BYTES: u64 = 16 * 1024;
const MAX_BRIDGE_CONTROL_BYTES: usize = 4096;
const BRIDGE_PROTOCOL_VERSION: u8 = 1;
const MAX_ACTION_RESPONSE_WAIT: Duration = Duration::from_secs(30);
const LIFECYCLE_RESPONSE_WAIT: Duration = Duration::from_secs(15);
const ACTION_CONTEXT_READY_WAIT: Duration = Duration::from_secs(180);
const BACKGROUND_CONTEXT_READY_WAIT: Duration = Duration::from_secs(10);
const ACTION_LEASE_READY_WAIT: Duration = Duration::from_secs(15);
const MIN_ACTION_LEASE_REMAINING: Duration = Duration::from_secs(30);
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
    #[serde(default)]
    pub current_state_generation: u64,
    #[serde(default, deserialize_with = "deserialize_null_default")]
    pub capabilities: BTreeSet<String>,
    pub lease_until: DateTime<Utc>,
}

fn deserialize_null_default<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de> + Default,
{
    Ok(Option::<T>::deserialize(deserializer)?.unwrap_or_default())
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
            && self.capabilities == other.capabilities
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceResult {
    pub message: String,
    pub screenshot: Option<Screenshot>,
    pub retry_count: u16,
    pub manual_recovery: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceResultV2 {
    pub message: String,
    pub state_generation: u64,
    pub screenshot_generation: u64,
    pub state_id: Uuid,
    pub application_digest: String,
    pub window_id: u32,
    pub display_fingerprint: String,
    pub base_state_id: Option<Uuid>,
    pub observation: Option<AccessibilityObservation>,
    pub settle: SettleResult,
    pub screenshot: Option<ScreenshotV2>,
    pub retry_count: u16,
    pub manual_recovery: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScreenshotV2 {
    pub base64_data: String,
    pub mime_type: String,
    pub pixel_width: u16,
    pub pixel_height: u16,
    pub profile: ImageProfile,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Screenshot {
    pub base64_data: String,
    pub mime_type: String,
}

#[async_trait]
pub trait DeviceTransport: Send + Sync + 'static {
    async fn supports_v2(&self) -> Result<bool, TransportError> {
        Ok(false)
    }

    async fn execute(&self, action: Action) -> Result<DeviceResult, TransportError>;

    async fn execute_v2(
        &self,
        _action: ActionV2,
        _observation: ObservationPolicy,
    ) -> Result<DeviceResultV2, TransportError> {
        Err(TransportError::CapabilityUnavailable)
    }
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
    state_id: Option<Uuid>,
    model_ax_base_state_id: Option<Uuid>,
    model_ax_base_context: Option<(String, u32, String)>,
    poisoned: bool,
    pending_request: Option<PendingRequest>,
    last_completed_response_binding: Option<ResponseBinding>,
    connection: Option<TlsStream<UnixStream>>,
}

#[derive(Debug, Clone)]
enum PendingRequest {
    V1(ActionRequest),
    V2(ActionRequestV2),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ResponseBinding {
    request_id: Uuid,
    monotonic_sequence: u64,
}

#[derive(Debug, Deserialize)]
struct ResponseBindingEnvelope {
    request_id: Uuid,
    monotonic_sequence: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ResponseFrameKind {
    Expected,
    PreviousDuplicate,
}

#[derive(Debug)]
struct ExchangeFailure {
    error: TransportError,
    request_started: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum ExchangePhase {
    #[default]
    PreRequest,
    RequestStarted,
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

#[derive(Debug, Serialize)]
struct FramedRequestV2<'a> {
    request: &'a ActionRequestV2,
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
    #[error("the active device session does not support token-efficient observations")]
    CapabilityUnavailable,
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
                state_id: None,
                model_ax_base_state_id: None,
                model_ax_base_context: None,
                context,
                poisoned: false,
                pending_request: None,
                last_completed_response_binding: None,
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
    ) -> Result<(ActionResponse, u16), ExchangeFailure> {
        let payload =
            serde_json::to_vec(&FramedRequest { request }).map_err(|error| ExchangeFailure {
                error: error.into(),
                request_started: false,
            })?;
        let response_bytes = exchange_payload_with_replay(
            &self.socket_path,
            state,
            &payload,
            MAX_ACTION_RESPONSE_WAIT,
            ResponseBinding {
                request_id: request.request_id,
                monotonic_sequence: request.context.monotonic_sequence,
            },
        )
        .await?;
        serde_json::from_slice(&response_bytes.0)
            .map(|response| (response, response_bytes.1))
            .map_err(|error| ExchangeFailure {
                error: error.into(),
                request_started: true,
            })
    }

    async fn exchange_v2(
        &self,
        state: &mut TransportState,
        request: &ActionRequestV2,
    ) -> Result<(ActionResponseV2, u16), ExchangeFailure> {
        let payload =
            serde_json::to_vec(&FramedRequestV2 { request }).map_err(|error| ExchangeFailure {
                error: error.into(),
                request_started: false,
            })?;
        let response_bytes = exchange_payload_with_replay(
            &self.socket_path,
            state,
            &payload,
            MAX_ACTION_RESPONSE_WAIT,
            ResponseBinding {
                request_id: request.request_id,
                monotonic_sequence: request.context.monotonic_sequence,
            },
        )
        .await?;
        serde_json::from_slice(&response_bytes.0)
            .map(|response| (response, response_bytes.1))
            .map_err(|error| ExchangeFailure {
                error: error.into(),
                request_started: true,
            })
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
        let mut phase = ExchangePhase::PreRequest;
        let response = match timeout(
            LIFECYCLE_RESPONSE_WAIT,
            exchange_payload(&self.socket_path, &mut state, &payload, &mut phase),
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
                clear_failed_connection(&mut state);
                if matches!(phase, ExchangePhase::RequestStarted) {
                    poison(&mut state);
                }
                return Err(error);
            }
            Err(_) => {
                clear_failed_connection(&mut state);
                if matches!(phase, ExchangePhase::RequestStarted) {
                    poison(&mut state);
                }
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

    async fn recover_pending(&self, state: &mut TransportState) -> Result<u16, TransportError> {
        let Some(pending) = state.pending_request.clone() else {
            return Ok(0);
        };
        let (result, retries) = match &pending {
            PendingRequest::V1(request) => match self.exchange(state, request).await {
                Ok((response, retries)) => (
                    apply_response_v1(state, request, response).map(|_| ()),
                    retries,
                ),
                Err(failure) => return retain_or_fail_pending(state, failure),
            },
            PendingRequest::V2(request) => match self.exchange_v2(state, request).await {
                Ok((response, retries)) => (
                    apply_response_v2(state, request, response).map(|_| ()),
                    retries,
                ),
                Err(failure) => return retain_or_fail_pending(state, failure),
            },
        };
        match result {
            Ok(()) | Err(TransportError::DeviceRejected(_)) => {
                state.pending_request = None;
                Ok(retries.saturating_add(1))
            }
            Err(error) => {
                state.pending_request = None;
                Err(error)
            }
        }
    }
}

fn retain_or_fail_pending(
    state: &mut TransportState,
    failure: ExchangeFailure,
) -> Result<u16, TransportError> {
    clear_failed_connection(state);
    if replayable_exchange_error(&failure.error) {
        return Err(failure.error);
    }
    poison(state);
    Err(failure.error)
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
        let context = load_managed_context(&self.managed_context_path, Duration::ZERO).await?;
        let transport = self.transport_for_context(context).await?;
        transport.notify_lifecycle(event).await
    }

    /// Establishes the generation-bound relay before the first MCP action arrives.
    pub async fn ensure_connected(&self) -> Result<(), TransportError> {
        let context =
            load_managed_context(&self.managed_context_path, BACKGROUND_CONTEXT_READY_WAIT).await?;
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

async fn load_action_context(path: &Path) -> Result<ManagedContext, TransportError> {
    let mut context = load_managed_context(path, ACTION_CONTEXT_READY_WAIT).await?;
    let deadline = Instant::now() + ACTION_LEASE_READY_WAIT;
    loop {
        if action_lease_ready(&context, Utc::now()) {
            return Ok(context);
        }
        let wait = deadline.saturating_duration_since(Instant::now());
        if wait.is_zero() {
            return Err(TransportError::LeaseExpired);
        }
        sleep(CONTEXT_RETRY_INTERVAL.min(wait)).await;
        context = ManagedContext::load(path)?;
    }
}

fn action_lease_ready(context: &ManagedContext, now: DateTime<Utc>) -> bool {
    (context.lease_until - now)
        .to_std()
        .is_ok_and(|remaining| remaining >= MIN_ACTION_LEASE_REMAINING)
}

async fn exchange_payload(
    socket_path: &Path,
    state: &mut TransportState,
    payload: &[u8],
    phase: &mut ExchangePhase,
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
    *phase = ExchangePhase::RequestStarted;
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
    read_response_payload(state).await
}

async fn read_response_payload(state: &mut TransportState) -> Result<Vec<u8>, TransportError> {
    let stream = state
        .connection
        .as_mut()
        .ok_or(TransportError::InvalidContext)?;
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

async fn exchange_payload_with_replay(
    socket_path: &Path,
    state: &mut TransportState,
    payload: &[u8],
    max_attempt_wait: Duration,
    expected_binding: ResponseBinding,
) -> Result<(Vec<u8>, u16), ExchangeFailure> {
    let first_wait =
        remaining_exchange_wait(state, max_attempt_wait).map_err(|error| ExchangeFailure {
            error,
            request_started: false,
        })?;
    let mut first_phase = ExchangePhase::PreRequest;
    let first_error = match timeout(
        first_wait,
        exchange_expected_payload(
            socket_path,
            state,
            payload,
            &mut first_phase,
            expected_binding,
        ),
    )
    .await
    {
        Ok(Ok(response)) => return Ok((response, 0)),
        Ok(Err(error)) if replayable_exchange_error(&error) => error,
        Ok(Err(error)) => {
            return Err(ExchangeFailure {
                error,
                request_started: matches!(first_phase, ExchangePhase::RequestStarted),
            })
        }
        Err(_) => TransportError::OperationTimedOut,
    };

    // The request may already have executed. Reconnect and replay the exact bytes so the
    // device can return its cached response without repeating input.
    state.connection = None;
    let retry_wait = match remaining_exchange_wait(state, max_attempt_wait) {
        Ok(wait) => wait,
        Err(_) => {
            return Err(ExchangeFailure {
                error: first_error,
                request_started: matches!(first_phase, ExchangePhase::RequestStarted),
            })
        }
    };
    let mut retry_phase = ExchangePhase::PreRequest;
    let result = match timeout(
        retry_wait,
        exchange_expected_payload(
            socket_path,
            state,
            payload,
            &mut retry_phase,
            expected_binding,
        ),
    )
    .await
    {
        Ok(result) => result,
        Err(_) => Err(TransportError::OperationTimedOut),
    };
    result
        .map(|response| (response, 1))
        .map_err(|error| ExchangeFailure {
            error,
            request_started: matches!(first_phase, ExchangePhase::RequestStarted)
                || matches!(retry_phase, ExchangePhase::RequestStarted),
        })
}

async fn exchange_expected_payload(
    socket_path: &Path,
    state: &mut TransportState,
    payload: &[u8],
    phase: &mut ExchangePhase,
    expected_binding: ResponseBinding,
) -> Result<Vec<u8>, TransportError> {
    let mut response = exchange_payload(socket_path, state, payload, phase).await?;
    loop {
        let binding =
            serde_json::from_slice::<ResponseBindingEnvelope>(&response).map(|value| {
                ResponseBinding {
                    request_id: value.request_id,
                    monotonic_sequence: value.monotonic_sequence,
                }
            })?;
        match classify_response_binding(
            binding,
            expected_binding,
            state.last_completed_response_binding,
        )? {
            ResponseFrameKind::Expected => return Ok(response),
            ResponseFrameKind::PreviousDuplicate => {}
        }

        // A timed-out request can finish just as its exact replay is sent. In that
        // case the old response is still queued ahead of the current response.
        response = read_response_payload(state).await?;
    }
}

fn classify_response_binding(
    actual: ResponseBinding,
    expected: ResponseBinding,
    previous: Option<ResponseBinding>,
) -> Result<ResponseFrameKind, TransportError> {
    if actual == expected {
        return Ok(ResponseFrameKind::Expected);
    }
    if Some(actual) == previous {
        return Ok(ResponseFrameKind::PreviousDuplicate);
    }
    Err(TransportError::ResponseBinding)
}

fn remaining_exchange_wait(
    state: &TransportState,
    max_attempt_wait: Duration,
) -> Result<Duration, TransportError> {
    let remaining = (state.context.lease_until - Utc::now())
        .to_std()
        .map_err(|_| TransportError::LeaseExpired)?;
    if remaining.is_zero() {
        return Err(TransportError::LeaseExpired);
    }
    Ok(remaining.min(max_attempt_wait))
}

fn replayable_exchange_error(error: &TransportError) -> bool {
    matches!(
        error,
        TransportError::OperationTimedOut
            | TransportError::BridgeConnect(_)
            | TransportError::BridgeHandshakeIo { .. }
            | TransportError::TlsHandshakeIo(_)
            | TransportError::ChannelIo { .. }
    )
}

#[async_trait]
impl DeviceTransport for ActivatedUnixDeviceTransport {
    async fn supports_v2(&self) -> Result<bool, TransportError> {
        let context = load_action_context(&self.managed_context_path).await?;
        Ok(supports_v2(&context.capabilities))
    }

    async fn execute(&self, action: Action) -> Result<DeviceResult, TransportError> {
        let context = load_action_context(&self.managed_context_path).await?;
        let transport = self.transport_for_context(context).await?;
        transport.execute(action).await
    }

    async fn execute_v2(
        &self,
        action: ActionV2,
        observation: ObservationPolicy,
    ) -> Result<DeviceResultV2, TransportError> {
        let context = load_action_context(&self.managed_context_path).await?;
        let transport = self.transport_for_context(context).await?;
        transport.execute_v2(action, observation).await
    }
}

#[async_trait]
impl DeviceTransport for UnixDeviceTransport {
    async fn supports_v2(&self) -> Result<bool, TransportError> {
        let state = self.state.lock().await;
        Ok(!state.poisoned && supports_v2(&state.context.capabilities))
    }

    async fn execute(&self, action: Action) -> Result<DeviceResult, TransportError> {
        let mut state = self.state.lock().await;
        if state.poisoned {
            return Err(TransportError::Poisoned);
        }
        let recovery_retries = self.recover_pending(&mut state).await?;
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
        let (response, exchange_retries) = match self.exchange(&mut state, &request).await {
            Ok(response) => response,
            Err(failure) => {
                clear_failed_connection(&mut state);
                if failure.request_started && replayable_exchange_error(&failure.error) {
                    state.pending_request = Some(PendingRequest::V1(request));
                } else if failure.request_started {
                    poison(&mut state);
                }
                return Err(failure.error);
            }
        };
        let mut result = apply_response_v1(&mut state, &request, response)?;
        result.retry_count = recovery_retries.saturating_add(exchange_retries);
        result.manual_recovery = recovery_retries > 0;
        Ok(result)
    }

    async fn execute_v2(
        &self,
        action: ActionV2,
        observation: ObservationPolicy,
    ) -> Result<DeviceResultV2, TransportError> {
        if !action.validate_parameters() || !observation.validate() {
            return Err(TransportError::InvalidContext);
        }
        let mut state = self.state.lock().await;
        if state.poisoned {
            return Err(TransportError::Poisoned);
        }
        let recovery_retries = self.recover_pending(&mut state).await?;
        if !supports_v2(&state.context.capabilities) {
            return Err(TransportError::CapabilityUnavailable);
        }
        if state.context.lease_until <= Utc::now() {
            poison(&mut state);
            return Err(TransportError::LeaseExpired);
        }
        if state.context.next_sequence == u64::MAX
            || state.context.current_state_generation == u64::MAX
            || state.context.current_screenshot_generation == u64::MAX
        {
            poison(&mut state);
            return Err(TransportError::CounterExhausted);
        }
        let request = ActionRequestV2 {
            version: PROTOCOL_VERSION_V2,
            request_id: Uuid::new_v4(),
            context: RequestContextV2 {
                user_id: state.context.user_id,
                device_id: state.context.device_id,
                tool_session_id: state.context.tool_session_id,
                device_session_id: state.context.device_session_id,
                node_id: state.context.node_id,
                platform: state.context.platform,
                generation: state.context.generation,
                monotonic_sequence: state.context.next_sequence,
                current_state_generation: state.context.current_state_generation,
                current_screenshot_generation: state.context.current_screenshot_generation,
                base_state_id: if matches!(observation.mode, ObservationMode::AxFull) {
                    None
                } else {
                    state.model_ax_base_state_id
                },
            },
            lease_until: state.context.lease_until,
            observation,
            action,
        };
        let (response, exchange_retries) = match self.exchange_v2(&mut state, &request).await {
            Ok(response) => response,
            Err(failure) => {
                clear_failed_connection(&mut state);
                if failure.request_started && replayable_exchange_error(&failure.error) {
                    state.pending_request = Some(PendingRequest::V2(request));
                } else if failure.request_started {
                    poison(&mut state);
                }
                return Err(failure.error);
            }
        };
        let mut result = apply_response_v2(&mut state, &request, response)?;
        result.retry_count = recovery_retries.saturating_add(exchange_retries);
        result.manual_recovery = recovery_retries > 0;
        Ok(result)
    }
}

fn apply_response_v1(
    state: &mut TransportState,
    request: &ActionRequest,
    response: ActionResponse,
) -> Result<DeviceResult, TransportError> {
    if response.request_id != request.request_id
        || response.monotonic_sequence != request.context.monotonic_sequence
        || response.screenshot_generation < request.context.current_screenshot_generation
    {
        poison(state);
        return Err(TransportError::ResponseBinding);
    }
    state.last_completed_response_binding = Some(ResponseBinding {
        request_id: response.request_id,
        monotonic_sequence: response.monotonic_sequence,
    });
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
        retry_count: 0,
        manual_recovery: false,
    })
}

fn apply_response_v2(
    state: &mut TransportState,
    request: &ActionRequestV2,
    response: ActionResponseV2,
) -> Result<DeviceResultV2, TransportError> {
    if response.request_id != request.request_id
        || response.monotonic_sequence != request.context.monotonic_sequence
        || !response.validate_payload(&request.observation)
    {
        poison(state);
        return Err(TransportError::ResponseBinding);
    }
    state.last_completed_response_binding = Some(ResponseBinding {
        request_id: response.request_id,
        monotonic_sequence: response.monotonic_sequence,
    });
    if matches!(response.status, ResponseStatusV2::Failed) {
        if response.state_generation != request.context.current_state_generation
            || response.screenshot_generation != request.context.current_screenshot_generation
            || response.state_id.is_some()
            || response.application_digest.is_some()
            || response.window_id.is_some()
            || response.display_fingerprint.is_some()
            || response.observation.is_some()
            || response.image.is_some()
        {
            poison(state);
            return Err(TransportError::ResponseBinding);
        }
        return Err(TransportError::DeviceRejected(response.message));
    }
    let expected_state_generation = request
        .context
        .current_state_generation
        .checked_add(1)
        .ok_or(TransportError::CounterExhausted)?;
    let Some(state_id) = response.state_id else {
        poison(state);
        return Err(TransportError::ResponseBinding);
    };
    let (Some(application_digest), Some(window_id), Some(display_fingerprint)) = (
        response.application_digest.clone(),
        response.window_id,
        response.display_fingerprint.clone(),
    ) else {
        poison(state);
        return Err(TransportError::ResponseBinding);
    };
    if application_digest.len() != 64
        || !application_digest
            .bytes()
            .all(|value| value.is_ascii_hexdigit())
        || display_fingerprint.is_empty()
        || display_fingerprint.len() > 256
    {
        poison(state);
        return Err(TransportError::ResponseBinding);
    }
    let expected_screenshot_generation = if response.image.is_some() {
        request
            .context
            .current_screenshot_generation
            .checked_add(1)
            .ok_or(TransportError::CounterExhausted)?
    } else {
        request.context.current_screenshot_generation
    };
    if response.state_generation != expected_state_generation
        || response.screenshot_generation != expected_screenshot_generation
        || !valid_observation_binding(
            response.observation.as_ref(),
            response.base_state_id,
            request.context.base_state_id,
        )
    {
        poison(state);
        return Err(TransportError::ResponseBinding);
    }
    state.context.next_sequence += 1;
    state.context.current_state_generation = response.state_generation;
    state.context.current_screenshot_generation = response.screenshot_generation;
    state.state_id = Some(state_id);
    let response_context = (
        application_digest.clone(),
        window_id,
        display_fingerprint.clone(),
    );
    if response.observation.is_some() {
        state.model_ax_base_state_id = Some(state_id);
        state.model_ax_base_context = Some(response_context);
    } else if state.model_ax_base_context.as_ref() != Some(&response_context) {
        state.model_ax_base_state_id = None;
        state.model_ax_base_context = None;
    }
    let screenshot = response.image.map(|image| ScreenshotV2 {
        base64_data: image.base64_data,
        mime_type: image.mime_type,
        pixel_width: image.pixel_width,
        pixel_height: image.pixel_height,
        profile: image.profile,
    });
    Ok(DeviceResultV2 {
        message: response.message,
        state_generation: response.state_generation,
        screenshot_generation: response.screenshot_generation,
        state_id,
        application_digest,
        window_id,
        display_fingerprint,
        base_state_id: response.base_state_id,
        observation: response.observation,
        settle: response.settle,
        screenshot,
        retry_count: 0,
        manual_recovery: false,
    })
}

fn valid_observation_binding(
    observation: Option<&AccessibilityObservation>,
    response_base_state_id: Option<Uuid>,
    request_base_state_id: Option<Uuid>,
) -> bool {
    match observation.map(|value| value.kind) {
        Some(AccessibilityObservationKind::Diff) => {
            response_base_state_id.is_some() && response_base_state_id == request_base_state_id
        }
        Some(AccessibilityObservationKind::Full) | None => response_base_state_id.is_none(),
    }
}

fn supports_v2(capabilities: &BTreeSet<String>) -> bool {
    [
        CAPABILITY_OBSERVATION_MODE_V2,
        CAPABILITY_AX_STATE_V2,
        CAPABILITY_ADAPTIVE_SETTLE_V2,
    ]
    .iter()
    .all(|capability| capabilities.contains(*capability))
}

fn poison(state: &mut TransportState) {
    state.poisoned = true;
    clear_failed_connection(state);
}

fn clear_failed_connection(state: &mut TransportState) {
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
    fn response_binding_accepts_only_current_or_exact_previous_response() {
        let previous = ResponseBinding {
            request_id: Uuid::new_v4(),
            monotonic_sequence: 4,
        };
        let expected = ResponseBinding {
            request_id: Uuid::new_v4(),
            monotonic_sequence: 5,
        };
        assert_eq!(
            classify_response_binding(expected, expected, Some(previous)).expect("current"),
            ResponseFrameKind::Expected
        );
        assert_eq!(
            classify_response_binding(previous, expected, Some(previous)).expect("duplicate"),
            ResponseFrameKind::PreviousDuplicate
        );

        let unrelated = ResponseBinding {
            request_id: Uuid::new_v4(),
            monotonic_sequence: 5,
        };
        assert!(matches!(
            classify_response_binding(unrelated, expected, Some(previous)),
            Err(TransportError::ResponseBinding)
        ));
    }

    #[test]
    fn observation_binding_accepts_full_fallback_after_a_diff_request() {
        let requested_base = Uuid::new_v4();
        let full = AccessibilityObservation {
            kind: AccessibilityObservationKind::Full,
            reset: false,
            truncated: false,
            nodes: vec![],
            removed: vec![],
        };

        assert!(valid_observation_binding(
            Some(&full),
            None,
            Some(requested_base)
        ));
    }

    #[test]
    fn observation_binding_keeps_diff_tied_to_the_requested_base() {
        let requested_base = Uuid::new_v4();
        let diff = AccessibilityObservation {
            kind: AccessibilityObservationKind::Diff,
            reset: false,
            truncated: false,
            nodes: vec![],
            removed: vec![],
        };

        assert!(valid_observation_binding(
            Some(&diff),
            Some(requested_base),
            Some(requested_base)
        ));
        assert!(!valid_observation_binding(
            Some(&diff),
            None,
            Some(requested_base)
        ));
        assert!(!valid_observation_binding(
            Some(&diff),
            Some(Uuid::new_v4()),
            Some(requested_base)
        ));
    }

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

    #[test]
    fn managed_context_treats_null_capabilities_as_v1() {
        let directory = tempdir().expect("temp directory");
        let path = directory.path().join("context.json");
        let context = test_context(1, Utc::now() + chrono::Duration::seconds(30));
        let mut value = serde_json::to_value(context).expect("serialize context");
        value["capabilities"] = serde_json::Value::Null;
        std::fs::write(&path, serde_json::to_vec(&value).expect("encode context"))
            .expect("write context");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .expect("set context permissions");

        let loaded = ManagedContext::load(&path).expect("load legacy null capabilities");
        assert!(loaded.capabilities.is_empty());
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
    async fn pre_request_timeout_is_bounded_by_the_lease_without_poisoning() {
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
        assert!(!state.poisoned);
        assert!(state.connection.is_none());
        assert_eq!(state.context.next_sequence, 1);
        drop(state);
        server.abort();
    }

    #[test]
    fn action_waits_for_a_lease_that_can_cover_transport_and_capture_work() {
        let now = Utc::now();
        let stale = test_context(1, now + chrono::Duration::seconds(29));
        let fresh = test_context(1, now + chrono::Duration::seconds(31));

        assert!(!action_lease_ready(&stale, now));
        assert!(action_lease_ready(&fresh, now));
    }

    #[tokio::test]
    async fn repeated_bridge_handshake_failures_allow_a_later_fresh_action() {
        let directory = tempdir().expect("temp directory");
        let socket_path = directory.path().join("bridge.sock");
        let listener = UnixListener::bind(&socket_path).expect("bind bridge socket");
        let context = test_context(9, Utc::now() + chrono::Duration::seconds(60));
        let server_context = context.clone();
        let server = tokio::spawn(async move {
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().await.expect("accept failed handshake");
                let _: BridgeHello = read_bridge_control(&mut stream)
                    .await
                    .expect("read failed-handshake hello");
            }

            let (mut stream, _) = listener.accept().await.expect("accept recovery handshake");
            let hello: BridgeHello = read_bridge_control(&mut stream)
                .await
                .expect("read recovery hello");
            assert_eq!(hello.generation, server_context.generation);
            let identity = GenerationIdentity::generate().expect("device identity");
            let exporter_context = hex::encode([0x7c_u8; 32]);
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
            .expect("write bridge material");
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

            let request = read_framed_json(&mut tls).await;
            let request = &request["request"];
            assert_eq!(request["context"]["monotonic_sequence"], 1);
            write_framed_json(
                &mut tls,
                &serde_json::json!({
                    "request_id": request["request_id"],
                    "monotonic_sequence": 1,
                    "screenshot_generation": 0,
                    "status": "success",
                    "message": "recovered",
                    "image": null
                }),
            )
            .await;
        });

        let transport = UnixDeviceTransport::new(&socket_path, context);
        assert!(matches!(
            transport.execute(Action::Screenshot).await,
            Err(TransportError::BridgeHandshakeIo { .. })
        ));
        {
            let state = transport.state.lock().await;
            assert!(!state.poisoned);
            assert!(state.connection.is_none());
            assert_eq!(state.context.next_sequence, 1);
        }

        let result = transport
            .execute(Action::Screenshot)
            .await
            .expect("fresh action after handshake failures");
        assert_eq!(result.message, "recovered");
        let state = transport.state.lock().await;
        assert!(!state.poisoned);
        assert_eq!(state.context.next_sequence, 2);
        drop(state);
        server.await.expect("bridge server");
    }

    #[tokio::test]
    async fn ambiguous_request_recovers_exact_replay_before_the_next_action() {
        let directory = tempdir().expect("temp directory");
        let socket_path = directory.path().join("bridge.sock");
        let listener = UnixListener::bind(&socket_path).expect("bind bridge socket");
        let context = test_context(11, Utc::now() + chrono::Duration::seconds(60));
        let server_context = context.clone();
        let server = tokio::spawn(async move {
            let mut pending_request_id = None;
            for exporter_byte in [0x31, 0x32] {
                let mut tls = accept_test_tls(&listener, &server_context, exporter_byte).await;
                let request = read_framed_json(&mut tls).await;
                let request = &request["request"];
                assert_eq!(request["context"]["monotonic_sequence"], 1);
                let request_id = request["request_id"].clone();
                if let Some(expected) = &pending_request_id {
                    assert_eq!(&request_id, expected, "retry must replay exact bytes");
                } else {
                    pending_request_id = Some(request_id);
                }
                drop(tls);
            }

            let mut tls = accept_test_tls(&listener, &server_context, 0x33).await;
            let recovered = read_framed_json(&mut tls).await;
            let recovered = &recovered["request"];
            assert_eq!(Some(recovered["request_id"].clone()), pending_request_id);
            write_framed_json(
                &mut tls,
                &serde_json::json!({
                    "request_id": recovered["request_id"],
                    "monotonic_sequence": 1,
                    "screenshot_generation": 0,
                    "status": "success",
                    "message": "pending recovered",
                    "image": null
                }),
            )
            .await;

            let next = read_framed_json(&mut tls).await;
            let next = &next["request"];
            assert_eq!(next["context"]["monotonic_sequence"], 2);
            assert_ne!(next["request_id"], recovered["request_id"]);
            write_framed_json(
                &mut tls,
                &serde_json::json!({
                    "request_id": next["request_id"],
                    "monotonic_sequence": 2,
                    "screenshot_generation": 0,
                    "status": "success",
                    "message": "next action completed",
                    "image": null
                }),
            )
            .await;
        });

        let transport = UnixDeviceTransport::new(&socket_path, context);
        assert!(matches!(
            transport.execute(Action::Screenshot).await,
            Err(TransportError::ChannelIo { .. })
        ));
        {
            let state = transport.state.lock().await;
            assert!(!state.poisoned);
            assert!(matches!(state.pending_request, Some(PendingRequest::V1(_))));
            assert_eq!(state.context.next_sequence, 1);
        }

        let result = transport
            .execute(Action::Wait { duration_ms: 1 })
            .await
            .expect("fresh action after pending replay recovery");
        assert_eq!(result.message, "next action completed");
        let state = transport.state.lock().await;
        assert!(!state.poisoned);
        assert!(state.pending_request.is_none());
        assert_eq!(state.context.next_sequence, 3);
        drop(state);
        server.await.expect("bridge server");
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

    #[tokio::test]
    async fn v2_nested_tls_binds_capabilities_state_and_failure_counters() {
        let directory = tempdir().expect("temp directory");
        let socket_path = directory.path().join("bridge.sock");
        let listener = UnixListener::bind(&socket_path).expect("bind bridge");
        let mut context = test_context(5, Utc::now() + chrono::Duration::seconds(60));
        context.capabilities = [
            CAPABILITY_ADAPTIVE_SETTLE_V2.to_owned(),
            CAPABILITY_AX_STATE_V2.to_owned(),
            CAPABILITY_OBSERVATION_MODE_V2.to_owned(),
        ]
        .into_iter()
        .collect();
        let server_context = context.clone();
        let state_id = Uuid::new_v4();
        let state_id_after_none = Uuid::new_v4();
        let state_id_after_full = Uuid::new_v4();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.expect("accept proxy");
            let hello: BridgeHello = read_bridge_control(&mut stream)
                .await
                .expect("bridge hello");
            assert_eq!(hello.generation, server_context.generation);
            let identity = GenerationIdentity::generate().expect("device identity");
            let exporter_context = hex::encode([0x6b_u8; 32]);
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

            let first = read_framed_json(&mut tls).await;
            let first = &first["request"];
            assert_eq!(first["version"], PROTOCOL_VERSION_V2);
            assert_eq!(first["context"]["monotonic_sequence"], 1);
            assert_eq!(first["context"]["current_state_generation"], 0);
            assert_eq!(first["context"]["current_screenshot_generation"], 0);
            assert_eq!(first["context"]["base_state_id"], serde_json::Value::Null);
            assert_eq!(first["observation"]["mode"], "auto");
            assert_eq!(first["action"]["type"], "observe");
            let first_response = serde_json::json!({
                "request_id": first["request_id"],
                "monotonic_sequence": 1,
                "state_generation": 1,
                "screenshot_generation": 0,
                "state_id": state_id,
                "application_digest": "a".repeat(64),
                "window_id": 7,
                "display_fingerprint": "display-layout",
                "base_state_id": null,
                "status": "success",
                "message": "Action completed.",
                "observation": {
                    "kind": "full",
                    "reset": false,
                    "truncated": false,
                    "nodes": [],
                    "removed": []
                },
                "settle": {"status": "not_requested", "elapsed_ms": 0},
                "image": null
            });
            write_framed_json(&mut tls, &first_response).await;

            let second = read_framed_json(&mut tls).await;
            let second = &second["request"];
            assert_eq!(second["context"]["monotonic_sequence"], 2);
            assert_eq!(second["context"]["current_state_generation"], 1);
            assert_eq!(second["context"]["base_state_id"], state_id.to_string());
            assert_eq!(second["observation"]["mode"], "none");
            // A delayed response from an exact replay can be queued ahead of the
            // current response. The proxy must discard only this proven duplicate.
            write_framed_json(&mut tls, &first_response).await;
            write_framed_json(
                &mut tls,
                &serde_json::json!({
                    "request_id": second["request_id"],
                    "monotonic_sequence": 2,
                    "state_generation": 2,
                    "screenshot_generation": 0,
                    "state_id": state_id_after_none,
                    "application_digest": "a".repeat(64),
                    "window_id": 7,
                    "display_fingerprint": "display-layout",
                    "status": "success",
                    "message": "Action completed.",
                    "settle": {"status": "not_requested", "elapsed_ms": 0}
                }),
            )
            .await;

            let third = read_framed_json(&mut tls).await;
            let third = &third["request"];
            assert_eq!(third["context"]["monotonic_sequence"], 3);
            assert_eq!(third["context"]["current_state_generation"], 2);
            assert_eq!(third["context"]["base_state_id"], state_id.to_string());
            write_framed_json(
                &mut tls,
                &serde_json::json!({
                    "request_id": third["request_id"],
                    "monotonic_sequence": 3,
                    "state_generation": 2,
                    "screenshot_generation": 0,
                    "status": "failed",
                    "message": "stale_element_target: observe again",
                    "settle": {"status": "not_requested", "elapsed_ms": 0}
                }),
            )
            .await;

            let fourth = read_framed_json(&mut tls).await;
            let fourth = &fourth["request"];
            assert_eq!(fourth["context"]["monotonic_sequence"], 3);
            assert_eq!(fourth["context"]["current_state_generation"], 2);
            assert_eq!(fourth["context"]["base_state_id"], serde_json::Value::Null);
            assert_eq!(fourth["observation"]["mode"], "ax_full");
            write_framed_json(
                &mut tls,
                &serde_json::json!({
                    "request_id": fourth["request_id"],
                    "monotonic_sequence": 3,
                    "state_generation": 3,
                    "screenshot_generation": 0,
                    "state_id": state_id_after_full,
                    "application_digest": "a".repeat(64),
                    "window_id": 7,
                    "display_fingerprint": "display-layout",
                    "base_state_id": null,
                    "status": "success",
                    "message": "Action completed.",
                    "observation": {
                        "kind": "full",
                        "reset": true,
                        "truncated": false,
                        "nodes": [],
                        "removed": []
                    },
                    "settle": {"status": "not_requested", "elapsed_ms": 0},
                    "image": null
                }),
            )
            .await;
        });

        let transport = UnixDeviceTransport::new(&socket_path, context);
        let first = transport
            .execute_v2(
                ActionV2::Observe { application: None },
                ObservationPolicy::default(),
            )
            .await
            .expect("v2 observation");
        assert_eq!(first.state_id, state_id);
        assert_eq!(first.state_generation, 1);
        assert_eq!(first.screenshot_generation, 0);

        let after_none = transport
            .execute_v2(
                ActionV2::Observe { application: None },
                ObservationPolicy {
                    mode: ObservationMode::None,
                    settle: crate::protocol_v2::SettleMode::None,
                    settle_timeout_ms: 0,
                    image_profile: ImageProfile::None,
                    ..ObservationPolicy::default()
                },
            )
            .await
            .expect("none observation");
        assert_eq!(after_none.state_id, state_id_after_none);
        assert!(after_none.observation.is_none());

        let error = transport
            .execute_v2(
                ActionV2::Observe { application: None },
                ObservationPolicy::default(),
            )
            .await
            .expect_err("device failure must remain a rejected operation");
        assert!(matches!(error, TransportError::DeviceRejected(_)));
        let state = transport.state.lock().await;
        assert!(!state.poisoned);
        assert_eq!(state.context.next_sequence, 3);
        assert_eq!(state.context.current_state_generation, 2);
        assert_eq!(state.context.current_screenshot_generation, 0);
        assert_eq!(state.model_ax_base_state_id, Some(state_id));
        drop(state);

        let after_full = transport
            .execute_v2(
                ActionV2::Observe { application: None },
                ObservationPolicy {
                    mode: ObservationMode::AxFull,
                    settle: crate::protocol_v2::SettleMode::None,
                    settle_timeout_ms: 0,
                    image_profile: ImageProfile::None,
                    ..ObservationPolicy::default()
                },
            )
            .await
            .expect("explicit full observation");
        assert_eq!(after_full.state_id, state_id_after_full);
        assert_eq!(after_full.state_generation, 3);
        let state = transport.state.lock().await;
        assert_eq!(state.context.next_sequence, 4);
        assert_eq!(state.model_ax_base_state_id, Some(state_id_after_full));
        drop(state);
        server.await.expect("bridge server");
    }

    async fn read_framed_json(
        stream: &mut tokio_rustls::server::TlsStream<UnixStream>,
    ) -> serde_json::Value {
        let length = stream.read_u32().await.expect("frame length") as usize;
        assert!((1..=MAX_FRAME_BYTES).contains(&length));
        let mut bytes = vec![0_u8; length];
        stream.read_exact(&mut bytes).await.expect("frame bytes");
        serde_json::from_slice(&bytes).expect("frame JSON")
    }

    async fn write_framed_json(
        stream: &mut tokio_rustls::server::TlsStream<UnixStream>,
        value: &serde_json::Value,
    ) {
        let bytes = serde_json::to_vec(value).expect("response JSON");
        stream
            .write_u32(bytes.len() as u32)
            .await
            .expect("response length");
        stream.write_all(&bytes).await.expect("response bytes");
        stream.flush().await.expect("flush response");
    }

    async fn accept_test_tls(
        listener: &UnixListener,
        context: &ManagedContext,
        exporter_byte: u8,
    ) -> tokio_rustls::server::TlsStream<UnixStream> {
        let (mut stream, _) = listener.accept().await.expect("accept proxy");
        let hello: BridgeHello = read_bridge_control(&mut stream)
            .await
            .expect("bridge hello");
        let identity = GenerationIdentity::generate().expect("device identity");
        let exporter_context = hex::encode([exporter_byte; 32]);
        write_bridge_control(
            &mut stream,
            &BridgeMaterial {
                protocol_version: BRIDGE_PROTOCOL_VERSION,
                generation: context.generation,
                peer_spki_sha256: identity.spki_sha256_hex(),
                exporter_context: exporter_context.clone(),
            },
        )
        .await
        .expect("bridge material");
        let material =
            GenerationMaterial::from_hex(context.generation, &hello.spki_sha256, &exporter_context)
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
            context.generation,
            context.device_session_id,
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
            context.generation,
            context.device_session_id,
        )
        .expect("verify proxy confirmation");
        tls
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
            current_state_generation: 0,
            capabilities: BTreeSet::new(),
            lease_until,
        }
    }
}
