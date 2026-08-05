use std::{
    fs::{File, OpenOptions},
    io::{self, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::Path,
    time::Duration,
};

use serde::{Deserialize, Serialize};

use crate::{
    protocol::Action,
    protocol_v2::{ActionV2, ObservationMode, ObservationPolicy, SettleStatus},
    transport::{DeviceResult, DeviceResultV2, TransportError},
};

pub const OPTIMIZATION_METRIC_SCHEMA_VERSION: u8 = 1;
const MAX_METRICS_FILE_BYTES: u64 = 16 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExecutionPath {
    V1,
    V2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MetricAction {
    Observe,
    Coordinate,
    Press,
    SetValue,
    SelectText,
    ScrollElement,
    SecondaryAction,
    ReadClipboard,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MetricOutcome {
    Success,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MetricErrorCode {
    CapabilityUnavailable,
    InvalidRequest,
    LeaseExpired,
    OperationTimeout,
    ResponseBinding,
    StaleTarget,
    DeviceRejected,
    Transport,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OptimizationEvent {
    pub schema_version: u8,
    pub path: ExecutionPath,
    pub action: MetricAction,
    pub observation_mode: Option<ObservationMode>,
    pub outcome: MetricOutcome,
    pub error_code: Option<MetricErrorCode>,
    pub node_count: u16,
    pub removed_count: u16,
    pub ax_bytes: u32,
    pub image_bytes: u32,
    pub bridge_bytes: u32,
    pub action_latency_ms: u32,
    pub settle_latency_ms: u32,
    pub settle_status: Option<SettleStatus>,
    pub model_visible_image: bool,
    pub coordinate_fallback: bool,
    pub stale_target: bool,
    pub retry_count: u16,
    pub manual_recovery: bool,
}

impl OptimizationEvent {
    pub fn success_v1(action: &Action, result: &DeviceResult, elapsed: Duration) -> Self {
        let image_bytes = result
            .screenshot
            .as_ref()
            .map(|image| bounded_u32(image.base64_data.len()))
            .unwrap_or(0);
        Self {
            schema_version: OPTIMIZATION_METRIC_SCHEMA_VERSION,
            path: ExecutionPath::V1,
            action: metric_action_v1(action),
            observation_mode: Some(ObservationMode::Screenshot),
            outcome: MetricOutcome::Success,
            error_code: None,
            node_count: 0,
            removed_count: 0,
            ax_bytes: 0,
            image_bytes,
            bridge_bytes: image_bytes,
            action_latency_ms: duration_ms(elapsed),
            settle_latency_ms: 0,
            settle_status: None,
            model_visible_image: result.screenshot.is_some(),
            coordinate_fallback: false,
            stale_target: false,
            retry_count: 0,
            manual_recovery: false,
        }
    }

    pub fn failure_v1(action: &Action, error: &TransportError, elapsed: Duration) -> Self {
        Self {
            schema_version: OPTIMIZATION_METRIC_SCHEMA_VERSION,
            path: ExecutionPath::V1,
            action: metric_action_v1(action),
            observation_mode: Some(ObservationMode::Screenshot),
            outcome: MetricOutcome::Failed,
            error_code: Some(metric_error(error)),
            node_count: 0,
            removed_count: 0,
            ax_bytes: 0,
            image_bytes: 0,
            bridge_bytes: 0,
            action_latency_ms: duration_ms(elapsed),
            settle_latency_ms: 0,
            settle_status: None,
            model_visible_image: false,
            coordinate_fallback: false,
            stale_target: false,
            retry_count: 0,
            manual_recovery: false,
        }
    }

    pub fn success_v2(
        action: &ActionV2,
        policy: &ObservationPolicy,
        result: &DeviceResultV2,
        elapsed: Duration,
    ) -> Self {
        let (node_count, removed_count, ax_bytes) = result
            .observation
            .as_ref()
            .map(|observation| {
                (
                    bounded_u16(observation.nodes.len()),
                    bounded_u16(observation.removed.len()),
                    serde_json::to_vec(observation)
                        .map(|value| bounded_u32(value.len()))
                        .unwrap_or(0),
                )
            })
            .unwrap_or((0, 0, 0));
        let image_bytes = result
            .screenshot
            .as_ref()
            .map(|image| bounded_u32(image.base64_data.len()))
            .unwrap_or(0);
        let coordinate = matches!(action, ActionV2::Coordinate { .. });
        Self {
            schema_version: OPTIMIZATION_METRIC_SCHEMA_VERSION,
            path: ExecutionPath::V2,
            action: metric_action_v2(action),
            observation_mode: Some(policy.mode),
            outcome: MetricOutcome::Success,
            error_code: None,
            node_count,
            removed_count,
            ax_bytes,
            image_bytes,
            bridge_bytes: ax_bytes.saturating_add(image_bytes),
            action_latency_ms: duration_ms(elapsed),
            settle_latency_ms: result.settle.elapsed_ms,
            settle_status: Some(result.settle.status),
            model_visible_image: result.screenshot.is_some(),
            coordinate_fallback: coordinate,
            stale_target: false,
            retry_count: 0,
            manual_recovery: false,
        }
    }

    pub fn failure_v2(
        action: &ActionV2,
        policy: &ObservationPolicy,
        error: &TransportError,
        elapsed: Duration,
    ) -> Self {
        let error_code = metric_error(error);
        let stale_target = matches!(error_code, MetricErrorCode::StaleTarget);
        Self {
            schema_version: OPTIMIZATION_METRIC_SCHEMA_VERSION,
            path: ExecutionPath::V2,
            action: metric_action_v2(action),
            observation_mode: Some(policy.mode),
            outcome: MetricOutcome::Failed,
            error_code: Some(error_code),
            node_count: 0,
            removed_count: 0,
            ax_bytes: 0,
            image_bytes: 0,
            bridge_bytes: 0,
            action_latency_ms: duration_ms(elapsed),
            settle_latency_ms: 0,
            settle_status: None,
            model_visible_image: false,
            coordinate_fallback: false,
            stale_target,
            retry_count: 0,
            manual_recovery: false,
        }
    }
}

#[derive(Debug, Default)]
pub struct OptimizationMetrics {
    events: Vec<OptimizationEvent>,
    sink: Option<MetricsSink>,
}

#[derive(Debug)]
struct MetricsSink {
    file: File,
    bytes_written: u64,
}

impl OptimizationMetrics {
    pub fn with_jsonl_sink(path: &Path) -> io::Result<Self> {
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .mode(0o600)
            .open(path)?;
        let metadata = file.metadata()?;
        if !metadata.file_type().is_file()
            || metadata.mode() & 0o077 != 0
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.len() > MAX_METRICS_FILE_BYTES
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "optimization metrics path is not a bounded owner-only regular file",
            ));
        }
        Ok(Self {
            events: Vec::new(),
            sink: Some(MetricsSink {
                file,
                bytes_written: metadata.len(),
            }),
        })
    }

    pub fn record(&mut self, event: OptimizationEvent) {
        if let Some(sink) = self.sink.as_mut() {
            let encoded = serde_json::to_vec(&event).ok().map(|mut value| {
                value.push(b'\n');
                value
            });
            let can_write = encoded.as_ref().is_some_and(|value| {
                sink.bytes_written
                    .checked_add(value.len() as u64)
                    .is_some_and(|total| total <= MAX_METRICS_FILE_BYTES)
            });
            let write_result = encoded.filter(|_| can_write).is_some_and(|value| {
                sink.file
                    .write_all(&value)
                    .and_then(|()| sink.file.flush())
                    .is_ok()
                    && {
                        sink.bytes_written += value.len() as u64;
                        true
                    }
            });
            if !write_result {
                self.sink = None;
            }
        }
        self.events.push(event);
    }

    pub fn events(&self) -> &[OptimizationEvent] {
        &self.events
    }

    pub fn summary(&self) -> OptimizationSummary {
        OptimizationSummary::from_events(&self.events)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OptimizationSummary {
    pub schema_version: u8,
    pub tool_calls: u64,
    pub v1_calls: u64,
    pub v2_calls: u64,
    pub successful_calls: u64,
    pub model_visible_images: u64,
    pub ax_bytes: u64,
    pub image_bytes: u64,
    pub bridge_bytes: u64,
    pub action_latency_p50_ms: u32,
    pub action_latency_p95_ms: u32,
    pub settle_latency_p95_ms: u32,
    pub stale_target_rate: f64,
    pub coordinate_fallback_rate: f64,
    pub call_success_rate: f64,
    pub manual_recovery_rate: f64,
}

impl OptimizationSummary {
    pub fn from_events(events: &[OptimizationEvent]) -> Self {
        let mut action_latency: Vec<_> =
            events.iter().map(|event| event.action_latency_ms).collect();
        let mut settle_latency: Vec<_> = events
            .iter()
            .filter_map(|event| event.settle_status.map(|_| event.settle_latency_ms))
            .collect();
        action_latency.sort_unstable();
        settle_latency.sort_unstable();
        let tool_calls = events.len() as u64;
        let successful_calls = events
            .iter()
            .filter(|event| matches!(event.outcome, MetricOutcome::Success))
            .count() as u64;
        Self {
            schema_version: OPTIMIZATION_METRIC_SCHEMA_VERSION,
            tool_calls,
            v1_calls: events
                .iter()
                .filter(|event| matches!(event.path, ExecutionPath::V1))
                .count() as u64,
            v2_calls: events
                .iter()
                .filter(|event| matches!(event.path, ExecutionPath::V2))
                .count() as u64,
            successful_calls,
            model_visible_images: count(events, |event| event.model_visible_image),
            ax_bytes: events.iter().map(|event| u64::from(event.ax_bytes)).sum(),
            image_bytes: events
                .iter()
                .map(|event| u64::from(event.image_bytes))
                .sum(),
            bridge_bytes: events
                .iter()
                .map(|event| u64::from(event.bridge_bytes))
                .sum(),
            action_latency_p50_ms: percentile(&action_latency, 50),
            action_latency_p95_ms: percentile(&action_latency, 95),
            settle_latency_p95_ms: percentile(&settle_latency, 95),
            stale_target_rate: rate(count(events, |event| event.stale_target), tool_calls),
            coordinate_fallback_rate: rate(
                count(events, |event| event.coordinate_fallback),
                tool_calls,
            ),
            call_success_rate: rate(successful_calls, tool_calls),
            manual_recovery_rate: rate(count(events, |event| event.manual_recovery), tool_calls),
        }
    }
}

fn metric_action_v1(action: &Action) -> MetricAction {
    match action {
        Action::Screenshot | Action::ScreenshotApplication { .. } => MetricAction::Observe,
        Action::ReadClipboard => MetricAction::ReadClipboard,
        _ => MetricAction::Coordinate,
    }
}

fn metric_action_v2(action: &ActionV2) -> MetricAction {
    match action {
        ActionV2::Observe { .. } => MetricAction::Observe,
        ActionV2::Coordinate { .. } => MetricAction::Coordinate,
        ActionV2::Press { .. } => MetricAction::Press,
        ActionV2::SetValue { .. } => MetricAction::SetValue,
        ActionV2::SelectText { .. } => MetricAction::SelectText,
        ActionV2::ScrollElement { .. } => MetricAction::ScrollElement,
        ActionV2::SecondaryAction { .. } => MetricAction::SecondaryAction,
        ActionV2::ReadClipboard => MetricAction::ReadClipboard,
    }
}

fn metric_error(error: &TransportError) -> MetricErrorCode {
    match error {
        TransportError::CapabilityUnavailable => MetricErrorCode::CapabilityUnavailable,
        TransportError::InvalidContext => MetricErrorCode::InvalidRequest,
        TransportError::LeaseExpired => MetricErrorCode::LeaseExpired,
        TransportError::OperationTimedOut => MetricErrorCode::OperationTimeout,
        TransportError::ResponseBinding => MetricErrorCode::ResponseBinding,
        TransportError::DeviceRejected(message)
            if message.starts_with("stale_element_target:")
                || message.starts_with("stale_state:")
                || message.starts_with("fresh_observation_required:") =>
        {
            MetricErrorCode::StaleTarget
        }
        TransportError::DeviceRejected(_) => MetricErrorCode::DeviceRejected,
        _ => MetricErrorCode::Transport,
    }
}

fn duration_ms(duration: Duration) -> u32 {
    duration.as_millis().min(u128::from(u32::MAX)) as u32
}

fn bounded_u16(value: usize) -> u16 {
    value.min(usize::from(u16::MAX)) as u16
}

fn bounded_u32(value: usize) -> u32 {
    value.min(u32::MAX as usize) as u32
}

fn count(events: &[OptimizationEvent], predicate: impl Fn(&OptimizationEvent) -> bool) -> u64 {
    events.iter().filter(|event| predicate(event)).count() as u64
}

fn rate(numerator: u64, denominator: u64) -> f64 {
    if denominator == 0 {
        0.0
    } else {
        numerator as f64 / denominator as f64
    }
}

fn percentile(sorted: &[u32], percentile: usize) -> u32 {
    if sorted.is_empty() {
        return 0;
    }
    let index = ((sorted.len() - 1) * percentile).div_ceil(100);
    sorted[index]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use tempfile::tempdir;

    #[test]
    fn summary_is_zero_content_and_computes_release_metrics() {
        let events = vec![
            OptimizationEvent {
                schema_version: 1,
                path: ExecutionPath::V1,
                action: MetricAction::Coordinate,
                observation_mode: Some(ObservationMode::Screenshot),
                outcome: MetricOutcome::Success,
                error_code: None,
                node_count: 0,
                removed_count: 0,
                ax_bytes: 0,
                image_bytes: 1_000,
                bridge_bytes: 1_000,
                action_latency_ms: 100,
                settle_latency_ms: 0,
                settle_status: None,
                model_visible_image: true,
                coordinate_fallback: false,
                stale_target: false,
                retry_count: 0,
                manual_recovery: false,
            },
            OptimizationEvent {
                schema_version: 1,
                path: ExecutionPath::V2,
                action: MetricAction::Press,
                observation_mode: Some(ObservationMode::AxDiff),
                outcome: MetricOutcome::Success,
                error_code: None,
                node_count: 3,
                removed_count: 1,
                ax_bytes: 120,
                image_bytes: 0,
                bridge_bytes: 120,
                action_latency_ms: 40,
                settle_latency_ms: 20,
                settle_status: Some(SettleStatus::Settled),
                model_visible_image: false,
                coordinate_fallback: false,
                stale_target: false,
                retry_count: 0,
                manual_recovery: false,
            },
        ];
        let summary = OptimizationSummary::from_events(&events);
        assert_eq!(summary.tool_calls, 2);
        assert_eq!(summary.model_visible_images, 1);
        assert_eq!(summary.ax_bytes, 120);
        assert_eq!(summary.image_bytes, 1_000);
        assert_eq!(summary.call_success_rate, 1.0);

        let serialized = serde_json::to_value(&events).expect("serialize metrics");
        let keys = object_keys(&serialized);
        for forbidden in [
            "title",
            "url",
            "coordinates",
            "input",
            "clipboard",
            "state_id",
        ] {
            assert!(!keys.contains(forbidden));
        }
    }

    #[test]
    fn jsonl_sink_is_owner_only_and_rejects_symlinks() {
        let directory = tempdir().expect("temp directory");
        let path = directory.path().join("metrics.jsonl");
        let mut metrics = OptimizationMetrics::with_jsonl_sink(&path).expect("metrics sink");
        metrics.record(OptimizationEvent {
            schema_version: 1,
            path: ExecutionPath::V2,
            action: MetricAction::Observe,
            observation_mode: Some(ObservationMode::Auto),
            outcome: MetricOutcome::Success,
            error_code: None,
            node_count: 1,
            removed_count: 0,
            ax_bytes: 20,
            image_bytes: 0,
            bridge_bytes: 20,
            action_latency_ms: 10,
            settle_latency_ms: 0,
            settle_status: Some(SettleStatus::NotRequested),
            model_visible_image: false,
            coordinate_fallback: false,
            stale_target: false,
            retry_count: 0,
            manual_recovery: false,
        });
        let metadata = std::fs::metadata(&path).expect("metrics metadata");
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        let line = std::fs::read_to_string(&path).expect("metrics JSONL");
        assert_eq!(line.lines().count(), 1);
        assert!(line.ends_with('\n'));
        let _: OptimizationEvent = serde_json::from_str(line.trim_end()).expect("event JSON");

        let target = directory.path().join("target");
        std::fs::write(&target, b"").expect("target");
        let link = directory.path().join("link");
        symlink(&target, &link).expect("symlink");
        assert!(OptimizationMetrics::with_jsonl_sink(&link).is_err());
    }

    #[test]
    fn every_v2_coordinate_action_counts_as_a_fallback() {
        let event = OptimizationEvent::success_v2(
            &ActionV2::Coordinate {
                action: Action::Key {
                    key: "RETURN".to_owned(),
                },
            },
            &ObservationPolicy::default(),
            &DeviceResultV2 {
                message: "done".to_owned(),
                state_generation: 1,
                screenshot_generation: 0,
                state_id: uuid::Uuid::new_v4(),
                application_digest: "a".repeat(64),
                window_id: 1,
                display_fingerprint: "display".to_owned(),
                base_state_id: None,
                observation: None,
                settle: crate::protocol_v2::SettleResult {
                    status: SettleStatus::NotRequested,
                    elapsed_ms: 0,
                },
                screenshot: None,
            },
            Duration::from_millis(1),
        );
        assert!(event.coordinate_fallback);
        assert!(!event.model_visible_image);
    }

    fn object_keys(value: &serde_json::Value) -> std::collections::BTreeSet<&str> {
        let mut keys = std::collections::BTreeSet::new();
        collect_keys(value, &mut keys);
        keys
    }

    fn collect_keys<'a>(
        value: &'a serde_json::Value,
        keys: &mut std::collections::BTreeSet<&'a str>,
    ) {
        match value {
            serde_json::Value::Object(object) => {
                for (key, value) in object {
                    keys.insert(key);
                    collect_keys(value, keys);
                }
            }
            serde_json::Value::Array(values) => {
                for value in values {
                    collect_keys(value, keys);
                }
            }
            _ => {}
        }
    }
}
