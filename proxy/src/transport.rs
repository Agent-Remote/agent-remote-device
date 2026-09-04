use std::{
    collections::{BTreeMap, BTreeSet},
    fs::OpenOptions,
    io::Read,
    os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt},
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
        ResponseStatusV2, SettleResult, CAPABILITY_ADAPTIVE_SETTLE_V2,
        CAPABILITY_APPLICATION_LAUNCH_V1, CAPABILITY_AX_STATE_V2, CAPABILITY_CLIPBOARD_PAYLOAD_V2,
        CAPABILITY_GLOBAL_CLIPBOARD_V1, CAPABILITY_OBSERVATION_MODE_V2,
        CAPABILITY_SESSION_FULL_TRUST_V1, PROTOCOL_VERSION_V2,
    },
};

const MAX_CONTEXT_BYTES: u64 = 16 * 1024;
const MAX_BRIDGE_CONTROL_BYTES: usize = 4096;
const BRIDGE_PROTOCOL_VERSION: u8 = 1;
// A generation rotation closes the old relay before the device publishes the
// replacement context. The control-plane exchange is bounded, but can take
// several seconds when the server is reconnecting both relay peers.
const MAX_ACTION_RESPONSE_WAIT: Duration = Duration::from_secs(60);
const LIFECYCLE_RESPONSE_WAIT: Duration = Duration::from_secs(15);
const INITIAL_ACTION_CONTEXT_READY_WAIT: Duration = Duration::from_secs(60);
// A bridge socket proves that Node activation is live while an absent context
// means local approval is still converging. Keep the same MCP call open for a
// bounded additional window instead of spending another model tool call.
const PENDING_ACTIVATION_CONTEXT_READY_WAIT: Duration = Duration::from_secs(120);
// Keep the MCP call alive across a bounded generation-rotation window. Ten
// seconds was shorter than the control-plane reconnect sequence and surfaced
// transient rotation as a permanent `context open failed` error.
const RECOVERY_ACTION_CONTEXT_READY_WAIT: Duration = Duration::from_secs(45);
const BACKGROUND_CONTEXT_READY_WAIT: Duration = Duration::from_secs(10);
const ACTION_LEASE_READY_WAIT: Duration = Duration::from_secs(15);
const MIN_ACTION_LEASE_REMAINING: Duration = Duration::from_secs(30);
const CONTEXT_RETRY_INTERVAL: Duration = Duration::from_millis(100);
// Control-plane generation rotation can briefly outlast the old three-attempt
// (700 ms) window. Keep retries bounded, but allow the action's 60 s deadline
// to absorb a normal relay restart without surfacing a transient TLS failure.
const MAX_SAME_GENERATION_RECONNECTS: u16 = 7;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthorizationMode {
    PerApplicationApproval,
    SessionFullTrust,
}

fn default_authorization_mode() -> AuthorizationMode {
    AuthorizationMode::PerApplicationApproval
}

fn default_authorization_policy_version() -> u8 {
    1
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ManagedContext {
    #[serde(default = "default_authorization_mode")]
    pub authorization_mode: AuthorizationMode,
    #[serde(default = "default_authorization_policy_version")]
    pub authorization_policy_version: u8,
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
        let document: serde_json::Value = serde_json::from_slice(&bytes)?;
        let object = document.as_object().ok_or(TransportError::InvalidContext)?;
        if object.contains_key("authorization_mode")
            != object.contains_key("authorization_policy_version")
        {
            return Err(TransportError::InvalidContext);
        }
        let context: Self = serde_json::from_value(document)?;
        if context.generation == 0
            || context.generation > MAX_ACTIVE_DEVICE_SESSION_GENERATION
            || context.next_sequence == 0
            || context.platform != Platform::Macos
            || context.authorization_policy_version != 1
            || match context.authorization_mode {
                AuthorizationMode::PerApplicationApproval => {
                    !legacy_capabilities_are_valid(&context.capabilities)
                }
                AuthorizationMode::SessionFullTrust => {
                    context.capabilities != full_trust_capabilities()
                }
            }
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
            && self.authorization_mode == other.authorization_mode
            && self.authorization_policy_version == other.authorization_policy_version
            && self.capabilities == other.capabilities
    }
}

fn full_trust_capabilities() -> BTreeSet<String> {
    [
        CAPABILITY_ADAPTIVE_SETTLE_V2,
        CAPABILITY_APPLICATION_LAUNCH_V1,
        CAPABILITY_AX_STATE_V2,
        CAPABILITY_CLIPBOARD_PAYLOAD_V2,
        CAPABILITY_GLOBAL_CLIPBOARD_V1,
        CAPABILITY_OBSERVATION_MODE_V2,
        CAPABILITY_SESSION_FULL_TRUST_V1,
    ]
    .into_iter()
    .map(str::to_owned)
    .collect()
}

fn observation_v2_capabilities() -> BTreeSet<String> {
    [
        CAPABILITY_ADAPTIVE_SETTLE_V2,
        CAPABILITY_AX_STATE_V2,
        CAPABILITY_OBSERVATION_MODE_V2,
    ]
    .into_iter()
    .map(str::to_owned)
    .collect()
}

fn legacy_v2_capabilities() -> BTreeSet<String> {
    [
        CAPABILITY_ADAPTIVE_SETTLE_V2,
        CAPABILITY_AX_STATE_V2,
        CAPABILITY_CLIPBOARD_PAYLOAD_V2,
        CAPABILITY_OBSERVATION_MODE_V2,
    ]
    .into_iter()
    .map(str::to_owned)
    .collect()
}

fn legacy_capabilities_are_valid(capabilities: &BTreeSet<String>) -> bool {
    capabilities.is_empty()
        || *capabilities == observation_v2_capabilities()
        || *capabilities == legacy_v2_capabilities()
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
    pub state_id: Option<Uuid>,
    pub application_digest: Option<String>,
    pub window_id: Option<u32>,
    pub display_fingerprint: Option<String>,
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

    async fn supports_capability(&self, _capability: &str) -> Result<bool, TransportError> {
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
    failed_generation: Mutex<Option<(Uuid, u64)>>,
}

#[derive(Debug)]
struct TransportState {
    context: ManagedContext,
    state_id: Option<Uuid>,
    state_context: Option<(String, u32, String)>,
    model_ax_bases: BTreeMap<(String, u32, String), Uuid>,
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
    #[error("device relay generation did not rotate after the prior transport failure")]
    GenerationRecoveryTimedOut,
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
    #[error("device response failed protocol validation: {0}")]
    ResponseValidation(&'static str),
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

impl TransportError {
    /// Returns the stable MCP-facing error classification while retaining the
    /// concrete transport diagnostic for logs and troubleshooting.
    pub fn client_message(&self) -> String {
        if matches!(
            self,
            Self::GenerationRecoveryTimedOut
                | Self::Poisoned
                | Self::OperationTimedOut
                | Self::BridgeConnect(_)
                | Self::BridgeHandshakeIo { .. }
                | Self::TlsHandshakeIo(_)
                | Self::ChannelIo { .. }
        ) {
            format!("transport_unavailable: {self}")
        } else {
            self.to_string()
        }
    }
}

impl UnixDeviceTransport {
    pub fn new(socket_path: &Path, context: ManagedContext) -> Self {
        Self {
            socket_path: Arc::from(socket_path),
            state: Mutex::new(TransportState {
                state_id: None,
                state_context: None,
                model_ax_bases: BTreeMap::new(),
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
            true,
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
            replayable_action_v2(&request.action),
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
            Ok(()) => {
                state.pending_request = None;
                Ok(retries.saturating_add(1))
            }
            Err(TransportError::DeviceRejected(_)) if !state.poisoned => {
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
            failed_generation: Mutex::new(None),
        }
    }

    /// Forwards one lifecycle event using the active generation binding.
    pub async fn notify_lifecycle(&self, event: LifecycleEvent) -> Result<(), TransportError> {
        let failed_generation = *self.failed_generation.lock().await;
        let context = if failed_generation.is_some() {
            load_action_context(
                &self.managed_context_path,
                RECOVERY_ACTION_CONTEXT_READY_WAIT,
                failed_generation,
            )
            .await?
        } else {
            load_managed_context(&self.managed_context_path, Duration::ZERO).await?
        };
        let transport = self.transport_for_context(context).await?;
        let result = transport.notify_lifecycle(event).await;
        if result.is_ok() && failed_generation.is_some() {
            let mut failed = self.failed_generation.lock().await;
            if *failed == failed_generation {
                *failed = None;
            }
        }
        result
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

    async fn action_context(&self) -> Result<ManagedContext, TransportError> {
        let failed_generation = *self.failed_generation.lock().await;
        let has_active = self.active.lock().await.is_some();
        let context = if has_active {
            load_action_context(
                &self.managed_context_path,
                RECOVERY_ACTION_CONTEXT_READY_WAIT,
                failed_generation,
            )
            .await?
        } else {
            load_initial_action_context(
                &self.managed_context_path,
                &self.bridge_socket_path,
                INITIAL_ACTION_CONTEXT_READY_WAIT,
                PENDING_ACTIVATION_CONTEXT_READY_WAIT,
            )
            .await?
        };
        if failed_generation.is_some() {
            let mut failed = self.failed_generation.lock().await;
            if *failed == failed_generation {
                *failed = None;
            }
        }
        Ok(context)
    }

    async fn record_transport_failure(
        &self,
        context: &ManagedContext,
        result: &Result<impl Sized, TransportError>,
    ) {
        if result.as_ref().is_err_and(replayable_exchange_error) {
            *self.failed_generation.lock().await =
                Some((context.device_session_id, context.generation));
        }
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

async fn load_action_context(
    path: &Path,
    ready_wait: Duration,
    failed_generation: Option<(Uuid, u64)>,
) -> Result<ManagedContext, TransportError> {
    let generation_deadline = Instant::now() + ready_wait;
    let mut context = load_managed_context(path, ready_wait).await?;
    while failed_generation
        .is_some_and(|value| value == (context.device_session_id, context.generation))
    {
        let wait = generation_deadline.saturating_duration_since(Instant::now());
        if wait.is_zero() {
            return Err(TransportError::GenerationRecoveryTimedOut);
        }
        sleep(CONTEXT_RETRY_INTERVAL.min(wait)).await;
        context = load_managed_context(path, wait).await?;
    }
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
        context = load_managed_context(path, wait).await?;
    }
}

async fn load_initial_action_context(
    context_path: &Path,
    bridge_socket_path: &Path,
    initial_wait: Duration,
    pending_activation_wait: Duration,
) -> Result<ManagedContext, TransportError> {
    match load_action_context(context_path, initial_wait, None).await {
        Err(TransportError::NotActivated) if bridge_activation_pending(bridge_socket_path) => {
            load_action_context(context_path, pending_activation_wait, None).await
        }
        result => result,
    }
}

fn bridge_activation_pending(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_socket())
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
    allow_replay: bool,
) -> Result<(Vec<u8>, u16), ExchangeFailure> {
    let deadline = Instant::now() + max_attempt_wait;
    let mut retry_count = 0_u16;
    let mut request_started = false;
    let mut first_error = None;

    loop {
        let deadline_wait = deadline.saturating_duration_since(Instant::now());
        let attempt_wait = match remaining_exchange_wait(state, deadline_wait) {
            Ok(wait) => wait,
            Err(error) => {
                return Err(ExchangeFailure {
                    error: first_error.unwrap_or(error),
                    request_started,
                })
            }
        };
        if attempt_wait.is_zero() {
            return Err(ExchangeFailure {
                error: first_error.unwrap_or(TransportError::OperationTimedOut),
                request_started,
            });
        }

        let mut phase = ExchangePhase::PreRequest;
        let result = match timeout(
            attempt_wait,
            exchange_expected_payload(socket_path, state, payload, &mut phase, expected_binding),
        )
        .await
        {
            Ok(result) => result,
            Err(_) => Err(TransportError::OperationTimedOut),
        };
        request_started |= matches!(phase, ExchangePhase::RequestStarted);
        match result {
            Ok(response) => return Ok((response, retry_count)),
            Err(error) if replayable_exchange_error(&error) && allow_replay => {
                first_error.get_or_insert(error);
                state.connection = None;
            }
            Err(error) => {
                return Err(ExchangeFailure {
                    error,
                    request_started,
                })
            }
        }

        let retry_wait = deadline.saturating_duration_since(Instant::now());
        if retry_wait.is_zero() {
            return Err(ExchangeFailure {
                error: first_error.unwrap_or(TransportError::OperationTimedOut),
                request_started,
            });
        }
        retry_count = retry_count.saturating_add(1);
        if retry_count > MAX_SAME_GENERATION_RECONNECTS {
            return Err(ExchangeFailure {
                error: first_error.unwrap_or(TransportError::OperationTimedOut),
                request_started,
            });
        }
        let backoff = CONTEXT_RETRY_INTERVAL.saturating_mul(1_u32 << (retry_count - 1));
        sleep(backoff.min(retry_wait)).await;
    }
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

fn replayable_action_v2(action: &ActionV2) -> bool {
    !matches!(action, ActionV2::LaunchApplication { .. })
}

#[async_trait]
impl DeviceTransport for ActivatedUnixDeviceTransport {
    async fn supports_v2(&self) -> Result<bool, TransportError> {
        let context = self.action_context().await?;
        Ok(supports_v2(&context.capabilities))
    }

    async fn supports_capability(&self, capability: &str) -> Result<bool, TransportError> {
        let context = self.action_context().await?;
        Ok(context.capabilities.contains(capability))
    }

    async fn execute(&self, action: Action) -> Result<DeviceResult, TransportError> {
        let context = self.action_context().await?;
        let transport = self.transport_for_context(context.clone()).await?;
        let result = transport.execute(action).await;
        self.record_transport_failure(&context, &result).await;
        result
    }

    async fn execute_v2(
        &self,
        action: ActionV2,
        observation: ObservationPolicy,
    ) -> Result<DeviceResultV2, TransportError> {
        let context = self.action_context().await?;
        let transport = self.transport_for_context(context.clone()).await?;
        let result = transport.execute_v2(action, observation).await;
        self.record_transport_failure(&context, &result).await;
        result
    }
}

#[async_trait]
impl DeviceTransport for UnixDeviceTransport {
    async fn supports_v2(&self) -> Result<bool, TransportError> {
        let state = self.state.lock().await;
        Ok(!state.poisoned && supports_v2(&state.context.capabilities))
    }

    async fn supports_capability(&self, capability: &str) -> Result<bool, TransportError> {
        let state = self.state.lock().await;
        Ok(!state.poisoned && state.context.capabilities.contains(capability))
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
        let element_base_state_id = match &action {
            ActionV2::Press { target }
            | ActionV2::SetValue { target, .. }
            | ActionV2::SelectText { target, .. }
            | ActionV2::ScrollElement { target, .. }
            | ActionV2::SecondaryAction { target, .. } => Some(target.state_id),
            _ => None,
        };
        let action_state_context = match &action {
            ActionV2::Press { target }
            | ActionV2::SetValue { target, .. }
            | ActionV2::SelectText { target, .. }
            | ActionV2::ScrollElement { target, .. }
            | ActionV2::SecondaryAction { target, .. } => Some((
                target.application_digest.clone(),
                target.window_id,
                target.display_fingerprint.clone(),
            )),
            ActionV2::Observe {
                application: Some(_),
            } => None,
            _ => state.state_context.clone(),
        };
        let base_state_id = if matches!(observation.mode, ObservationMode::AxFull) {
            None
        } else {
            element_base_state_id.or_else(|| {
                action_state_context
                    .as_ref()
                    .and_then(|context| state.model_ax_bases.get(context).copied())
            })
        };
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
                base_state_id,
            },
            lease_until: state.context.lease_until,
            observation,
            action,
        };
        let (response, exchange_retries) = match self.exchange_v2(&mut state, &request).await {
            Ok(response) => response,
            Err(failure) => {
                clear_failed_connection(&mut state);
                if failure.request_started
                    && replayable_exchange_error(&failure.error)
                    && replayable_action_v2(&request.action)
                {
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
    mut response: ActionResponseV2,
) -> Result<DeviceResultV2, TransportError> {
    if response.request_id != request.request_id
        || response.monotonic_sequence != request.context.monotonic_sequence
    {
        poison(state);
        return Err(TransportError::ResponseBinding);
    }
    // AX action names are OS-provided metadata. Some system applications emit
    // custom names containing control characters; those names cannot be safely
    // invoked or represented in the model-visible protocol, so discard them
    // without invalidating the otherwise bound response.
    response.discard_unsafe_ax_actions();
    if let Err(reason) = response.validate_payload_reason(&request.observation) {
        poison(state);
        return Err(TransportError::ResponseValidation(reason));
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
            return Err(TransportError::ResponseValidation(
                "failed response contains state",
            ));
        }
        if is_terminal_device_rejection(&response.message) {
            poison(state);
        }
        return Err(TransportError::DeviceRejected(response.message));
    }
    let message = match model_message_v2(
        &request.action,
        state
            .context
            .capabilities
            .contains(CAPABILITY_CLIPBOARD_PAYLOAD_V2),
        response.message,
        response.clipboard,
    ) {
        Ok(message) => message,
        Err(reason) => {
            poison(state);
            return Err(TransportError::ResponseValidation(reason));
        }
    };
    let preserves_state = matches!(request.action, ActionV2::ReadClipboard);
    let expected_state_generation = if preserves_state {
        request.context.current_state_generation
    } else {
        request
            .context
            .current_state_generation
            .checked_add(1)
            .ok_or(TransportError::CounterExhausted)?
    };
    let stateless_global_clipboard = preserves_state
        && request.context.current_state_generation == 0
        && state
            .context
            .capabilities
            .contains(CAPABILITY_GLOBAL_CLIPBOARD_V1)
        && response.state_id.is_none()
        && response.application_digest.is_none()
        && response.window_id.is_none()
        && response.display_fingerprint.is_none();
    if stateless_global_clipboard {
        if response.state_generation != 0
            || response.screenshot_generation != request.context.current_screenshot_generation
            || response.observation.is_some()
            || response.image.is_some()
        {
            poison(state);
            return Err(TransportError::ResponseValidation(
                "stateless clipboard response contains state",
            ));
        }
        state.context.next_sequence += 1;
        return Ok(DeviceResultV2 {
            message,
            state_generation: response.state_generation,
            screenshot_generation: response.screenshot_generation,
            state_id: None,
            application_digest: None,
            window_id: None,
            display_fingerprint: None,
            base_state_id: None,
            observation: None,
            settle: response.settle,
            screenshot: None,
            retry_count: 0,
            manual_recovery: false,
        });
    }
    let Some(state_id) = response.state_id else {
        poison(state);
        return Err(TransportError::ResponseValidation("missing state_id"));
    };
    let (Some(application_digest), Some(window_id), Some(display_fingerprint)) = (
        response.application_digest.clone(),
        response.window_id,
        response.display_fingerprint.clone(),
    ) else {
        poison(state);
        return Err(TransportError::ResponseValidation(
            "missing application or window context",
        ));
    };
    if application_digest.len() != 64
        || !application_digest
            .bytes()
            .all(|value| value.is_ascii_hexdigit())
        || display_fingerprint.is_empty()
        || display_fingerprint.len() > 256
    {
        poison(state);
        return Err(TransportError::ResponseValidation(
            "invalid application or display context",
        ));
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
    if response.state_generation != expected_state_generation {
        poison(state);
        return Err(TransportError::ResponseValidation("state generation"));
    }
    if preserves_state && state.state_id != Some(state_id) {
        poison(state);
        return Err(TransportError::ResponseValidation("preserved state id"));
    }
    if response.screenshot_generation != expected_screenshot_generation {
        poison(state);
        return Err(TransportError::ResponseValidation("screenshot generation"));
    }
    if !valid_observation_binding(
        response.observation.as_ref(),
        response.base_state_id,
        request.context.base_state_id,
    ) {
        poison(state);
        return Err(TransportError::ResponseValidation(
            "accessibility base state",
        ));
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
    state.state_context = Some(response_context.clone());
    if response.observation.is_some() {
        state.model_ax_bases.insert(response_context, state_id);
    }
    let screenshot = response.image.map(|image| ScreenshotV2 {
        base64_data: image.base64_data,
        mime_type: image.mime_type,
        pixel_width: image.pixel_width,
        pixel_height: image.pixel_height,
        profile: image.profile,
    });
    Ok(DeviceResultV2 {
        message,
        state_generation: response.state_generation,
        screenshot_generation: response.screenshot_generation,
        state_id: Some(state_id),
        application_digest: Some(application_digest),
        window_id: Some(window_id),
        display_fingerprint: Some(display_fingerprint),
        base_state_id: response.base_state_id,
        observation: response.observation,
        settle: response.settle,
        screenshot,
        retry_count: 0,
        manual_recovery: false,
    })
}

fn model_message_v2(
    action: &ActionV2,
    supports_clipboard_payload: bool,
    message: String,
    clipboard: Option<String>,
) -> Result<String, &'static str> {
    match (action, supports_clipboard_payload, clipboard) {
        (ActionV2::ReadClipboard, true, Some(clipboard)) => Ok(clipboard),
        (ActionV2::ReadClipboard, true, None) => Err("missing clipboard payload"),
        (ActionV2::ReadClipboard, false, None) => Ok(message),
        (ActionV2::ReadClipboard, false, Some(_)) => Err("unnegotiated clipboard payload"),
        (_, _, None) => Ok(message),
        (_, _, Some(_)) => Err("unexpected clipboard payload"),
    }
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

fn is_terminal_device_rejection(message: &str) -> bool {
    message.starts_with("window_refresh_failed:")
        || message.starts_with("application_launch_timeout:")
        || message.starts_with("application_launch_result_unknown:")
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

    #[test]
    fn clipboard_payload_negotiation_controls_model_visible_message() {
        let large_clipboard = "a".repeat(4_097);
        assert_eq!(
            model_message_v2(
                &ActionV2::ReadClipboard,
                true,
                "Clipboard read.".to_owned(),
                Some(large_clipboard.clone()),
            ),
            Ok(large_clipboard)
        );
        assert_eq!(
            model_message_v2(
                &ActionV2::ReadClipboard,
                false,
                "legacy clipboard".to_owned(),
                None,
            ),
            Ok("legacy clipboard".to_owned())
        );
        assert_eq!(
            model_message_v2(
                &ActionV2::ReadClipboard,
                true,
                "Clipboard read.".to_owned(),
                None,
            ),
            Err("missing clipboard payload")
        );
        assert_eq!(
            model_message_v2(
                &ActionV2::ReadClipboard,
                false,
                "legacy clipboard".to_owned(),
                Some("unnegotiated".to_owned()),
            ),
            Err("unnegotiated clipboard payload")
        );
        assert_eq!(
            model_message_v2(
                &ActionV2::Observe { application: None },
                true,
                "Action completed.".to_owned(),
                Some("unexpected".to_owned()),
            ),
            Err("unexpected clipboard payload")
        );
    }
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

    #[test]
    fn managed_context_defaults_missing_authorization_to_legacy_v1() {
        let directory = tempdir().expect("temp directory");
        let path = directory.path().join("context.json");
        let context = test_context(1, Utc::now() + chrono::Duration::seconds(30));
        let mut value = serde_json::to_value(context).expect("serialize context");
        value
            .as_object_mut()
            .expect("context object")
            .remove("authorization_mode");
        value
            .as_object_mut()
            .expect("context object")
            .remove("authorization_policy_version");
        std::fs::write(&path, serde_json::to_vec(&value).expect("encode context"))
            .expect("write context");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .expect("set context permissions");

        let loaded = ManagedContext::load(&path).expect("load legacy context");
        assert_eq!(
            loaded.authorization_mode,
            AuthorizationMode::PerApplicationApproval
        );
        assert_eq!(loaded.authorization_policy_version, 1);

        let mut partial = value;
        partial["authorization_mode"] =
            serde_json::Value::String("per_application_approval".to_owned());
        std::fs::write(
            &path,
            serde_json::to_vec(&partial).expect("encode partial context"),
        )
        .expect("rewrite context");
        assert!(matches!(
            ManagedContext::load(&path),
            Err(TransportError::InvalidContext)
        ));
    }

    #[test]
    fn managed_context_requires_the_complete_full_trust_capability_set() {
        let directory = tempdir().expect("temp directory");
        let path = directory.path().join("context.json");
        let mut context = test_context(1, Utc::now() + chrono::Duration::seconds(30));
        context.authorization_mode = AuthorizationMode::SessionFullTrust;
        context.capabilities = full_trust_capabilities();
        std::fs::write(
            &path,
            serde_json::to_vec(&context).expect("encode full-trust context"),
        )
        .expect("write context");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .expect("set context permissions");

        assert_eq!(
            ManagedContext::load(&path).expect("load full-trust context"),
            context
        );

        context.capabilities.remove(CAPABILITY_GLOBAL_CLIPBOARD_V1);
        std::fs::write(
            &path,
            serde_json::to_vec(&context).expect("encode incomplete context"),
        )
        .expect("rewrite context");
        assert!(matches!(
            ManagedContext::load(&path),
            Err(TransportError::InvalidContext)
        ));
    }

    #[test]
    fn managed_context_rejects_full_trust_capabilities_for_legacy_authorization() {
        let directory = tempdir().expect("temp directory");
        let path = directory.path().join("context.json");
        let mut context = test_context(1, Utc::now() + chrono::Duration::seconds(30));
        context.capabilities = full_trust_capabilities();
        std::fs::write(
            &path,
            serde_json::to_vec(&context).expect("encode legacy context"),
        )
        .expect("write context");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .expect("set context permissions");

        assert!(matches!(
            ManagedContext::load(&path),
            Err(TransportError::InvalidContext)
        ));

        context.capabilities = legacy_v2_capabilities();
        std::fs::write(
            &path,
            serde_json::to_vec(&context).expect("encode bounded legacy context"),
        )
        .expect("rewrite context");
        assert_eq!(
            ManagedContext::load(&path).expect("load bounded legacy context"),
            context
        );
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
    async fn initial_action_context_extends_wait_for_live_bridge_activation() {
        let directory = tempdir().expect("temp directory");
        let context_path = directory.path().join("context.json");
        let bridge_path = directory.path().join("bridge.sock");
        let _listener = tokio::net::UnixListener::bind(&bridge_path).expect("bind bridge socket");
        let context = test_context(1, Utc::now() + chrono::Duration::seconds(60));
        let writer_path = context_path.clone();
        let writer_context = context.clone();
        let writer = tokio::spawn(async move {
            sleep(Duration::from_millis(40)).await;
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&writer_path)
                .expect("create context");
            serde_json::to_writer(&mut file, &writer_context).expect("write context");
        });

        let loaded = load_initial_action_context(
            &context_path,
            &bridge_path,
            Duration::from_millis(10),
            Duration::from_secs(1),
        )
        .await
        .expect("live activation should extend the initial readiness wait");
        assert_eq!(loaded, context);
        writer.await.expect("context writer");
    }

    #[tokio::test]
    async fn initial_action_context_does_not_extend_wait_without_live_bridge() {
        let directory = tempdir().expect("temp directory");
        let context_path = directory.path().join("missing-context.json");
        let bridge_path = directory.path().join("bridge.sock");
        std::fs::write(&bridge_path, b"not a socket").expect("write regular bridge file");

        assert!(matches!(
            load_initial_action_context(
                &context_path,
                &bridge_path,
                Duration::from_millis(10),
                Duration::from_millis(100),
            )
            .await,
            Err(TransportError::NotActivated)
        ));
    }

    #[tokio::test]
    async fn action_context_waits_for_a_failed_generation_to_rotate() {
        let directory = tempdir().expect("temp directory");
        let path = directory.path().join("context.json");
        let initial = test_context(4, Utc::now() + chrono::Duration::seconds(60));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .expect("create initial context");
        serde_json::to_writer(&mut file, &initial).expect("write initial context");

        let replacement_path = path.clone();
        let mut rotated = initial.clone();
        rotated.generation += 1;
        let expected = rotated.clone();
        let writer = tokio::spawn(async move {
            sleep(Duration::from_millis(25)).await;
            let temporary = replacement_path.with_extension("next");
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temporary)
                .expect("create rotated context");
            serde_json::to_writer(&mut file, &rotated).expect("write rotated context");
            std::fs::rename(temporary, replacement_path).expect("publish rotated context");
        });

        let loaded = load_action_context(
            &path,
            Duration::from_secs(1),
            Some((initial.device_session_id, initial.generation)),
        )
        .await
        .expect("rotated generation should become available");
        assert_eq!(loaded, expected);
        writer.await.expect("context writer");
    }

    #[tokio::test]
    async fn action_context_tolerates_a_missing_file_during_generation_rotation() {
        let directory = tempdir().expect("temp directory");
        let path = directory.path().join("context.json");
        let initial = test_context(4, Utc::now() + chrono::Duration::seconds(60));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .expect("create initial context");
        serde_json::to_writer(&mut file, &initial).expect("write initial context");

        let replacement_path = path.clone();
        let mut rotated = initial.clone();
        rotated.generation += 1;
        let expected = rotated.clone();
        let writer = tokio::spawn(async move {
            sleep(Duration::from_millis(25)).await;
            std::fs::remove_file(&replacement_path).expect("remove old context");
            sleep(Duration::from_millis(25)).await;
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&replacement_path)
                .expect("publish rotated context");
            serde_json::to_writer(&mut file, &rotated).expect("write rotated context");
        });

        let loaded = load_action_context(
            &path,
            Duration::from_secs(1),
            Some((initial.device_session_id, initial.generation)),
        )
        .await
        .expect("temporary context absence should be absorbed by recovery");
        assert_eq!(loaded, expected);
        writer.await.expect("context writer");
    }

    #[tokio::test]
    async fn lifecycle_notification_waits_for_and_uses_the_rotated_generation() {
        let directory = tempdir().expect("temp directory");
        let context_path = directory.path().join("context.json");
        let bridge_path = directory.path().join("bridge.sock");
        let listener = UnixListener::bind(&bridge_path).expect("bind bridge socket");
        let initial = test_context(4, Utc::now() + chrono::Duration::seconds(60));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&context_path)
            .expect("create initial context");
        serde_json::to_writer(&mut file, &initial).expect("write initial context");

        let activated = ActivatedUnixDeviceTransport::new(&context_path, &bridge_path);
        activated
            .transport_for_context(initial.clone())
            .await
            .expect("seed initial transport");
        *activated.failed_generation.lock().await =
            Some((initial.device_session_id, initial.generation));

        let mut rotated = initial.clone();
        rotated.generation += 1;
        let replacement_path = context_path.clone();
        let replacement = rotated.clone();
        let writer = tokio::spawn(async move {
            sleep(Duration::from_millis(25)).await;
            let temporary = replacement_path.with_extension("next");
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temporary)
                .expect("create rotated context");
            serde_json::to_writer(&mut file, &replacement).expect("write rotated context");
            std::fs::rename(temporary, replacement_path).expect("publish rotated context");
        });

        let server_context = rotated.clone();
        let server = tokio::spawn(async move {
            let mut tls = accept_test_tls(&listener, &server_context, 0x54).await;
            let lifecycle = read_framed_json(&mut tls).await;
            assert_eq!(lifecycle["lifecycle"]["event"], "turn_stop");
            assert_eq!(
                lifecycle["lifecycle"]["context"]["generation"],
                server_context.generation
            );
            let response = serde_json::json!({
                "request_id": lifecycle["lifecycle"]["request_id"],
                "status": "success"
            });
            write_framed_json(&mut tls, &response).await;
        });

        activated
            .notify_lifecycle(LifecycleEvent::TurnStop)
            .await
            .expect("lifecycle should use the rotated generation");
        assert_eq!(*activated.failed_generation.lock().await, None);
        let active = activated.active.lock().await;
        assert_eq!(
            active.as_ref().expect("active transport").0.generation,
            rotated.generation
        );
        drop(active);
        writer.await.expect("context writer");
        server.await.expect("bridge server");
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

        let context = test_context(2, Utc::now() + chrono::Duration::seconds(30));
        activated
            .transport_for_context(context.clone())
            .await
            .expect("rotated transport");
        let mut changed = context;
        changed.authorization_mode = AuthorizationMode::SessionFullTrust;
        changed.capabilities = full_trust_capabilities();
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
    fn transport_failures_have_a_stable_client_error_code() {
        let error = TransportError::ChannelIo {
            operation: "write length",
            source: std::io::Error::new(std::io::ErrorKind::BrokenPipe, "closed"),
        };

        assert_eq!(
            error.client_message(),
            "transport_unavailable: encrypted device channel write length failed: closed"
        );
        assert_eq!(
            TransportError::GenerationRecoveryTimedOut.client_message(),
            "transport_unavailable: device relay generation did not rotate after the prior transport failure"
        );
        assert_eq!(
            TransportError::DeviceRejected("stale_state: observe again".to_owned())
                .client_message(),
            "device rejected the action: stale_state: observe again"
        );
    }

    #[test]
    fn rejected_device_action_preserves_the_concrete_reason() {
        for code in [
            "clipboard_empty",
            "clipboard_non_text",
            "clipboard_unavailable",
            "clipboard_too_large",
            "clipboard_access_denied",
        ] {
            let error = TransportError::DeviceRejected(format!("{code}: clipboard rejected"));
            assert_eq!(
                error.client_message(),
                format!("device rejected the action: {code}: clipboard rejected")
            );
        }
    }

    #[test]
    fn terminal_window_refresh_rejection_poisons_the_generation() {
        let context = test_context(1, Utc::now() + chrono::Duration::seconds(30));
        let request_id = Uuid::new_v4();
        let request = ActionRequestV2 {
            version: PROTOCOL_VERSION_V2,
            request_id,
            context: RequestContextV2 {
                user_id: context.user_id,
                device_id: context.device_id,
                tool_session_id: context.tool_session_id,
                device_session_id: context.device_session_id,
                node_id: context.node_id,
                platform: context.platform,
                generation: context.generation,
                monotonic_sequence: 1,
                current_state_generation: 0,
                current_screenshot_generation: 0,
                base_state_id: None,
            },
            lease_until: context.lease_until,
            observation: ObservationPolicy::default(),
            action: ActionV2::Observe { application: None },
        };
        let mut state = TransportState {
            context,
            state_id: None,
            state_context: None,
            model_ax_bases: BTreeMap::new(),
            poisoned: false,
            pending_request: None,
            last_completed_response_binding: None,
            connection: None,
        };
        let response = ActionResponseV2 {
            request_id,
            monotonic_sequence: 1,
            state_generation: 0,
            screenshot_generation: 0,
            state_id: None,
            application_digest: None,
            window_id: None,
            display_fingerprint: None,
            base_state_id: None,
            status: ResponseStatusV2::Failed,
            message: "window_refresh_failed: the new window was not confirmed".to_owned(),
            clipboard: None,
            observation: None,
            settle: SettleResult {
                status: crate::protocol_v2::SettleStatus::NotRequested,
                elapsed_ms: 0,
            },
            image: None,
        };

        let error = apply_response_v2(&mut state, &request, response)
            .expect_err("terminal device rejection");
        assert!(matches!(error, TransportError::DeviceRejected(message)
            if message.starts_with("window_refresh_failed:")));
        assert!(state.poisoned);
        assert!(state.connection.is_none());
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
    fn action_context_waits_are_bounded_by_activation_state() {
        assert!(
            INITIAL_ACTION_CONTEXT_READY_WAIT
                + PENDING_ACTIVATION_CONTEXT_READY_WAIT
                + ACTION_LEASE_READY_WAIT
                + MAX_ACTION_RESPONSE_WAIT
                < Duration::from_secs(256)
        );
        assert!(RECOVERY_ACTION_CONTEXT_READY_WAIT < INITIAL_ACTION_CONTEXT_READY_WAIT);
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
    async fn repeated_bridge_handshake_failures_recover_within_the_same_action() {
        let directory = tempdir().expect("temp directory");
        let socket_path = directory.path().join("bridge.sock");
        let listener = UnixListener::bind(&socket_path).expect("bind bridge socket");
        let context = test_context(9, Utc::now() + chrono::Duration::seconds(60));
        let server_context = context.clone();
        let server = tokio::spawn(async move {
            for _ in 0..4 {
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
        let result = transport
            .execute(Action::Screenshot)
            .await
            .expect("same action should recover after handshake failures");
        assert_eq!(result.message, "recovered");
        assert_eq!(result.retry_count, 4);
        let state = transport.state.lock().await;
        assert!(!state.poisoned);
        assert_eq!(state.context.next_sequence, 2);
        drop(state);
        server.await.expect("bridge server");
    }

    #[tokio::test]
    async fn ambiguous_request_recovers_exact_replay_within_the_same_action() {
        let directory = tempdir().expect("temp directory");
        let socket_path = directory.path().join("bridge.sock");
        let listener = UnixListener::bind(&socket_path).expect("bind bridge socket");
        let context = test_context(11, Utc::now() + chrono::Duration::seconds(60));
        let server_context = context.clone();
        let replacement_socket_path = socket_path.clone();
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

            drop(listener);
            std::fs::remove_file(&replacement_socket_path).expect("remove old bridge socket");
            tokio::time::sleep(Duration::from_millis(250)).await;
            let listener =
                UnixListener::bind(&replacement_socket_path).expect("restore bridge socket");
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
        let result = transport
            .execute(Action::Screenshot)
            .await
            .expect("exact replay should recover the original action");
        assert_eq!(result.message, "pending recovered");
        assert!(result.retry_count >= 2);

        let next = transport
            .execute(Action::Wait { duration_ms: 1 })
            .await
            .expect("fresh action after inline replay recovery");
        assert_eq!(next.message, "next action completed");
        let state = transport.state.lock().await;
        assert!(!state.poisoned);
        assert!(state.pending_request.is_none());
        assert_eq!(state.context.next_sequence, 3);
        drop(state);
        server.await.expect("bridge server");
    }

    #[tokio::test]
    async fn terminal_pending_rejection_does_not_start_a_new_action() {
        let directory = tempdir().expect("temp directory");
        let socket_path = directory.path().join("bridge.sock");
        let listener = UnixListener::bind(&socket_path).expect("bind bridge socket");
        let mut context = test_context(12, Utc::now() + chrono::Duration::seconds(60));
        context.capabilities = [
            CAPABILITY_ADAPTIVE_SETTLE_V2.to_owned(),
            CAPABILITY_AX_STATE_V2.to_owned(),
            CAPABILITY_OBSERVATION_MODE_V2.to_owned(),
        ]
        .into_iter()
        .collect();
        let server_context = context.clone();
        let server_socket_path = socket_path.clone();
        let first_server = tokio::spawn(async move {
            let mut tls = accept_test_tls(&listener, &server_context, 0x41).await;
            let request = read_framed_json(&mut tls).await;
            let request = &request["request"];
            assert_eq!(request["context"]["monotonic_sequence"], 1);
            drop(tls);
            drop(listener);
            std::fs::remove_file(server_socket_path).expect("remove bridge socket");
        });

        let transport = Arc::new(UnixDeviceTransport::new(&socket_path, context.clone()));
        let first_action = transport.execute_v2(
            ActionV2::Observe { application: None },
            ObservationPolicy::default(),
        );
        let (server_result, first_result) = tokio::join!(first_server, first_action);
        server_result.expect("first bridge server");
        first_result.expect_err("the disconnected action must be retained as pending");
        {
            let state = transport.state.lock().await;
            assert!(!state.poisoned);
            assert!(state.pending_request.is_some());
        }

        let listener = UnixListener::bind(&socket_path).expect("rebind bridge socket");
        let server_context = context;
        let second_server = tokio::spawn(async move {
            let mut tls = accept_test_tls(&listener, &server_context, 0x42).await;
            let request = read_framed_json(&mut tls).await;
            let request = &request["request"];
            assert_eq!(request["context"]["monotonic_sequence"], 1);
            write_framed_json(
                &mut tls,
                &serde_json::json!({
                    "request_id": request["request_id"],
                    "monotonic_sequence": 1,
                    "state_generation": 0,
                    "screenshot_generation": 0,
                    "status": "failed",
                    "message": "window_refresh_failed: the new window was not confirmed",
                    "settle": {"status": "not_requested", "elapsed_ms": 0}
                }),
            )
            .await;
            if let Ok(Ok(_)) = timeout(Duration::from_millis(250), tls.read_u32()).await {
                panic!("a poisoned generation must not receive a new action")
            }
        });

        let error = transport
            .execute_v2(
                ActionV2::Observe { application: None },
                ObservationPolicy::default(),
            )
            .await
            .expect_err("terminal pending rejection");
        assert!(matches!(error, TransportError::DeviceRejected(message)
            if message.starts_with("window_refresh_failed:")));
        let state = transport.state.lock().await;
        assert!(state.poisoned);
        assert!(state.pending_request.is_none());
        drop(state);
        second_server.await.expect("second bridge server");
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
            CAPABILITY_CLIPBOARD_PAYLOAD_V2.to_owned(),
            CAPABILITY_OBSERVATION_MODE_V2.to_owned(),
        ]
        .into_iter()
        .collect();
        let server_context = context.clone();
        let state_id = Uuid::new_v4();
        let state_id_after_full = Uuid::new_v4();
        let state_id_after_element = Uuid::new_v4();
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
                    "state_generation": 1,
                    "screenshot_generation": 0,
                    "state_id": state_id,
                    "application_digest": "a".repeat(64),
                    "window_id": 7,
                    "display_fingerprint": "display-layout",
                    "status": "success",
                    "message": "Clipboard read.",
                    "clipboard": "clipboard text",
                    "settle": {"status": "not_requested", "elapsed_ms": 0}
                }),
            )
            .await;

            let third = read_framed_json(&mut tls).await;
            let third = &third["request"];
            assert_eq!(third["context"]["monotonic_sequence"], 3);
            assert_eq!(third["context"]["current_state_generation"], 1);
            assert_eq!(third["context"]["base_state_id"], state_id.to_string());
            write_framed_json(
                &mut tls,
                &serde_json::json!({
                    "request_id": third["request_id"],
                    "monotonic_sequence": 3,
                    "state_generation": 1,
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
            assert_eq!(fourth["context"]["current_state_generation"], 1);
            assert_eq!(fourth["context"]["base_state_id"], serde_json::Value::Null);
            assert_eq!(fourth["observation"]["mode"], "ax_full");
            write_framed_json(
                &mut tls,
                &serde_json::json!({
                    "request_id": fourth["request_id"],
                    "monotonic_sequence": 3,
                    "state_generation": 2,
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

            let fifth = read_framed_json(&mut tls).await;
            let fifth = &fifth["request"];
            assert_eq!(fifth["context"]["monotonic_sequence"], 4);
            assert_eq!(fifth["context"]["current_state_generation"], 2);
            assert_eq!(
                fifth["context"]["base_state_id"],
                state_id_after_full.to_string()
            );
            assert_eq!(fifth["action"]["type"], "press");
            write_framed_json(
                &mut tls,
                &serde_json::json!({
                    "request_id": fifth["request_id"],
                    "monotonic_sequence": 4,
                    "state_generation": 3,
                    "screenshot_generation": 0,
                    "state_id": state_id_after_element,
                    "application_digest": "b".repeat(64),
                    "window_id": 8,
                    "display_fingerprint": "other-display",
                    "base_state_id": state_id_after_full,
                    "status": "success",
                    "message": "Action completed.",
                    "observation": {
                        "kind": "diff",
                        "reset": false,
                        "truncated": false,
                        "nodes": [],
                        "removed": []
                    },
                    "settle": {"status": "settled", "elapsed_ms": 10},
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
        assert_eq!(first.state_id, Some(state_id));
        assert_eq!(first.state_generation, 1);
        assert_eq!(first.screenshot_generation, 0);

        let after_clipboard = transport
            .execute_v2(
                ActionV2::ReadClipboard,
                ObservationPolicy {
                    mode: ObservationMode::None,
                    settle: crate::protocol_v2::SettleMode::None,
                    settle_timeout_ms: 0,
                    image_profile: ImageProfile::None,
                    ..ObservationPolicy::default()
                },
            )
            .await
            .expect("clipboard read");
        assert_eq!(after_clipboard.state_id, Some(state_id));
        assert_eq!(after_clipboard.state_generation, 1);
        assert_eq!(after_clipboard.message, "clipboard text");
        assert!(after_clipboard.observation.is_none());

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
        assert_eq!(state.context.current_state_generation, 1);
        assert_eq!(state.context.current_screenshot_generation, 0);
        assert_eq!(
            state
                .state_context
                .as_ref()
                .and_then(|context| state.model_ax_bases.get(context).copied()),
            Some(state_id)
        );
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
        assert_eq!(after_full.state_id, Some(state_id_after_full));
        assert_eq!(after_full.state_generation, 2);
        let state = transport.state.lock().await;
        assert_eq!(state.context.next_sequence, 4);
        assert_eq!(
            state
                .state_context
                .as_ref()
                .and_then(|context| state.model_ax_bases.get(context).copied()),
            Some(state_id_after_full)
        );
        drop(state);

        let after_element = transport
            .execute_v2(
                ActionV2::Press {
                    target: crate::protocol_v2::ElementTarget {
                        state_id: state_id_after_full,
                        state_generation: 2,
                        application_digest: "b".repeat(64),
                        window_id: 8,
                        display_fingerprint: "other-display".to_owned(),
                        element_index: 0,
                    },
                },
                ObservationPolicy::default(),
            )
            .await
            .expect("element action uses its bound state as the diff base");
        assert_eq!(after_element.state_id, Some(state_id_after_element));
        assert_eq!(after_element.base_state_id, Some(state_id_after_full));
        server.await.expect("bridge server");
    }

    #[test]
    fn stateless_global_clipboard_preserves_empty_gui_state() {
        let mut context = test_context(1, Utc::now() + chrono::Duration::seconds(60));
        context.authorization_mode = AuthorizationMode::SessionFullTrust;
        context.capabilities = full_trust_capabilities();
        let mut state = TransportState {
            context: context.clone(),
            state_id: None,
            state_context: None,
            model_ax_bases: BTreeMap::new(),
            poisoned: false,
            pending_request: None,
            last_completed_response_binding: None,
            connection: None,
        };
        let observation = ObservationPolicy {
            mode: ObservationMode::None,
            settle: crate::protocol_v2::SettleMode::None,
            settle_timeout_ms: 0,
            image_profile: ImageProfile::None,
            ..ObservationPolicy::default()
        };
        let request = ActionRequestV2 {
            version: PROTOCOL_VERSION_V2,
            request_id: Uuid::new_v4(),
            context: RequestContextV2 {
                user_id: context.user_id,
                device_id: context.device_id,
                tool_session_id: context.tool_session_id,
                device_session_id: context.device_session_id,
                node_id: context.node_id,
                platform: context.platform,
                generation: context.generation,
                monotonic_sequence: 1,
                current_state_generation: 0,
                current_screenshot_generation: 0,
                base_state_id: None,
            },
            lease_until: context.lease_until,
            observation,
            action: ActionV2::ReadClipboard,
        };
        let response = ActionResponseV2 {
            request_id: request.request_id,
            monotonic_sequence: 1,
            state_generation: 0,
            screenshot_generation: 0,
            state_id: None,
            application_digest: None,
            window_id: None,
            display_fingerprint: None,
            base_state_id: None,
            status: ResponseStatusV2::Success,
            message: "Clipboard read.".to_owned(),
            clipboard: Some("clipboard text".to_owned()),
            observation: None,
            settle: SettleResult {
                status: crate::protocol_v2::SettleStatus::NotRequested,
                elapsed_ms: 0,
            },
            image: None,
        };

        let result = apply_response_v2(&mut state, &request, response)
            .expect("stateless global clipboard response");
        assert_eq!(result.message, "clipboard text");
        assert!(result.state_id.is_none());
        assert_eq!(state.context.next_sequence, 2);
        assert_eq!(state.context.current_state_generation, 0);
        assert!(state.state_id.is_none());
    }

    #[test]
    fn application_launch_is_never_automatically_replayed() {
        assert!(!replayable_action_v2(&ActionV2::LaunchApplication {
            application: "com.apple.TextEdit".to_owned(),
        }));
        assert!(replayable_action_v2(&ActionV2::ReadClipboard));
        assert!(is_terminal_device_rejection(
            "application_launch_timeout: no eligible window"
        ));
        assert!(is_terminal_device_rejection(
            "application_launch_result_unknown: launch state was not verified"
        ));
        assert!(!is_terminal_device_rejection(
            "application_not_found: no eligible application"
        ));
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
            authorization_mode: AuthorizationMode::PerApplicationApproval,
            authorization_policy_version: 1,
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
