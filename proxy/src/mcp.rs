use std::{io::Cursor, path::Path, sync::Arc, time::Instant};

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
        SelectionType, SettleMode,
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
    v2_state: Arc<Mutex<Option<McpBoundState>>>,
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
    /// Approved application display name or bundle identifier.
    pub application: Option<String>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TypeParameters {
    pub text: String,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct InputTextParameters {
    /// Optional image-relative coordinate to focus before typing.
    pub coordinate: Option<Point>,
    /// Optional approved shortcut to send after focusing and before typing.
    pub shortcut_before: Option<String>,
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
    /// Approved application display name or bundle identifier.
    pub application: Option<String>,
    /// Prefer auto; request screenshots only for visual judgment or AX fallback.
    pub mode: Option<ObservationModeParameter>,
    pub image_profile: Option<ImageProfileParameter>,
    pub region: Option<Region>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ActParameters {
    #[serde(rename = "type")]
    pub kind: ActKind,
    pub element_index: Option<u32>,
    pub value: Option<String>,
    pub text: Option<String>,
    pub prefix: Option<String>,
    pub suffix: Option<String>,
    pub selection_type: Option<SelectionTypeParameter>,
    pub direction: Option<ScrollDirectionParameter>,
    pub pages: Option<u8>,
    pub action_name: Option<String>,
    pub coordinate: Option<Point>,
    pub start: Option<Point>,
    pub end: Option<Point>,
    pub key: Option<String>,
    pub delta_x: Option<i32>,
    pub delta_y: Option<i32>,
    pub duration_ms: Option<u32>,
}

#[derive(Debug, Clone, Copy, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ActKind {
    Press,
    SetValue,
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
        let no_element_fields = self.element_index.is_none()
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
            ActKind::SelectText => {
                self.element_index.is_some()
                    && self.text.is_some()
                    && self.value.is_none()
                    && self.direction.is_none()
                    && self.pages.is_none()
                    && self.action_name.is_none()
                    && no_coordinate_fields
            }
            ActKind::ScrollElement => {
                self.element_index.is_some()
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
                        "observe" | "act" | "input_text" | "read_clipboard"
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
            v2_state: Arc::new(Mutex::new(None)),
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
        *self.v2_state.lock().await = None;
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
                return Err(error.to_string());
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
        *self.v2_state.lock().await = None;
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
                        "input sequence stopped at step {} of {total} after {index} completed steps: {error}",
                        index + 1,
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
                return Err(error.to_string());
            }
        };
        self.remember_v2_state(&result).await;
        device_result_v2(result).await
    }

    async fn dispatch_sequence_v2(&self, actions: Vec<Action>) -> Result<CallToolResult, String> {
        if actions.is_empty() || actions.iter().any(|action| !action.validate_parameters()) {
            return Err("action parameters are outside the supported bounds".to_owned());
        }
        let _operation = self.operation_guard.lock().await;
        let total = actions.len();
        let mut final_result = None;
        for (index, action) in actions.into_iter().enumerate() {
            let observation = if index + 1 == total {
                ObservationPolicy::default()
            } else {
                observation_none()
            };
            let action = ActionV2::Coordinate { action };
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
                        "input sequence stopped at step {} of {total} after {index} completed steps: {error}",
                        index + 1,
                    ));
                }
            };
            self.remember_v2_state(&result).await;
            final_result = Some(result);
        }
        device_result_v2(final_result.expect("non-empty sequence produces a result")).await
    }

    async fn remember_v2_state(&self, result: &DeviceResultV2) {
        *self.v2_state.lock().await = Some(McpBoundState {
            state_id: result.state_id,
            state_generation: result.state_generation,
            application_digest: result.application_digest.clone(),
            window_id: result.window_id,
            display_fingerprint: result.display_fingerprint.clone(),
        });
    }

    async fn element_target(&self, element_index: u32) -> Result<ElementTarget, String> {
        let state =
            self.v2_state.lock().await.clone().ok_or_else(|| {
                "observe the application before using an element action".to_owned()
            })?;
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

fn render_v2_result(result: &DeviceResultV2) -> Result<String, String> {
    let mut lines = vec![format!(
        "state={} generation={} screenshot_generation={} settle={:?} elapsed_ms={}",
        result.state_id,
        result.state_generation,
        result.screenshot_generation,
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
            .map_err(|error| error.to_string())?
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
        description = "Act on the latest observed Mac UI. Prefer element_index actions; coordinates require a model-visible screenshot. The result contains the next AX diff by default"
    )]
    async fn act(
        &self,
        Parameters(params): Parameters<ActParameters>,
    ) -> Result<CallToolResult, String> {
        if !params.validate_shape() {
            return Err("act fields do not match the requested action type".to_owned());
        }
        let supports_v2 = self
            .transport
            .supports_v2()
            .await
            .map_err(|error| error.to_string())?;
        let action = match params.kind {
            ActKind::Press => ActionV2::Press {
                target: self
                    .element_target(params.element_index.expect("validated"))
                    .await?,
            },
            ActKind::SetValue => ActionV2::SetValue {
                target: self
                    .element_target(params.element_index.expect("validated"))
                    .await?,
                value: params.value.expect("validated"),
            },
            ActKind::SelectText => ActionV2::SelectText {
                target: self
                    .element_target(params.element_index.expect("validated"))
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
                    .element_target(params.element_index.expect("validated"))
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
                    .element_target(params.element_index.expect("validated"))
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
        self.dispatch_v2(action, ObservationPolicy::default()).await
    }

    #[tool(
        description = "Capture an approved macOS application, bringing the named application to the foreground when provided"
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
        description = "Read bounded text from the Mac clipboard when explicitly approved for the current application session"
    )]
    async fn read_clipboard(&self) -> Result<CallToolResult, String> {
        if self
            .transport
            .supports_v2()
            .await
            .map_err(|error| error.to_string())?
            && self.v2_state.lock().await.is_some()
        {
            return self
                .dispatch_v2(ActionV2::ReadClipboard, ObservationPolicy::default())
                .await;
        }
        self.dispatch(Action::ReadClipboard).await
    }

    #[tool(description = "Click the approved application at image-relative coordinates")]
    async fn left_click(
        &self,
        Parameters(params): Parameters<PointParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::LeftClick {
            coordinate: params.coordinate,
        })
        .await
    }

    #[tool(name = "type", description = "Type text into the approved application")]
    async fn type_text(
        &self,
        Parameters(params): Parameters<TypeParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::Type { text: params.text }).await
    }

    #[tool(
        description = "Focus an optional image coordinate, send an optional shortcut, type text, send an optional final key, optionally wait, and return only the final screenshot. Prefer this for browser address bars, searches, and forms when the intermediate focus changes are deterministic"
    )]
    async fn input_text(
        &self,
        Parameters(params): Parameters<InputTextParameters>,
    ) -> Result<CallToolResult, String> {
        let mut actions = Vec::with_capacity(5);
        if let Some(coordinate) = params.coordinate {
            actions.push(Action::LeftClick { coordinate });
        }
        if let Some(key) = params.shortcut_before {
            actions.push(Action::Key { key });
        }
        actions.push(Action::Type { text: params.text });
        if let Some(key) = params.key_after {
            actions.push(Action::Key { key });
        }
        if let Some(duration_ms) = params.wait_after_ms {
            actions.push(Action::Wait { duration_ms });
        }
        if self
            .transport
            .supports_v2()
            .await
            .map_err(|error| error.to_string())?
        {
            self.dispatch_sequence_v2(actions).await
        } else {
            self.dispatch_sequence(actions).await
        }
    }

    #[tool(description = "Send an approved key or key combination")]
    async fn key(
        &self,
        Parameters(params): Parameters<KeyParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::Key { key: params.key }).await
    }

    #[tool(description = "Move the pointer within the approved image region")]
    async fn mouse_move(
        &self,
        Parameters(params): Parameters<PointParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::MouseMove {
            coordinate: params.coordinate,
        })
        .await
    }

    #[tool(description = "Scroll the approved application")]
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

    #[tool(description = "Drag between image-relative coordinates in the approved application")]
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

    #[tool(description = "Right-click the approved application")]
    async fn right_click(
        &self,
        Parameters(params): Parameters<PointParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::RightClick {
            coordinate: params.coordinate,
        })
        .await
    }

    #[tool(description = "Middle-click the approved application")]
    async fn middle_click(
        &self,
        Parameters(params): Parameters<PointParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::MiddleClick {
            coordinate: params.coordinate,
        })
        .await
    }

    #[tool(description = "Double-click the approved application")]
    async fn double_click(
        &self,
        Parameters(params): Parameters<PointParameters>,
    ) -> Result<CallToolResult, String> {
        self.dispatch(Action::DoubleClick {
            coordinate: params.coordinate,
        })
        .await
    }

    #[tool(description = "Triple-click the approved application")]
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

    #[tool(description = "Hold an approved key for a bounded duration")]
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

    #[tool(description = "Zoom an approved image-relative region when supported")]
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
            "Controls only approved macOS applications. Start with observe, which returns bounded accessibility state or a diff and falls back to a screenshot when needed. Use act with fresh element_index values; use coordinates only from the latest model-visible screenshot. A successful act already returns the next state, so do not observe again immediately. Prefer input_text for deterministic browser address-bar, search, and form prefixes; keep consequential final actions separate for observation and confirmation.",
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

    #[async_trait]
    impl DeviceTransport for SuccessTransport {
        async fn execute(&self, _action: Action) -> Result<DeviceResult, TransportError> {
            Ok(DeviceResult {
                message: "ok".to_owned(),
                screenshot: None,
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
            })
        }
    }

    #[async_trait]
    impl DeviceTransport for ImageTransport {
        async fn execute(&self, _action: Action) -> Result<DeviceResult, TransportError> {
            Ok(DeviceResult {
                message: "ok".to_owned(),
                screenshot: Some(self.screenshot.clone()),
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
    fn token_efficient_surface_exposes_only_four_composable_tools() {
        let server = DeviceMcp::token_efficient(Arc::new(SuccessTransport));
        let mut names: Vec<_> = server
            .tool_router
            .list_all()
            .into_iter()
            .map(|tool| tool.name.into_owned())
            .collect();
        names.sort_unstable();
        assert_eq!(names, ["act", "input_text", "observe", "read_clipboard"]);
    }

    #[test]
    fn compact_act_schema_accepts_each_exact_action_shape() {
        let valid = [
            serde_json::json!({"type": "press", "element_index": 1}),
            serde_json::json!({"type": "set_value", "element_index": 1, "value": "value"}),
            serde_json::json!({"type": "select_text", "element_index": 1, "text": "text", "prefix": "pre", "suffix": "post", "selection_type": "cursor_after"}),
            serde_json::json!({"type": "scroll_element", "element_index": 1, "direction": "down", "pages": 2}),
            serde_json::json!({"type": "secondary_action", "element_index": 1, "action_name": "show_menu"}),
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
        });
        assert!(malformed.is_err());

        let jpeg = encoded_test_image(ImageFormat::Jpeg);
        let mislabeled = device_result(DeviceResult {
            message: "ok".to_owned(),
            screenshot: Some(crate::transport::Screenshot {
                base64_data: STANDARD.encode(jpeg),
                mime_type: "image/png".to_owned(),
            }),
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
