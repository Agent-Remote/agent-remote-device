use std::{collections::BTreeMap, io::Cursor, path::Path, sync::Arc, time::Instant};

use base64::{engine::general_purpose::STANDARD, Engine};
use image::{ImageFormat, ImageReader, Limits};
use rmcp::{
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{CallToolResult, ContentBlock, ServerCapabilities, ServerInfo},
    schemars, tool, tool_handler, tool_router, ServerHandler,
};
use serde::Deserialize;
use tokio::sync::Mutex;
use uuid::Uuid;

use crate::{
    protocol::{Action, Point, Region},
    protocol_v2::{
        ActionV2, ElementTarget, ImageProfile, ObservationMode, ObservationPolicy, ScrollDirection,
        SelectionType, SettleMode, CAPABILITY_APPLICATION_LAUNCH_V1,
        CAPABILITY_GLOBAL_CLIPBOARD_V1,
    },
    telemetry::{OptimizationEvent, OptimizationMetrics, OptimizationSummary},
    transport::{DeviceResult, DeviceResultV2, DeviceTransport},
};

const MAX_DECODED_IMAGE_BYTES: usize = 12 * 1024 * 1024;
const MAX_ENCODED_IMAGE_BYTES: usize = MAX_DECODED_IMAGE_BYTES.div_ceil(3) * 4;
const MAX_IMAGE_DIMENSION: u32 = 4_096;
const MAX_IMAGE_PIXELS: u64 = 4_000_000;
const MAX_IMAGE_DECODE_ALLOCATION_BYTES: u64 = 16 * 1024 * 1024;

#[derive(Clone)]
pub struct DeviceMcp {
    transport: Arc<dyn DeviceTransport>,
    operation_guard: Arc<Mutex<()>>,
    v2_states: Arc<Mutex<BTreeMap<Uuid, McpBoundState>>>,
    optimization_metrics: Arc<Mutex<OptimizationMetrics>>,
    tool_router: ToolRouter<Self>,
}

#[derive(Debug, Clone)]
struct McpBoundState {
    state_id: Uuid,
    state_generation: u64,
    application_digest: String,
    window_id: u32,
    display_fingerprint: String,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PointParameters {
    pub coordinate: Point,
}

#[derive(Debug, Default, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ScreenshotParameters {
    /// Eligible GUI application display name or bundle identifier.
    pub application: Option<String>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TypeParameters {
    pub text: String,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct LaunchApplicationParameters {
    /// Exact installed GUI application Bundle ID or unambiguous display name.
    pub application: String,
}

#[derive(Debug, Clone, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct InputTextParameters {
    /// Optional image-relative coordinate to focus before typing.
    pub coordinate: Option<Point>,
    /// Latest model-visible AX state containing the element to focus.
    pub state_id: Option<String>,
    /// Generation returned with state_id.
    pub state_generation: Option<u64>,
    /// Element index from the state identified by state_id.
    pub element_index: Option<u32>,
    /// Optional approved shortcut to send after focusing and before typing.
    pub shortcut_before: Option<String>,
    /// Text to type. May be empty when the shortcut/key sequence clears existing text.
    pub text: String,
    /// Optional approved key to send after typing, such as Return.
    pub key_after: Option<String>,
    /// Optional bounded wait before returning the final screenshot.
    pub wait_after_ms: Option<u32>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct KeyParameters {
    pub key: String,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ScrollParameters {
    pub delta_x: i32,
    pub delta_y: i32,
    pub coordinate: Option<Point>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct DragParameters {
    pub start: Point,
    pub end: Point,
    pub duration_ms: Option<u32>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HoldKeyParameters {
    pub key: String,
    pub duration_ms: u32,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct WaitParameters {
    pub duration_ms: u32,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ZoomParameters {
    pub region: Region,
}

#[derive(Debug, Clone, Copy, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ObservationModeParameter {
    None,
    AxDiff,
    AxFull,
    Screenshot,
    Both,
    Auto,
}

#[derive(Debug, Clone, Copy, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ImageProfileParameter {
    None,
    Compact,
    Standard,
    Region,
}

#[derive(Debug, Default, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ObserveParameters {
    /// Eligible GUI application display name or bundle identifier. Omit for the frontmost app.
    pub application: Option<String>,
    /// Prefer auto; request screenshots only for visual judgment or AX fallback.
    pub mode: Option<ObservationModeParameter>,
    pub image_profile: Option<ImageProfileParameter>,
    pub region: Option<Region>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ActParameters {
    /// Choose an element action (press, set_value, clear_value, select_text,
    /// scroll_element, secondary_action) or a context action. Do not mix their fields.
    #[serde(rename = "type")]
    pub kind: ActKind,
    /// Element actions only: state identifier returned with element_index.
    pub state_id: Option<String>,
    /// Element actions only: state generation returned with element_index.
    pub state_generation: Option<u64>,
    /// Element actions only. Use type=press to activate/click an AX element;
    /// type=left_click accepts a coordinate instead and never an element_index.
    pub element_index: Option<u32>,
    /// type=set_value only.
    pub value: Option<String>,
    /// type=select_text or type=type only.
    pub text: Option<String>,
    /// type=select_text only.
    pub prefix: Option<String>,
    /// type=select_text only.
    pub suffix: Option<String>,
    /// type=select_text only.
    pub selection_type: Option<SelectionTypeParameter>,
    /// type=scroll_element only. For type=scroll, provide delta_x and delta_y.
    pub direction: Option<ScrollDirectionParameter>,
    /// type=scroll_element only.
    pub pages: Option<u8>,
    /// type=secondary_action only.
    pub action_name: Option<String>,
    /// Coordinate context actions only, from the latest model-visible screenshot.
    pub coordinate: Option<Point>,
    /// type=left_click_drag only.
    pub start: Option<Point>,
    /// type=left_click_drag only.
    pub end: Option<Point>,
    /// type=key or type=hold_key only. Do not include state or element fields.
    pub key: Option<String>,
    /// type=scroll only; delta_x and delta_y are both required.
    pub delta_x: Option<i32>,
    /// type=scroll only; delta_x and delta_y are both required.
    pub delta_y: Option<i32>,
    /// type=left_click_drag or type=hold_key only.
    pub duration_ms: Option<u32>,
    /// Optional adaptive-settle deadline. Omit for the normal 5000 ms maximum;
    /// a short value is useful for explicitly exercising finite timeout recovery.
    pub settle_timeout_ms: Option<u32>,
}

#[derive(Debug, Clone, Copy, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ActKind {
    Press,
    SetValue,
    ClearValue,
    SelectText,
    ScrollElement,
    SecondaryAction,
    LeftClick,
    RightClick,
    MiddleClick,
    DoubleClick,
    TripleClick,
    MouseMove,
    LeftClickDrag,
    LeftMouseDown,
    LeftMouseUp,
    Type,
    Key,
    HoldKey,
    Scroll,
    Wait,
}

#[derive(Debug, Clone, Copy, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SelectionTypeParameter {
    Text,
    CursorBefore,
    CursorAfter,
}

#[derive(Debug, Clone, Copy, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ScrollDirectionParameter {
    Up,
    Down,
    Left,
    Right,
}

impl ActParameters {
    fn validate_shape(&self) -> bool {
        if self
            .settle_timeout_ms
            .is_some_and(|value| !(1..=crate::protocol_v2::MAX_SETTLE_TIMEOUT_MS).contains(&value))
        {
            return false;
        }
        let no_element_fields = self.element_index.is_none()
            && self.state_id.is_none()
            && self.state_generation.is_none()
            && self.value.is_none()
            && self.prefix.is_none()
            && self.suffix.is_none()
            && self.selection_type.is_none()
            && self.direction.is_none()
            && self.pages.is_none()
            && self.action_name.is_none();
        let no_coordinate_fields = self.coordinate.is_none()
            && self.start.is_none()
            && self.end.is_none()
            && self.key.is_none()
            && self.delta_x.is_none()
            && self.delta_y.is_none()
            && self.duration_ms.is_none();
        match self.kind {
            ActKind::Press => {
                self.element_index.is_some()
                    && self.state_id.is_some()
                    && self.state_generation.is_some()
                    && self.value.is_none()
                    && self.text.is_none()
                    && self.prefix.is_none()
                    && self.suffix.is_none()
                    && self.selection_type.is_none()
                    && self.direction.is_none()
                    && self.pages.is_none()
                    && self.action_name.is_none()
                    && no_coordinate_fields
            }
            ActKind::SetValue => {
                self.element_index.is_some()
                    && self.state_id.is_some()
                    && self.state_generation.is_some()
                    && self.value.is_some()
                    && self.text.is_none()
                    && self.prefix.is_none()
                    && self.suffix.is_none()
                    && self.selection_type.is_none()
                    && self.direction.is_none()
                    && self.pages.is_none()
                    && self.action_name.is_none()
                    && no_coordinate_fields
            }
            ActKind::ClearValue => {
                self.element_index.is_some()
                    && self.state_id.is_some()
                    && self.state_generation.is_some()
                    && self.value.is_none()
                    && self.text.is_none()
                    && self.prefix.is_none()
                    && self.suffix.is_none()
                    && self.selection_type.is_none()
                    && self.direction.is_none()
                    && self.pages.is_none()
                    && self.action_name.is_none()
                    && no_coordinate_fields
            }
            ActKind::SelectText => {
                self.element_index.is_some()
                    && self.state_id.is_some()
                    && self.state_generation.is_some()
                    && self.text.is_some()
                    && self.value.is_none()
                    && self.direction.is_none()
                    && self.pages.is_none()
                    && self.action_name.is_none()
                    && no_coordinate_fields
            }
            ActKind::ScrollElement => {
                self.element_index.is_some()
                    && self.state_id.is_some()
                    && self.state_generation.is_some()
                    && self.direction.is_some()
                    && self.value.is_none()
                    && self.text.is_none()
                    && self.prefix.is_none()
                    && self.suffix.is_none()
                    && self.selection_type.is_none()
                    && self.action_name.is_none()
                    && no_coordinate_fields
            }
            ActKind::SecondaryAction => {
                self.element_index.is_some()
                    && self.state_id.is_some()
                    && self.state_generation.is_some()
                    && self.action_name.is_some()
                    && self.value.is_none()
                    && self.text.is_none()
                    && self.prefix.is_none()
                    && self.suffix.is_none()
                    && self.selection_type.is_none()
                    && self.direction.is_none()
                    && self.pages.is_none()
                    && no_coordinate_fields
            }
            ActKind::LeftClick
            | ActKind::RightClick
            | ActKind::MiddleClick
            | ActKind::DoubleClick
            | ActKind::TripleClick
            | ActKind::MouseMove => {
                no_element_fields
                    && self.text.is_none()
                    && self.coordinate.is_some()
                    && self.start.is_none()
                    && self.end.is_none()
                    && self.key.is_none()
                    && self.delta_x.is_none()
                    && self.delta_y.is_none()
                    && self.duration_ms.is_none()
            }
            ActKind::LeftClickDrag => {
                no_element_fields
                    && self.text.is_none()
                    && self.coordinate.is_none()
                    && self.start.is_some()
                    && self.end.is_some()
                    && self.key.is_none()
                    && self.delta_x.is_none()
                    && self.delta_y.is_none()
            }
            ActKind::LeftMouseDown | ActKind::LeftMouseUp => {
                no_element_fields
                    && self.text.is_none()
                    && self.coordinate.is_none()
                    && self.start.is_none()
                    && self.end.is_none()
                    && self.key.is_none()
                    && self.delta_x.is_none()
                    && self.delta_y.is_none()
                    && self.duration_ms.is_none()
            }
            ActKind::Type => {
                no_element_fields
                    && self.text.is_some()
                    && self.coordinate.is_none()
                    && self.start.is_none()
                    && self.end.is_none()
                    && self.key.is_none()
                    && self.delta_x.is_none()
                    && self.delta_y.is_none()
                    && self.duration_ms.is_none()
            }
            ActKind::Key => {
                no_element_fields
                    && self.text.is_none()
                    && self.coordinate.is_none()
                    && self.start.is_none()
                    && self.end.is_none()
                    && self.key.is_some()
                    && self.delta_x.is_none()
                    && self.delta_y.is_none()
                    && self.duration_ms.is_none()
            }
            ActKind::HoldKey => {
                no_element_fields
                    && self.text.is_none()
                    && self.coordinate.is_none()
                    && self.start.is_none()
                    && self.end.is_none()
                    && self.key.is_some()
                    && self.delta_x.is_none()
                    && self.delta_y.is_none()
                    && self.duration_ms.is_some()
            }
            ActKind::Scroll => {
                no_element_fields
                    && self.text.is_none()
                    && self.key.is_none()
                    && self.start.is_none()
                    && self.end.is_none()
                    && self.delta_x.is_some()
                    && self.delta_y.is_some()
                    && self.duration_ms.is_none()
            }
            ActKind::Wait => {
                no_element_fields
                    && self.text.is_none()
                    && self.coordinate.is_none()
                    && self.start.is_none()
                    && self.end.is_none()
                    && self.key.is_none()
                    && self.delta_x.is_none()
                    && self.delta_y.is_none()
                    && self.duration_ms.is_some()
            }
        }
    }

    fn shape_error(&self) -> &'static str {
        match self.kind {
            ActKind::Press => "press requires state_id, state_generation, and element_index",
            ActKind::SetValue => {
                "set_value requires state_id, state_generation, element_index, and value"
            }
            ActKind::ClearValue => {
                "clear_value requires only state_id, state_generation, and element_index"
            }
            ActKind::SelectText => {
                "select_text requires state_id, state_generation, element_index, and text; prefix, suffix, and selection_type are optional"
            }
            ActKind::ScrollElement => {
                "scroll_element requires state_id, state_generation, element_index, and direction; pages is optional"
            }
            ActKind::SecondaryAction => {
                "secondary_action requires state_id, state_generation, element_index, and action_name"
            }
            ActKind::LeftClick
            | ActKind::RightClick
            | ActKind::MiddleClick
            | ActKind::DoubleClick
            | ActKind::TripleClick
            | ActKind::MouseMove => "this coordinate action requires only coordinate",
            ActKind::LeftClickDrag => {
                "left_click_drag requires start and end; duration_ms is optional"
            }
            ActKind::LeftMouseDown | ActKind::LeftMouseUp => {
                "mouse button state actions do not accept additional fields"
            }
            ActKind::Type => "type requires only text",
            ActKind::Key => "key requires only key",
            ActKind::HoldKey => "hold_key requires key and duration_ms",
            ActKind::Scroll => {
                "scroll requires delta_x and delta_y; coordinate is optional; direction is not accepted"
            }
            ActKind::Wait => "wait requires only duration_ms",
        }
    }
}

impl DeviceMcp {
    pub fn new(transport: Arc<dyn DeviceTransport>) -> Self {
        Self::configured(transport, false, None).expect("in-memory metrics cannot fail")
    }

    pub fn token_efficient(transport: Arc<dyn DeviceTransport>) -> Self {
        Self::configured(transport, true, None).expect("in-memory metrics cannot fail")
    }

    pub fn configured(
        transport: Arc<dyn DeviceTransport>,
        compact_tools: bool,
        metrics_path: Option<&Path>,
    ) -> std::io::Result<Self> {
        let mut tool_router = Self::tool_router();
        if compact_tools {
            for name in tool_router
                .list_all()
                .into_iter()
                .map(|tool| tool.name.into_owned())
                .filter(|name| {
                    !matches!(
                        name.as_str(),
                        "observe" | "act" | "input_text" | "launch_application" | "read_clipboard"
                    )
                })
                .collect::<Vec<_>>()
            {
                tool_router.disable_route(name);
            }
        }
        let optimization_metrics = match metrics_path {
            Some(path) => OptimizationMetrics::with_jsonl_sink(path)?,
            None => OptimizationMetrics::default(),
        };
        Ok(Self {
            transport,
            operation_guard: Arc::new(Mutex::new(())),
            v2_states: Arc::new(Mutex::new(BTreeMap::new())),
            optimization_metrics: Arc::new(Mutex::new(optimization_metrics)),
            tool_router,
        })
    }

    pub async fn optimization_summary(&self) -> OptimizationSummary {
        self.optimization_metrics.lock().await.summary()
    }

    async fn dispatch(&self, action: Action) -> Result<CallToolResult, String> {
        if !action.validate_parameters() {
            return Err("action parameters are outside the supported bounds".to_owned());
        }
        let _operation = self.operation_guard.lock().await;
        self.v2_states.lock().await.clear();
        let started = Instant::now();
        let result = match self.transport.execute(action.clone()).await {
            Ok(result) => {
                self.optimization_metrics
                    .lock()
                    .await
                    .record(OptimizationEvent::success_v1(
                        &action,
                        &result,
                        started.elapsed(),
                    ));
                result
            }
            Err(error) => {
                self.optimization_metrics
                    .lock()
                    .await
                    .record(OptimizationEvent::failure_v1(
                        &action,
                        &error,
                        started.elapsed(),
                    ));
                return Err(error.client_message());
            }
        };
        if result.screenshot.is_none() {
            return device_result(result);
        }
        tokio::task::spawn_blocking(move || device_result(result))
            .await
            .map_err(|error| format!("device image validation task failed: {error}"))?
    }

    async fn dispatch_sequence(&self, actions: Vec<Action>) -> Result<CallToolResult, String> {
        if actions.is_empty() || actions.iter().any(|action| !action.validate_parameters()) {
            return Err("action parameters are outside the supported bounds".to_owned());
        }

        let _operation = self.operation_guard.lock().await;
        self.v2_states.lock().await.clear();
        let total = actions.len();
        let mut final_result = None;
        for (index, action) in actions.into_iter().enumerate() {
            let started = Instant::now();
            let result = match self.transport.execute(action.clone()).await {
                Ok(result) => {
                    self.optimization_metrics
                        .lock()
                        .await
                        .record(OptimizationEvent::success_v1(
                            &action,
                            &result,
                            started.elapsed(),
                        ));
                    result
                }
                Err(error) => {
                    self.optimization_metrics
                        .lock()
                        .await
                        .record(OptimizationEvent::failure_v1(
                            &action,
                            &error,
                            started.elapsed(),
                        ));
                    return Err(format!(
                        "input sequence stopped at step {} of {total} after {index} completed steps: {}",
                        index + 1,
                        error.client_message(),
                    ));
                }
            };
            final_result = Some(result);
        }

        let result = final_result.expect("a non-empty sequence must produce a result");
        if result.screenshot.is_none() {
            return device_result(result);
        }
        tokio::task::spawn_blocking(move || device_result(result))
            .await
            .map_err(|error| format!("device image validation task failed: {error}"))?
    }

    async fn dispatch_v2(
        &self,
        action: ActionV2,
        observation: ObservationPolicy,
    ) -> Result<CallToolResult, String> {
        if !action.validate_parameters() || !observation.validate() {
            return Err(
                "v2 action or observation parameters are outside the supported bounds".to_owned(),
            );
        }
        let _operation = self.operation_guard.lock().await;
        let started = Instant::now();
        let result = match self
            .transport
            .execute_v2(action.clone(), observation.clone())
            .await
        {
            Ok(result) => {
                self.optimization_metrics
                    .lock()
                    .await
                    .record(OptimizationEvent::success_v2(
                        &action,
                        &observation,
                        &result,
                        started.elapsed(),
                    ));
                result
            }
            Err(error) => {
                self.optimization_metrics
                    .lock()
                    .await
                    .record(OptimizationEvent::failure_v2(
                        &action,
                        &observation,
                        &error,
                        started.elapsed(),
                    ));
                return Err(error.client_message());
            }
        };
        self.remember_v2_state(&result).await;
        device_result_v2(result).await
    }

    async fn dispatch_clipboard_v2(&self) -> Result<CallToolResult, String> {
        let action = ActionV2::ReadClipboard;
        let observation = observation_none();
        let _operation = self.operation_guard.lock().await;
        let started = Instant::now();
        let result = match self
            .transport
            .execute_v2(action.clone(), observation.clone())
            .await
        {
            Ok(result) => {
                self.optimization_metrics
                    .lock()
                    .await
                    .record(OptimizationEvent::success_v2(
                        &action,
                        &observation,
                        &result,
                        started.elapsed(),
                    ));
                result
            }
            Err(error) => {
                self.optimization_metrics
                    .lock()
                    .await
                    .record(OptimizationEvent::failure_v2(
                        &action,
                        &observation,
                        &error,
                        started.elapsed(),
                    ));
                return Err(error.client_message());
            }
        };
        self.remember_v2_state(&result).await;
        compact_clipboard_result_v2(result)
    }

    async fn dispatch_sequence_v2(&self, actions: Vec<ActionV2>) -> Result<CallToolResult, String> {
        if actions.is_empty() || actions.iter().any(|action| !action.validate_parameters()) {
            return Err("v2 action parameters are outside the supported bounds".to_owned());
        }
        let _operation = self.operation_guard.lock().await;
        let total = actions.len();
        let mut final_result = None;
        for (index, action) in actions.into_iter().enumerate() {
            let typed_text = match &action {
                ActionV2::Coordinate {
                    action: Action::Type { text },
                } => Some(text.clone()),
                _ => None,
            };
            let observation = if index + 1 == total || typed_text.is_some() {
                ObservationPolicy::default()
            } else {
                observation_none()
            };
            let started = Instant::now();
            let result = match self
                .transport
                .execute_v2(action.clone(), observation.clone())
                .await
            {
                Ok(result) => {
                    self.optimization_metrics
                        .lock()
                        .await
                        .record(OptimizationEvent::success_v2(
                            &action,
                            &observation,
                            &result,
                            started.elapsed(),
                        ));
                    result
                }
                Err(error) => {
                    self.optimization_metrics
                        .lock()
                        .await
                        .record(OptimizationEvent::failure_v2(
                            &action,
                            &observation,
                            &error,
                            started.elapsed(),
                        ));
                    return Err(format!(
                        "input sequence stopped at step {} of {total} after {index} completed steps: {}",
                        index + 1,
                        error.client_message(),
                    ));
                }
            };
            self.remember_v2_state(&result).await;
            if let Some(text) = typed_text {
                if typed_text_confirmation(&result, &text) == TypedTextConfirmation::Missing {
                    return Err(format!(
                        "input sequence stopped at step {} of {total}: typed text was not observed in the focused application; no subsequent key was sent",
                        index + 1,
                    ));
                }
            }
            final_result = Some(result);
        }
        device_result_v2(final_result.expect("non-empty sequence produces a result")).await
    }

    async fn remember_v2_state(&self, result: &DeviceResultV2) {
        let (Some(state_id), Some(application_digest), Some(window_id), Some(display_fingerprint)) = (
            result.state_id,
            result.application_digest.as_ref(),
            result.window_id,
            result.display_fingerprint.as_ref(),
        ) else {
            return;
        };
        let mut states = self.v2_states.lock().await;
        states.retain(|_, state| state.application_digest != *application_digest);
        states.insert(
            state_id,
            McpBoundState {
                state_id,
                state_generation: result.state_generation,
                application_digest: application_digest.clone(),
                window_id,
                display_fingerprint: display_fingerprint.clone(),
            },
        );
    }

    async fn element_target(
        &self,
        state_id: &str,
        state_generation: u64,
        element_index: u32,
    ) -> Result<ElementTarget, String> {
        let state_id = Uuid::parse_str(state_id).map_err(|_| {
            "state_id must be a valid UUID from the latest visible state".to_owned()
        })?;
        let state = self.v2_states.lock().await.get(&state_id).cloned();
        let Some(state) = state else {
            return Err(
                "stale_state: element_index is not bound to the latest model-visible state for its application; observe that application again"
                    .to_owned(),
            );
        };
        if state.state_generation != state_generation {
            return Err(
                "stale_state: state_generation does not match the latest model-visible state for its application; use the generation returned with that state_id"
                    .to_owned(),
            );
        }
        Ok(ElementTarget {
            state_id: state.state_id,
            state_generation: state.state_generation,
            application_digest: state.application_digest,
            window_id: state.window_id,
            display_fingerprint: state.display_fingerprint,
            element_index,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TypedTextConfirmation {
    Confirmed,
    Inconclusive,
    Missing,
}

fn typed_text_confirmation(result: &DeviceResultV2, text: &str) -> TypedTextConfirmation {
    let normalized = text.trim().to_lowercase();
    let without_scheme = normalized
        .strip_prefix("https://")
        .or_else(|| normalized.strip_prefix("http://"))
        .unwrap_or(&normalized)
        .trim_end_matches('/');
    let needles = [normalized.as_str(), without_scheme];
    let Some(observation) = result.observation.as_ref() else {
        return TypedTextConfirmation::Inconclusive;
    };
    if observation.nodes.iter().any(|node| {
        [
            node.title.as_deref(),
            node.label.as_deref(),
            node.value.as_deref(),
            node.url.as_deref(),
        ]
        .into_iter()
        .flatten()
        .map(str::to_lowercase)
        .any(|value| {
            needles
                .iter()
                .any(|needle| !needle.is_empty() && value.contains(needle))
        })
    }) {
        return TypedTextConfirmation::Confirmed;
    }
    if observation.truncated
        || matches!(
            observation.kind,
            crate::protocol_v2::AccessibilityObservationKind::Diff
        )
    {
        TypedTextConfirmation::Inconclusive
    } else {
        TypedTextConfirmation::Missing
    }
}

fn input_text_actions(params: InputTextParameters) -> Vec<Action> {
    input_text_actions_with_wait(params, true)
}

fn input_text_actions_v2(
    params: InputTextParameters,
    element_target: Option<ElementTarget>,
) -> Vec<ActionV2> {
    // Every v2 action already uses adaptive settle. A trailing fixed wait would
    // advance the state and replace the typed-text evidence with an empty diff.
    let mut actions = Vec::with_capacity(5);
    if let Some(target) = element_target {
        actions.push(ActionV2::Press { target });
    }
    actions.extend(
        input_text_actions_with_wait(params, false)
            .into_iter()
            .map(|action| ActionV2::Coordinate { action }),
    );
    actions
}

fn input_text_actions_with_wait(
    params: InputTextParameters,
    include_explicit_wait: bool,
) -> Vec<Action> {
    let mut actions = Vec::with_capacity(5);
    if let Some(coordinate) = params.coordinate {
        actions.push(Action::LeftClick { coordinate });
    }
    if let Some(key) = params.shortcut_before {
        actions.push(Action::Key { key });
    }
    if !params.text.is_empty() {
        actions.push(Action::Type { text: params.text });
    }
    if let Some(key) = params.key_after {
        actions.push(Action::Key { key });
    }
    if include_explicit_wait {
        if let Some(duration_ms) = params.wait_after_ms {
            actions.push(Action::Wait { duration_ms });
        }
    }
    actions
}

fn input_text_element_fields(
    params: &InputTextParameters,
) -> Result<Option<(&str, u64, u32)>, String> {
    let fields = (
        params.state_id.as_deref(),
        params.state_generation,
        params.element_index,
    );
    match fields {
        (None, None, None) => Ok(None),
        (Some(state_id), Some(state_generation), Some(element_index)) => {
            if params.coordinate.is_some() {
                return Err(
                    "input_text accepts either an AX element target or coordinate, not both"
                        .to_owned(),
                );
            }
            Ok(Some((state_id, state_generation, element_index)))
        }
        _ => Err(
            "input_text AX focus requires state_id, state_generation, and element_index together"
                .to_owned(),
        ),
    }
}

fn observation_none() -> ObservationPolicy {
    ObservationPolicy {
        mode: ObservationMode::None,
        settle: SettleMode::None,
        settle_timeout_ms: 0,
        image_profile: ImageProfile::None,
        ..ObservationPolicy::default()
    }
}

async fn device_result_v2(result: DeviceResultV2) -> Result<CallToolResult, String> {
    let text = render_v2_result(&result)?;
    let mut content = vec![ContentBlock::text(text)];
    if let Some(image) = result.screenshot {
        let legacy = crate::transport::Screenshot {
            base64_data: image.base64_data,
            mime_type: image.mime_type,
        };
        let block = tokio::task::spawn_blocking(move || validated_image_content(legacy))
            .await
            .map_err(|error| format!("device image validation task failed: {error}"))??;
        content.push(block);
    }
    Ok(CallToolResult::success(content))
}

fn compact_clipboard_result_v2(result: DeviceResultV2) -> Result<CallToolResult, String> {
    if result.observation.is_some() || result.screenshot.is_some() {
        return Err("clipboard response unexpectedly contained visual state".to_owned());
    }
    Ok(CallToolResult::success(vec![ContentBlock::text(format!(
        "clipboard={}",
        json_string(&result.message)?,
    ))]))
}

fn render_v2_result(result: &DeviceResultV2) -> Result<String, String> {
    let state_id = result
        .state_id
        .ok_or_else(|| "device response omitted state_id".to_owned())?;
    let window_id = result
        .window_id
        .ok_or_else(|| "device response omitted window_id".to_owned())?;
    let mut lines = vec![format!(
        "state={} generation={} screenshot_generation={} window_id={} settle={:?} elapsed_ms={}",
        state_id,
        result.state_generation,
        result.screenshot_generation,
        window_id,
        result.settle.status,
        result.settle.elapsed_ms,
    )];
    if result.message != "Action completed." {
        lines.push(format!(
            "message={}",
            serde_json::to_string(&result.message).map_err(|error| error.to_string())?
        ));
    }
    if let Some(observation) = &result.observation {
        lines.push(format!(
            "ax={:?} reset={} truncated={} removed={:?}",
            observation.kind, observation.reset, observation.truncated, observation.removed
        ));
        for node in &observation.nodes {
            let mut fields = vec![format!("[{}]", node.index), format!("role={}", node.role)];
            if let Some(parent) = node.parent_index {
                fields.push(format!("parent={parent}"));
            }
            if let Some(value) = &node.title {
                fields.push(format!("title={}", json_string(value)?));
            }
            if let Some(value) = &node.label {
                fields.push(format!("label={}", json_string(value)?));
            }
            if let Some(value) = &node.value {
                fields.push(format!("value={}", json_string(value)?));
            }
            if let Some(value) = &node.placeholder {
                fields.push(format!("placeholder={}", json_string(value)?));
            }
            if let Some(value) = &node.url {
                fields.push(format!("url={}", json_string(value)?));
            }
            if let Some(frame) = node.frame {
                fields.push(format!("frame={frame:?}"));
            }
            if node.settable {
                fields.push("settable=true".to_owned());
            }
            if !node.actions.is_empty() {
                fields.push(format!("actions={}", node.actions.join(",")));
            }
            lines.push(fields.join(" "));
        }
    }
    Ok(lines.join("\n"))
}

fn json_string(value: &str) -> Result<String, String> {
    serde_json::to_string(value).map_err(|error| error.to_string())
}

fn device_result(result: DeviceResult) -> Result<CallToolResult, String> {
    let mut content = vec![ContentBlock::text(result.message)];
    if let Some(image) = result.screenshot {
        content.push(validated_image_content(image)?);
    }
    Ok(CallToolResult::success(content))
}

fn validated_image_content(image: crate::transport::Screenshot) -> Result<ContentBlock, String> {
    let expected_format = match image.mime_type.as_str() {
        "image/png" => ImageFormat::Png,
        "image/jpeg" => ImageFormat::Jpeg,
        _ => return Err("device returned an unsupported image type".to_owned()),
    };
    if image.base64_data.len() > MAX_ENCODED_IMAGE_BYTES {
        return Err("device returned an image above the size limit".to_owned());
    }
    let decoded = STANDARD
        .decode(&image.base64_data)
        .map_err(|_| "device returned malformed image data".to_owned())?;
    if decoded.len() > MAX_DECODED_IMAGE_BYTES {
        return Err("device returned an image above the size limit".to_owned());
    }
    validate_image(&decoded, expected_format)?;
    Ok(ContentBlock::image(image.base64_data, image.mime_type))
}

fn validate_image(data: &[u8], expected_format: ImageFormat) -> Result<(), String> {
    let mut reader = ImageReader::new(Cursor::new(data))
        .with_guessed_format()
        .map_err(|_| "device returned malformed image data".to_owned())?;
    if reader.format() != Some(expected_format) {
        return Err("device image content does not match its declared type".to_owned());
    }
    reader.limits(image_limits());
    let dimensions = reader
        .into_dimensions()
        .map_err(|_| "device returned malformed image data".to_owned())?;
    if u64::from(dimensions.0) * u64::from(dimensions.1) > MAX_IMAGE_PIXELS {
        return Err("device returned an image above the pixel limit".to_owned());
    }

    let mut decoder = ImageReader::new(Cursor::new(data));
    decoder.set_format(expected_format);
    decoder.limits(image_limits());
    decoder
        .decode()
        .map_err(|_| "device returned malformed image data".to_owned())?;
    Ok(())
}

fn image_limits() -> Limits {
    let mut limits = Limits::default();
    limits.max_image_width = Some(MAX_IMAGE_DIMENSION);
    limits.max_image_height = Some(MAX_IMAGE_DIMENSION);
    limits.max_alloc = Some(MAX_IMAGE_DECODE_ALLOCATION_BYTES);
    limits
}

#[tool_router(router = tool_router)]
impl DeviceMcp {
    #[tool(
        description = "Observe the approved Mac application. Returns a bounded accessibility full state or diff by default and includes a screenshot only when requested or AX is insufficient"
    )]
    async fn observe(
        &self,
        Parameters(params): Parameters<ObserveParameters>,
    ) -> Result<CallToolResult, String> {
        if !self
            .transport
            .supports_v2()
            .await
            .map_err(|error| error.client_message())?
        {
            let action = match params.application {
                Some(application) => Action::ScreenshotApplication { application },
                None => Action::Screenshot,
            };
            return self.dispatch(action).await;
        }
        let application = params.application;
        let policy = observation_policy(params.mode, params.image_profile, params.region)?;
        self.dispatch_v2(ActionV2::Observe { application }, policy)
            .await
    }

    #[tool(
        description = "Act on the latest observed Mac UI. Element forms: press={state_id,state_generation,element_index}; set_value adds value; clear_value uses the same three fields; select_text requires non-empty text and may add prefix, suffix, or selection_type; scroll_element adds direction; secondary_action adds action_name. Use an element form only when the latest node exposes the required AX action; scroll_element needs the matching AXScroll...ByPage action, otherwise use bounded context scroll. Use press, not left_click, for an AX element. Context forms never take state or element fields: key={key}; type={text}; left_click/right_click/middle_click/double_click/triple_click/mouse_move={coordinate}; left_click_drag={start,end,duration_ms?}; scroll={delta_x,delta_y,coordinate?}; wait={duration_ms}. Key uses macOS names and + modifiers, for example cmd+Left, Page Down, Home, cmd+a, or Return. Coordinates require a latest model-visible screenshot. A successful result already contains the next AX diff. settle_timeout_ms is optional and should only be shortened for bounded timeout-path testing"
    )]
    async fn act(
        &self,
        Parameters(params): Parameters<ActParameters>,
    ) -> Result<CallToolResult, String> {
        if !params.validate_shape() {
            return Err(params.shape_error().to_owned());
        }
        let supports_v2 = self
            .transport
            .supports_v2()
            .await
            .map_err(|error| error.client_message())?;
        let settle_timeout_ms = params.settle_timeout_ms;
        let action = match params.kind {
            ActKind::Press => ActionV2::Press {
                target: self
                    .element_target(
                        params.state_id.as_deref().expect("validated"),
                        params.state_generation.expect("validated"),
                        params.element_index.expect("validated"),
                    )
                    .await?,
            },
            ActKind::SetValue => ActionV2::SetValue {
                target: self
                    .element_target(
                        params.state_id.as_deref().expect("validated"),
                        params.state_generation.expect("validated"),
                        params.element_index.expect("validated"),
                    )
                    .await?,
                value: params.value.expect("validated"),
            },
            ActKind::ClearValue => ActionV2::SetValue {
                target: self
                    .element_target(
                        params.state_id.as_deref().expect("validated"),
                        params.state_generation.expect("validated"),
                        params.element_index.expect("validated"),
                    )
                    .await?,
                value: String::new(),
            },
            ActKind::SelectText => ActionV2::SelectText {
                target: self
                    .element_target(
                        params.state_id.as_deref().expect("validated"),
                        params.state_generation.expect("validated"),
                        params.element_index.expect("validated"),
                    )
                    .await?,
                text: params.text.expect("validated"),
                prefix: params.prefix,
                suffix: params.suffix,
                selection_type: match params
                    .selection_type
                    .unwrap_or(SelectionTypeParameter::Text)
                {
                    SelectionTypeParameter::Text => SelectionType::Text,
                    SelectionTypeParameter::CursorBefore => SelectionType::CursorBefore,
                    SelectionTypeParameter::CursorAfter => SelectionType::CursorAfter,
                },
            },
            ActKind::ScrollElement => ActionV2::ScrollElement {
                target: self
                    .element_target(
                        params.state_id.as_deref().expect("validated"),
                        params.state_generation.expect("validated"),
                        params.element_index.expect("validated"),
                    )
                    .await?,
                direction: match params.direction.expect("validated") {
                    ScrollDirectionParameter::Up => ScrollDirection::Up,
                    ScrollDirectionParameter::Down => ScrollDirection::Down,
                    ScrollDirectionParameter::Left => ScrollDirection::Left,
                    ScrollDirectionParameter::Right => ScrollDirection::Right,
                },
                pages: params.pages.unwrap_or(1),
            },
            ActKind::SecondaryAction => ActionV2::SecondaryAction {
                target: self
                    .element_target(
                        params.state_id.as_deref().expect("validated"),
                        params.state_generation.expect("validated"),
                        params.element_index.expect("validated"),
                    )
                    .await?,
                action_name: params.action_name.expect("validated"),
            },
            ActKind::LeftClick => ActionV2::Coordinate {
                action: Action::LeftClick {
                    coordinate: params.coordinate.expect("validated"),
                },
            },
            ActKind::RightClick => ActionV2::Coordinate {
                action: Action::RightClick {
                    coordinate: params.coordinate.expect("validated"),
                },
            },
            ActKind::MiddleClick => ActionV2::Coordinate {
                action: Action::MiddleClick {
                    coordinate: params.coordinate.expect("validated"),
                },
            },
            ActKind::DoubleClick => ActionV2::Coordinate {
                action: Action::DoubleClick {
                    coordinate: params.coordinate.expect("validated"),
                },
            },
            ActKind::TripleClick => ActionV2::Coordinate {
                action: Action::TripleClick {
                    coordinate: params.coordinate.expect("validated"),
                },
            },
            ActKind::MouseMove => ActionV2::Coordinate {
                action: Action::MouseMove {
                    coordinate: params.coordinate.expect("validated"),
                },
            },
            ActKind::LeftClickDrag => ActionV2::Coordinate {
                action: Action::LeftClickDrag {
                    start: params.start.expect("validated"),
                    end: params.end.expect("validated"),
                    duration_ms: params.duration_ms,
                },
            },
            ActKind::LeftMouseDown => ActionV2::Coordinate {
                action: Action::LeftMouseDown,
            },
            ActKind::LeftMouseUp => ActionV2::Coordinate {
                action: Action::LeftMouseUp,
            },
            ActKind::Type => ActionV2::Coordinate {
                action: Action::Type {
                    text: params.text.expect("validated"),
                },
            },
            ActKind::Key => ActionV2::Coordinate {
                action: Action::Key {
                    key: params.key.expect("validated"),
                },
            },
            ActKind::HoldKey => ActionV2::Coordinate {
                action: Action::HoldKey {
                    key: params.key.expect("validated"),
                    duration_ms: params.duration_ms.expect("validated"),
                },
            },
            ActKind::Scroll => ActionV2::Coordinate {
                action: Action::Scroll {
                    delta_x: params.delta_x.expect("validated"),
                    delta_y: params.delta_y.expect("validated"),
                    coordinate: params.coordinate,
                },
            },
            ActKind::Wait => ActionV2::Coordinate {
                action: Action::Wait {
                    duration_ms: params.duration_ms.expect("validated"),
                },
            },
        };
        if !supports_v2 {
            if let ActionV2::Coordinate { action } = action {
                return self.dispatch(action).await;
            }
            return Err("element actions require the negotiated ax_state_v2 capability".to_owned());
        }
        let mut observation = ObservationPolicy::default();
        if let Some(settle_timeout_ms) = settle_timeout_ms {
            observation.settle_timeout_ms = settle_timeout_ms;
        }
        self.dispatch_v2(action, observation).await
    }

    #[tool(
        description = "Capture an eligible macOS application, bringing the named application to the foreground when provided"
    )]
    async fn screenshot(
        &self,
        Parameters(params): Parameters<ScreenshotParameters>,
    ) -> Result<CallToolResult, String> {
        let action = match params.application {
            Some(application) => Action::ScreenshotApplication { application },
            None => Action::Screenshot,
        };
        self.dispatch(action).await
    }

    #[tool(
        description = "Read bounded global plain text from the Mac clipboard under the active local full-trust session"
    )]
    async fn read_clipboard(&self) -> Result<CallToolResult, String> {
        let supports_v2 = self
            .transport
            .supports_v2()
            .await
            .map_err(|error| error.client_message())?;
        let supports_global_clipboard = self
            .transport
            .supports_capability(CAPABILITY_GLOBAL_CLIPBOARD_V1)
            .await
            .map_err(|error| error.client_message())?;
        if supports_v2 && (supports_global_clipboard || !self.v2_states.lock().await.is_empty()) {
            return self.dispatch_clipboard_v2().await;
        }
        self.dispatch(Action::ReadClipboard).await
    }

    #[tool(
        description = "Launch an installed eligible macOS GUI application by exact Bundle ID or unambiguous application name, then return its first full observation. Paths, URLs, arguments, commands, and environment variables are rejected"
    )]
    async fn launch_application(
        &self,
        Parameters(params): Parameters<LaunchApplicationParameters>,
    ) -> Result<CallToolResult, String> {
        if !self
            .transport
            .supports_capability(CAPABILITY_APPLICATION_LAUNCH_V1)
            .await
            .map_err(|error| error.client_message())?
        {
            return Err("unsupported_capability: application_launch_v1 is unavailable".to_owned());
        }
        self.dispatch_v2(
            ActionV2::LaunchApplication {
                application: params.application,
            },
            ObservationPolicy::default(),
        )
        .await
    }

    #[tool(description = "Click the current application at image-relative coordinates")]
    async fn left_click(
        &self,
        Parameters(params): Parameters<PointParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::LeftClick {
            coordinate: params.coordinate,
        })
        .await
    }

    #[tool(name = "type", description = "Type text into the current application")]
    async fn type_text(
        &self,
        Parameters(params): Parameters<TypeParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::Type { text: params.text }).await
    }

    #[tool(
        description = "Optionally focus either a latest-state AX target={state_id,state_generation,element_index} or an image coordinate, then send an optional shortcut, type text, send an optional final key, and return only the final state. Prefer the AX target because it needs no screenshot and removes a separate act press call. The three AX fields are required together and cannot be combined with coordinate. A coordinate requires a latest model-visible screenshot. V2 uses adaptive settle instead of an extra fixed wait"
    )]
    async fn input_text(
        &self,
        Parameters(params): Parameters<InputTextParameters>,
    ) -> Result<CallToolResult, String> {
        let element_fields = input_text_element_fields(&params)?;
        let supports_v2 = self
            .transport
            .supports_v2()
            .await
            .map_err(|error| error.client_message())?;
        let actions_v2 = if supports_v2 {
            let element_target = match element_fields {
                Some((state_id, state_generation, element_index)) => Some(
                    self.element_target(state_id, state_generation, element_index)
                        .await?,
                ),
                None => None,
            };
            Some(input_text_actions_v2(params.clone(), element_target))
        } else {
            if element_fields.is_some() {
                return Err(
                    "input_text AX focus requires the negotiated ax_state_v2 capability".to_owned(),
                );
            }
            None
        };
        let actions_v1 = actions_v2.is_none().then(|| input_text_actions(params));
        let is_empty = actions_v2.as_ref().is_some_and(Vec::is_empty)
            || actions_v1.as_ref().is_some_and(Vec::is_empty);
        if is_empty {
            return Err(
                "input_text requires an AX target, coordinate, shortcut, non-empty text, final key, or wait"
                    .to_owned(),
            );
        }
        if let Some(actions) = actions_v2 {
            self.dispatch_sequence_v2(actions).await
        } else {
            self.dispatch_sequence(actions_v1.expect("v1 actions exist"))
                .await
        }
    }

    #[tool(description = "Send a supported key or key combination")]
    async fn key(
        &self,
        Parameters(params): Parameters<KeyParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::Key { key: params.key }).await
    }

    #[tool(description = "Move the pointer within the current image region")]
    async fn mouse_move(
        &self,
        Parameters(params): Parameters<PointParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::MouseMove {
            coordinate: params.coordinate,
        })
        .await
    }

    #[tool(description = "Scroll the current application")]
    async fn scroll(
        &self,
        Parameters(params): Parameters<ScrollParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::Scroll {
            delta_x: params.delta_x,
            delta_y: params.delta_y,
            coordinate: params.coordinate,
        })
        .await
    }

    #[tool(description = "Drag between image-relative coordinates in the current application")]
    async fn left_click_drag(
        &self,
        Parameters(params): Parameters<DragParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::LeftClickDrag {
            start: params.start,
            end: params.end,
            duration_ms: params.duration_ms,
        })
        .await
    }

    #[tool(description = "Right-click the current application")]
    async fn right_click(
        &self,
        Parameters(params): Parameters<PointParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::RightClick {
            coordinate: params.coordinate,
        })
        .await
    }

    #[tool(description = "Middle-click the current application")]
    async fn middle_click(
        &self,
        Parameters(params): Parameters<PointParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::MiddleClick {
            coordinate: params.coordinate,
        })
        .await
    }

    #[tool(description = "Double-click the current application")]
    async fn double_click(
        &self,
        Parameters(params): Parameters<PointParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::DoubleClick {
            coordinate: params.coordinate,
        })
        .await
    }

    #[tool(description = "Triple-click the current application")]
    async fn triple_click(
        &self,
        Parameters(params): Parameters<PointParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::TripleClick {
            coordinate: params.coordinate,
        })
        .await
    }

    #[tool(description = "Press and hold the left mouse button")]
    async fn left_mouse_down(&self) -> Result<CallToolResult, String> {
        self.dispatch(Action::LeftMouseDown).await
    }

    #[tool(description = "Release the left mouse button")]
    async fn left_mouse_up(&self) -> Result<CallToolResult, String> {
        self.dispatch(Action::LeftMouseUp).await
    }

    #[tool(description = "Hold a supported key for a bounded duration")]
    async fn hold_key(
        &self,
        Parameters(params): Parameters<HoldKeyParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::HoldKey {
            key: params.key,
            duration_ms: params.duration_ms,
        })
        .await
    }

    #[tool(description = "Wait for a bounded duration before taking a new screenshot")]
    async fn wait(
        &self,
        Parameters(params): Parameters<WaitParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::Wait {
            duration_ms: params.duration_ms,
        })
        .await
    }

    #[tool(description = "Zoom the current image-relative region when supported")]
    async fn zoom(
        &self,
        Parameters(params): Parameters<ZoomParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::Zoom {
            region: params.region,
        })
        .await
    }
}

fn observation_policy(
    mode: Option<ObservationModeParameter>,
    image_profile: Option<ImageProfileParameter>,
    region: Option<Region>,
) -> Result<ObservationPolicy, String> {
    let mode = match mode.unwrap_or(ObservationModeParameter::Auto) {
        ObservationModeParameter::None => ObservationMode::None,
        ObservationModeParameter::AxDiff => ObservationMode::AxDiff,
        ObservationModeParameter::AxFull => ObservationMode::AxFull,
        ObservationModeParameter::Screenshot => ObservationMode::Screenshot,
        ObservationModeParameter::Both => ObservationMode::Both,
        ObservationModeParameter::Auto => ObservationMode::Auto,
    };
    let image_profile = match image_profile {
        Some(ImageProfileParameter::None) => ImageProfile::None,
        Some(ImageProfileParameter::Compact) => ImageProfile::Compact,
        Some(ImageProfileParameter::Standard) => ImageProfile::Standard,
        Some(ImageProfileParameter::Region) => ImageProfile::Region,
        None if region.is_some() => ImageProfile::Region,
        None if matches!(mode, ObservationMode::None) => ImageProfile::None,
        None => ImageProfile::Compact,
    };
    let settle = if matches!(mode, ObservationMode::None) {
        SettleMode::None
    } else {
        SettleMode::Auto
    };
    let policy = ObservationPolicy {
        mode,
        settle,
        settle_timeout_ms: if matches!(settle, SettleMode::None) {
            0
        } else {
            crate::protocol_v2::MAX_SETTLE_TIMEOUT_MS
        },
        image_profile,
        region,
        ..ObservationPolicy::default()
    };
    policy
        .validate()
        .then_some(policy)
        .ok_or_else(|| "observation parameters are outside the supported bounds".to_owned())
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for DeviceMcp {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build()).with_instructions(
            "Controls eligible macOS GUI applications within the active local full-trust session. Start with observe, which resolves the named application or the eligible frontmost application and returns bounded accessibility state or a diff, with screenshot fallback when needed. Bind every element operation to the state_id and state_generation returned with its fresh element_index; use coordinates only from the latest model-visible screenshot. A successful operation already returns the next state, so do not observe again immediately. Prefer one AX-targeted input_text call for deterministic address-bar, search, and form sequences; keep consequential final actions separate for observation and confirmation.",
        )
    }
}

#[cfg(test)]
mod tests {
    use std::{
        io::Cursor,
        sync::atomic::{AtomicUsize, Ordering},
        time::Duration,
    };

    use async_trait::async_trait;
    use image::{DynamicImage, GrayImage, ImageFormat, RgbaImage};

    use super::*;
    use crate::transport::{Screenshot, TransportError};

    struct SuccessTransport;

    struct ConcurrentTransport {
        active: AtomicUsize,
        maximum: AtomicUsize,
    }

    struct ImageTransport {
        screenshot: Screenshot,
    }

    struct FullTrustTransport {
        actions: std::sync::Mutex<Vec<ActionV2>>,
    }

    #[async_trait]
    impl DeviceTransport for SuccessTransport {
        async fn execute(&self, _action: Action) -> Result<DeviceResult, TransportError> {
            Ok(DeviceResult {
                message: "ok".to_owned(),
                screenshot: None,
                retry_count: 0,
                manual_recovery: false,
            })
        }
    }

    #[async_trait]
    impl DeviceTransport for ConcurrentTransport {
        async fn execute(&self, _action: Action) -> Result<DeviceResult, TransportError> {
            let active = self.active.fetch_add(1, Ordering::SeqCst) + 1;
            self.maximum.fetch_max(active, Ordering::SeqCst);
            tokio::time::sleep(Duration::from_millis(25)).await;
            self.active.fetch_sub(1, Ordering::SeqCst);
            Ok(DeviceResult {
                message: "ok".to_owned(),
                screenshot: None,
                retry_count: 0,
                manual_recovery: false,
            })
        }
    }

    #[async_trait]
    impl DeviceTransport for ImageTransport {
        async fn execute(&self, _action: Action) -> Result<DeviceResult, TransportError> {
            Ok(DeviceResult {
                message: "ok".to_owned(),
                screenshot: Some(self.screenshot.clone()),
                retry_count: 0,
                manual_recovery: false,
            })
        }
    }

    #[async_trait]
    impl DeviceTransport for FullTrustTransport {
        async fn supports_v2(&self) -> Result<bool, TransportError> {
            Ok(true)
        }

        async fn supports_capability(&self, capability: &str) -> Result<bool, TransportError> {
            Ok(matches!(
                capability,
                CAPABILITY_APPLICATION_LAUNCH_V1 | CAPABILITY_GLOBAL_CLIPBOARD_V1
            ))
        }

        async fn execute(&self, _action: Action) -> Result<DeviceResult, TransportError> {
            Err(TransportError::CapabilityUnavailable)
        }

        async fn execute_v2(
            &self,
            action: ActionV2,
            _observation: ObservationPolicy,
        ) -> Result<DeviceResultV2, TransportError> {
            self.actions
                .lock()
                .expect("full-trust actions lock")
                .push(action.clone());
            let has_state = matches!(action, ActionV2::LaunchApplication { .. });
            Ok(DeviceResultV2 {
                message: if has_state {
                    "Action completed.".to_owned()
                } else {
                    "clipboard text".to_owned()
                },
                state_generation: u64::from(has_state),
                screenshot_generation: 0,
                state_id: has_state.then(Uuid::new_v4),
                application_digest: has_state.then(|| "a".repeat(64)),
                window_id: has_state.then_some(1),
                display_fingerprint: has_state.then(|| "display".to_owned()),
                base_state_id: None,
                observation: None,
                settle: crate::protocol_v2::SettleResult {
                    status: crate::protocol_v2::SettleStatus::NotRequested,
                    elapsed_ms: 0,
                },
                screenshot: None,
                retry_count: 0,
                manual_recovery: false,
            })
        }
    }

    #[test]
    fn exposes_only_the_public_computer_use_actions() {
        let server = DeviceMcp::new(Arc::new(SuccessTransport));
        let mut names: Vec<_> = server
            .tool_router
            .list_all()
            .into_iter()
            .map(|tool| tool.name.into_owned())
            .collect();
        names.sort_unstable();
        assert_eq!(
            names,
            [
                "act",
                "double_click",
                "hold_key",
                "input_text",
                "key",
                "launch_application",
                "left_click",
                "left_click_drag",
                "left_mouse_down",
                "left_mouse_up",
                "middle_click",
                "mouse_move",
                "observe",
                "read_clipboard",
                "right_click",
                "screenshot",
                "scroll",
                "triple_click",
                "type",
                "wait",
                "zoom",
            ]
        );
    }

    #[test]
    fn token_efficient_surface_exposes_full_trust_composable_tools() {
        let server = DeviceMcp::token_efficient(Arc::new(SuccessTransport));
        let mut names: Vec<_> = server
            .tool_router
            .list_all()
            .into_iter()
            .map(|tool| tool.name.into_owned())
            .collect();
        names.sort_unstable();
        assert_eq!(
            names,
            [
                "act",
                "input_text",
                "launch_application",
                "observe",
                "read_clipboard",
            ]
        );
    }

    #[tokio::test]
    async fn full_trust_tools_dispatch_without_a_prior_observation() {
        let transport = Arc::new(FullTrustTransport {
            actions: std::sync::Mutex::new(Vec::new()),
        });
        let server = DeviceMcp::token_efficient(transport.clone());

        server
            .read_clipboard()
            .await
            .expect("stateless global clipboard");
        server
            .launch_application(Parameters(LaunchApplicationParameters {
                application: "com.apple.TextEdit".to_owned(),
            }))
            .await
            .expect("full-trust application launch");

        assert_eq!(
            *transport.actions.lock().expect("full-trust actions lock"),
            [
                ActionV2::ReadClipboard,
                ActionV2::LaunchApplication {
                    application: "com.apple.TextEdit".to_owned(),
                },
            ]
        );
    }

    #[test]
    fn compact_act_schema_accepts_each_exact_action_shape() {
        let server = DeviceMcp::token_efficient(Arc::new(SuccessTransport));
        let act = server
            .tool_router
            .list_all()
            .into_iter()
            .find(|tool| tool.name == "act")
            .expect("compact act tool");
        let input_schema = serde_json::Value::Object((*act.input_schema).clone());
        let action_kinds = input_schema
            .pointer("/$defs/ActKind/enum")
            .and_then(serde_json::Value::as_array)
            .expect("act kind enum");
        assert!(action_kinds.iter().any(|value| value == "hold_key"));
        assert!(input_schema.pointer("/properties/key").is_some());
        assert!(input_schema.pointer("/properties/duration_ms").is_some());

        let valid = [
            serde_json::json!({"type": "press", "state_id": "10000000-0000-4000-8000-000000000001", "state_generation": 1, "element_index": 1}),
            serde_json::json!({"type": "set_value", "state_id": "10000000-0000-4000-8000-000000000001", "state_generation": 1, "element_index": 1, "value": "value"}),
            serde_json::json!({"type": "set_value", "state_id": "10000000-0000-4000-8000-000000000001", "state_generation": 1, "element_index": 1, "value": ""}),
            serde_json::json!({"type": "clear_value", "state_id": "10000000-0000-4000-8000-000000000001", "state_generation": 1, "element_index": 1}),
            serde_json::json!({"type": "select_text", "state_id": "10000000-0000-4000-8000-000000000001", "state_generation": 1, "element_index": 1, "text": "text", "prefix": "pre", "suffix": "post", "selection_type": "cursor_after"}),
            serde_json::json!({"type": "scroll_element", "state_id": "10000000-0000-4000-8000-000000000001", "state_generation": 1, "element_index": 1, "direction": "down", "pages": 2}),
            serde_json::json!({"type": "secondary_action", "state_id": "10000000-0000-4000-8000-000000000001", "state_generation": 1, "element_index": 1, "action_name": "show_menu"}),
            serde_json::json!({"type": "left_click", "coordinate": [10, 20]}),
            serde_json::json!({"type": "right_click", "coordinate": [10, 20]}),
            serde_json::json!({"type": "middle_click", "coordinate": [10, 20]}),
            serde_json::json!({"type": "double_click", "coordinate": [10, 20]}),
            serde_json::json!({"type": "triple_click", "coordinate": [10, 20]}),
            serde_json::json!({"type": "mouse_move", "coordinate": [10, 20]}),
            serde_json::json!({"type": "left_click_drag", "start": [10, 20], "end": [30, 40], "duration_ms": 250}),
            serde_json::json!({"type": "left_mouse_down"}),
            serde_json::json!({"type": "left_mouse_up"}),
            serde_json::json!({"type": "type", "text": "hello"}),
            serde_json::json!({"type": "key", "key": "RETURN"}),
            serde_json::json!({"type": "key", "key": "Page Down", "settle_timeout_ms": 1}),
            serde_json::json!({"type": "hold_key", "key": "SHIFT", "duration_ms": 250}),
            serde_json::json!({"type": "scroll", "delta_x": 0, "delta_y": 400, "coordinate": [10, 20]}),
            serde_json::json!({"type": "wait", "duration_ms": 250}),
        ];

        for value in valid {
            let params: ActParameters = serde_json::from_value(value.clone()).expect("act shape");
            assert!(params.validate_shape(), "expected valid act shape: {value}");
        }

        let invalid: ActParameters = serde_json::from_value(serde_json::json!({
            "type": "press",
            "element_index": 1,
            "coordinate": [10, 20]
        }))
        .expect("known fields");
        assert!(!invalid.validate_shape());

        for settle_timeout_ms in [0, crate::protocol_v2::MAX_SETTLE_TIMEOUT_MS + 1] {
            let invalid_timeout: ActParameters = serde_json::from_value(serde_json::json!({
                "type": "key",
                "key": "RETURN",
                "settle_timeout_ms": settle_timeout_ms
            }))
            .expect("known fields");
            assert!(!invalid_timeout.validate_shape());
        }

        let missing_text: ActParameters = serde_json::from_value(serde_json::json!({
            "type": "select_text",
            "state_id": "10000000-0000-4000-8000-000000000001",
            "state_generation": 1,
            "element_index": 1,
            "selection_type": "text"
        }))
        .expect("known fields");
        assert!(!missing_text.validate_shape());
        assert_eq!(
            missing_text.shape_error(),
            "select_text requires state_id, state_generation, element_index, and text; prefix, suffix, and selection_type are optional"
        );

        let unbound_element: ActParameters = serde_json::from_value(serde_json::json!({
            "type": "press",
            "element_index": 1
        }))
        .expect("known fields");
        assert!(!unbound_element.validate_shape());
        assert_eq!(
            unbound_element.shape_error(),
            "press requires state_id, state_generation, and element_index"
        );

        let clear_with_value: ActParameters = serde_json::from_value(serde_json::json!({
            "type": "clear_value",
            "state_id": "10000000-0000-4000-8000-000000000001",
            "state_generation": 1,
            "element_index": 1,
            "value": ""
        }))
        .expect("known fields");
        assert!(!clear_with_value.validate_shape());
        assert_eq!(
            clear_with_value.shape_error(),
            "clear_value requires only state_id, state_generation, and element_index"
        );

        let conflicting_scroll: ActParameters = serde_json::from_value(serde_json::json!({
            "type": "scroll",
            "direction": "down",
            "delta_x": 0,
            "delta_y": 400
        }))
        .expect("known fields");
        assert!(!conflicting_scroll.validate_shape());
        assert_eq!(
            conflicting_scroll.shape_error(),
            "scroll requires delta_x and delta_y; coordinate is optional; direction is not accepted"
        );
    }

    #[test]
    fn typed_text_confirmation_matches_ax_text_and_normalized_urls() {
        use crate::protocol_v2::{
            AccessibilityNode, AccessibilityObservation, AccessibilityObservationKind,
            SettleResult, SettleStatus,
        };

        let result_with_value = |value: Option<&str>, url: Option<&str>| DeviceResultV2 {
            message: "ok".to_owned(),
            state_generation: 1,
            screenshot_generation: 0,
            state_id: Some(Uuid::new_v4()),
            application_digest: Some("a".repeat(64)),
            window_id: Some(1),
            display_fingerprint: Some("display".to_owned()),
            base_state_id: None,
            observation: Some(AccessibilityObservation {
                kind: AccessibilityObservationKind::Full,
                reset: false,
                truncated: false,
                nodes: vec![AccessibilityNode {
                    index: 0,
                    parent_index: None,
                    depth: 0,
                    role: "AXTextField".to_owned(),
                    title: None,
                    label: None,
                    value: value.map(str::to_owned),
                    placeholder: None,
                    url: url.map(str::to_owned),
                    frame: None,
                    settable: true,
                    actions: vec![],
                }],
                removed: vec![],
            }),
            settle: SettleResult {
                status: SettleStatus::Settled,
                elapsed_ms: 10,
            },
            screenshot: None,
            retry_count: 0,
            manual_recovery: false,
        };

        assert_eq!(
            typed_text_confirmation(
                &result_with_value(Some("Computer use test query"), None),
                "computer use test"
            ),
            TypedTextConfirmation::Confirmed
        );
        assert_eq!(
            typed_text_confirmation(
                &result_with_value(None, Some("https://example.com/path/")),
                "http://example.com/path"
            ),
            TypedTextConfirmation::Confirmed
        );
        assert_eq!(
            typed_text_confirmation(
                &result_with_value(Some("different query"), Some("https://example.com/")),
                "missing text"
            ),
            TypedTextConfirmation::Missing
        );

        let mut truncated = result_with_value(Some("different query"), None);
        truncated
            .observation
            .as_mut()
            .expect("observation")
            .truncated = true;
        assert_eq!(
            typed_text_confirmation(&truncated, "missing text"),
            TypedTextConfirmation::Inconclusive
        );

        let mut diff = result_with_value(Some("different query"), None);
        diff.observation.as_mut().expect("observation").kind = AccessibilityObservationKind::Diff;
        assert_eq!(
            typed_text_confirmation(&diff, "missing text"),
            TypedTextConfirmation::Inconclusive
        );
    }

    #[test]
    fn rendered_v2_state_includes_the_selected_window_id() {
        use crate::protocol_v2::{SettleResult, SettleStatus};

        let result = DeviceResultV2 {
            message: "Action completed.".to_owned(),
            state_generation: 3,
            screenshot_generation: 2,
            state_id: Some(Uuid::new_v4()),
            application_digest: Some("a".repeat(64)),
            window_id: Some(42),
            display_fingerprint: Some("display".to_owned()),
            base_state_id: None,
            observation: None,
            settle: SettleResult {
                status: SettleStatus::Settled,
                elapsed_ms: 10,
            },
            screenshot: None,
            retry_count: 0,
            manual_recovery: false,
        };

        let rendered = render_v2_result(&result).expect("render v2 result");
        assert!(rendered.contains("screenshot_generation=2 window_id=42 settle=Settled"));
    }

    #[test]
    fn compact_clipboard_output_omits_ax_image_and_settle_metadata() {
        use crate::protocol_v2::{SettleResult, SettleStatus};

        let state_id = Uuid::new_v4();
        let result = compact_clipboard_result_v2(DeviceResultV2 {
            message: "Clipboard v2 test".to_owned(),
            state_generation: 9,
            screenshot_generation: 4,
            state_id: Some(state_id),
            application_digest: Some("a".repeat(64)),
            window_id: Some(1),
            display_fingerprint: Some("display".to_owned()),
            base_state_id: None,
            observation: None,
            settle: SettleResult {
                status: SettleStatus::Settled,
                elapsed_ms: 1_234,
            },
            screenshot: None,
            retry_count: 0,
            manual_recovery: false,
        })
        .expect("compact clipboard result");
        let encoded = serde_json::to_string(&result).expect("serialize MCP result");

        assert!(encoded.contains("Clipboard v2 test"));
        assert!(!encoded.contains(&state_id.to_string()));
        assert!(!encoded.contains("generation=9"));
        assert!(!encoded.contains("settle"));
        assert!(!encoded.contains("elapsed_ms"));
        assert!(!encoded.contains("screenshot_generation"));
        assert!(!encoded.contains("ax="));
    }

    #[test]
    fn empty_input_text_omits_type_but_keeps_clear_shortcuts() {
        let actions = input_text_actions(InputTextParameters {
            coordinate: Some([320, 240]),
            state_id: None,
            state_generation: None,
            element_index: None,
            shortcut_before: Some("CMD+A".to_owned()),
            text: String::new(),
            key_after: Some("DELETE".to_owned()),
            wait_after_ms: None,
        });
        assert_eq!(
            actions,
            vec![
                Action::LeftClick {
                    coordinate: [320, 240]
                },
                Action::Key {
                    key: "CMD+A".to_owned()
                },
                Action::Key {
                    key: "DELETE".to_owned()
                }
            ]
        );
        assert!(input_text_actions(InputTextParameters {
            coordinate: None,
            state_id: None,
            state_generation: None,
            element_index: None,
            shortcut_before: None,
            text: String::new(),
            key_after: None,
            wait_after_ms: None,
        })
        .is_empty());
    }

    #[test]
    fn v2_input_text_uses_adaptive_settle_without_a_trailing_wait_state() {
        let actions = input_text_actions_v2(
            InputTextParameters {
                coordinate: None,
                state_id: None,
                state_generation: None,
                element_index: None,
                shortcut_before: None,
                text: "typed text".to_owned(),
                key_after: None,
                wait_after_ms: Some(300),
            },
            None,
        );
        assert_eq!(
            actions,
            vec![ActionV2::Coordinate {
                action: Action::Type {
                    text: "typed text".to_owned()
                }
            }]
        );
    }

    #[test]
    fn v2_input_text_can_focus_a_bound_ax_element_in_the_same_sequence() {
        let state_id = Uuid::new_v4();
        let target = ElementTarget {
            state_id,
            state_generation: 7,
            application_digest: "application".to_owned(),
            window_id: 9,
            display_fingerprint: "display".to_owned(),
            element_index: 12,
        };
        let actions = input_text_actions_v2(
            InputTextParameters {
                coordinate: None,
                state_id: Some(state_id.to_string()),
                state_generation: Some(7),
                element_index: Some(12),
                shortcut_before: Some("CMD+A".to_owned()),
                text: "https://example.com".to_owned(),
                key_after: Some("Return".to_owned()),
                wait_after_ms: None,
            },
            Some(target.clone()),
        );

        assert_eq!(
            actions,
            vec![
                ActionV2::Press { target },
                ActionV2::Coordinate {
                    action: Action::Key {
                        key: "CMD+A".to_owned()
                    }
                },
                ActionV2::Coordinate {
                    action: Action::Type {
                        text: "https://example.com".to_owned()
                    }
                },
                ActionV2::Coordinate {
                    action: Action::Key {
                        key: "Return".to_owned()
                    }
                },
            ]
        );
    }

    #[test]
    fn input_text_rejects_partial_or_mixed_ax_targets() {
        let partial = InputTextParameters {
            coordinate: None,
            state_id: Some(Uuid::new_v4().to_string()),
            state_generation: None,
            element_index: Some(1),
            shortcut_before: None,
            text: "text".to_owned(),
            key_after: None,
            wait_after_ms: None,
        };
        assert!(input_text_element_fields(&partial)
            .expect_err("partial target must fail")
            .contains("requires state_id"));

        let mixed = InputTextParameters {
            coordinate: Some([10, 20]),
            state_id: Some(Uuid::new_v4().to_string()),
            state_generation: Some(1),
            element_index: Some(1),
            shortcut_before: None,
            text: "text".to_owned(),
            key_after: None,
            wait_after_ms: None,
        };
        assert!(input_text_element_fields(&mixed)
            .expect_err("mixed targets must fail")
            .contains("not both"));
    }

    #[tokio::test]
    async fn dispatch_records_only_aggregate_optimization_metrics() {
        let server = DeviceMcp::token_efficient(Arc::new(SuccessTransport));
        server
            .dispatch(Action::Wait { duration_ms: 50 })
            .await
            .expect("dispatch");

        let summary = server.optimization_summary().await;
        assert_eq!(summary.tool_calls, 1);
        assert_eq!(summary.v1_calls, 1);
        assert_eq!(summary.successful_calls, 1);
        assert_eq!(summary.model_visible_images, 0);
    }

    #[tokio::test]
    async fn element_target_rejects_a_model_visible_stale_state() {
        let server = DeviceMcp::token_efficient(Arc::new(SuccessTransport));
        let current_state_id = Uuid::new_v4();
        server.v2_states.lock().await.insert(
            current_state_id,
            McpBoundState {
                state_id: current_state_id,
                state_generation: 7,
                application_digest: "a".repeat(64),
                window_id: 1,
                display_fingerprint: "display".to_owned(),
            },
        );

        let error = server
            .element_target(&Uuid::new_v4().to_string(), 6, 12)
            .await
            .expect_err("stale state must fail before dispatch");
        assert!(error.starts_with("stale_state:"));

        let target = server
            .element_target(&current_state_id.to_string(), 7, 12)
            .await
            .expect("latest state");
        assert_eq!(target.state_id, current_state_id);
        assert_eq!(target.state_generation, 7);
        assert_eq!(target.element_index, 12);
    }

    #[tokio::test]
    async fn element_target_keeps_the_latest_state_for_each_application() {
        let server = DeviceMcp::token_efficient(Arc::new(SuccessTransport));
        let first_state_id = Uuid::new_v4();
        let second_state_id = Uuid::new_v4();
        server.v2_states.lock().await.insert(
            first_state_id,
            McpBoundState {
                state_id: first_state_id,
                state_generation: 1,
                application_digest: "a".repeat(64),
                window_id: 1,
                display_fingerprint: "display".to_owned(),
            },
        );
        server.v2_states.lock().await.insert(
            second_state_id,
            McpBoundState {
                state_id: second_state_id,
                state_generation: 2,
                application_digest: "b".repeat(64),
                window_id: 2,
                display_fingerprint: "display".to_owned(),
            },
        );

        let target = server
            .element_target(&first_state_id.to_string(), 1, 12)
            .await
            .expect("first application remains model-visible");
        assert_eq!(target.state_id, first_state_id);
    }

    #[tokio::test]
    async fn rejects_out_of_bounds_duration_before_transport() {
        let server = DeviceMcp::new(Arc::new(SuccessTransport));
        assert!(server
            .dispatch(Action::Wait { duration_ms: 49 })
            .await
            .is_err());
    }

    #[tokio::test]
    async fn serializes_concurrent_tool_calls_across_cloned_handlers() {
        let transport = Arc::new(ConcurrentTransport {
            active: AtomicUsize::new(0),
            maximum: AtomicUsize::new(0),
        });
        let server = DeviceMcp::new(transport.clone());
        let clone = server.clone();

        let (first, second) = tokio::join!(
            server.dispatch(Action::Screenshot),
            clone.dispatch(Action::Wait { duration_ms: 50 })
        );

        assert!(first.is_ok());
        assert!(second.is_ok());
        assert_eq!(transport.maximum.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn accepts_a_bounded_image_through_the_blocking_decoder() {
        let png = encoded_test_image(ImageFormat::Png);
        let server = DeviceMcp::new(Arc::new(ImageTransport {
            screenshot: Screenshot {
                base64_data: STANDARD.encode(png),
                mime_type: "image/png".to_owned(),
            },
        }));

        assert!(server.dispatch(Action::Screenshot).await.is_ok());
    }

    #[tokio::test]
    async fn input_sequence_executes_in_order_and_returns_only_the_final_result() {
        struct RecordingTransport {
            actions: std::sync::Mutex<Vec<Action>>,
            screenshot: Screenshot,
        }

        #[async_trait]
        impl DeviceTransport for RecordingTransport {
            async fn execute(&self, action: Action) -> Result<DeviceResult, TransportError> {
                self.actions.lock().expect("recording lock").push(action);
                Ok(DeviceResult {
                    message: "ok".to_owned(),
                    screenshot: Some(self.screenshot.clone()),
                    retry_count: 0,
                    manual_recovery: false,
                })
            }
        }

        let png = encoded_test_image(ImageFormat::Png);
        let transport = Arc::new(RecordingTransport {
            actions: std::sync::Mutex::new(Vec::new()),
            screenshot: Screenshot {
                base64_data: STANDARD.encode(png),
                mime_type: "image/png".to_owned(),
            },
        });
        let server = DeviceMcp::new(transport.clone());

        let result = server
            .dispatch_sequence(vec![
                Action::Key {
                    key: "CMD+L".to_owned(),
                },
                Action::Type {
                    text: "https://example.com".to_owned(),
                },
                Action::Key {
                    key: "RETURN".to_owned(),
                },
                Action::Wait { duration_ms: 250 },
            ])
            .await
            .expect("sequence succeeds");

        assert_eq!(result.content.len(), 2, "text plus only the final image");
        assert_eq!(
            *transport.actions.lock().expect("recording lock"),
            vec![
                Action::Key {
                    key: "CMD+L".to_owned(),
                },
                Action::Type {
                    text: "https://example.com".to_owned(),
                },
                Action::Key {
                    key: "RETURN".to_owned(),
                },
                Action::Wait { duration_ms: 250 },
            ]
        );
    }

    #[tokio::test]
    async fn input_sequence_validates_every_step_before_execution() {
        let server = DeviceMcp::new(Arc::new(SuccessTransport));
        let result = server
            .dispatch_sequence(vec![
                Action::Type {
                    text: "valid".to_owned(),
                },
                Action::Key {
                    key: "not/a/key".to_owned(),
                },
            ])
            .await;

        assert_eq!(
            result.expect_err("invalid key must fail before execution"),
            "action parameters are outside the supported bounds"
        );
    }

    #[tokio::test]
    async fn input_sequence_stops_after_the_first_failed_step() {
        struct FailingTransport {
            calls: AtomicUsize,
        }

        #[async_trait]
        impl DeviceTransport for FailingTransport {
            async fn execute(&self, _action: Action) -> Result<DeviceResult, TransportError> {
                let call = self.calls.fetch_add(1, Ordering::SeqCst);
                if call == 1 {
                    return Err(TransportError::DeviceRejected("test rejection".to_owned()));
                }
                Ok(DeviceResult {
                    message: "ok".to_owned(),
                    screenshot: None,
                    retry_count: 0,
                    manual_recovery: false,
                })
            }
        }

        let transport = Arc::new(FailingTransport {
            calls: AtomicUsize::new(0),
        });
        let server = DeviceMcp::new(transport.clone());
        let error = server
            .dispatch_sequence(vec![
                Action::Key {
                    key: "CMD+L".to_owned(),
                },
                Action::Type {
                    text: "https://example.com".to_owned(),
                },
                Action::Key {
                    key: "RETURN".to_owned(),
                },
            ])
            .await
            .expect_err("second step must fail");

        assert_eq!(transport.calls.load(Ordering::SeqCst), 2);
        assert!(error.contains("step 2 of 3 after 1 completed steps"));
        assert!(error.contains("test rejection"));
    }

    #[test]
    fn rejects_malformed_and_mislabeled_images() {
        let malformed = device_result(DeviceResult {
            message: "ok".to_owned(),
            screenshot: Some(crate::transport::Screenshot {
                base64_data: STANDARD.encode(b"not an image"),
                mime_type: "image/png".to_owned(),
            }),
            retry_count: 0,
            manual_recovery: false,
        });
        assert!(malformed.is_err());

        let jpeg = encoded_test_image(ImageFormat::Jpeg);
        let mislabeled = device_result(DeviceResult {
            message: "ok".to_owned(),
            screenshot: Some(crate::transport::Screenshot {
                base64_data: STANDARD.encode(jpeg),
                mime_type: "image/png".to_owned(),
            }),
            retry_count: 0,
            manual_recovery: false,
        });
        assert!(mislabeled.is_err());
    }

    #[test]
    fn rejects_images_above_the_pixel_limit_before_full_decode() {
        let image = DynamicImage::ImageLuma8(GrayImage::from_pixel(2_001, 2_000, image::Luma([0])));
        let mut png = Vec::new();
        image
            .write_to(&mut Cursor::new(&mut png), ImageFormat::Png)
            .expect("encode high-compression test image");

        assert_eq!(
            validate_image(&png, ImageFormat::Png),
            Err("device returned an image above the pixel limit".to_owned())
        );
    }

    fn encoded_test_image(format: ImageFormat) -> Vec<u8> {
        let image =
            DynamicImage::ImageRgba8(RgbaImage::from_pixel(2, 2, image::Rgba([0, 0, 0, 255])));
        let mut encoded = Vec::new();
        image
            .write_to(&mut Cursor::new(&mut encoded), format)
            .expect("encode test image");
        encoded
    }
}
