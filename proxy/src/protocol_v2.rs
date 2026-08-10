use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use uuid::Uuid;

use crate::protocol::{Action, Platform};

pub const PROTOCOL_VERSION_V2: u8 = 2;
pub const CAPABILITY_OBSERVATION_MODE_V2: &str = "observation_mode_v2";
pub const CAPABILITY_AX_STATE_V2: &str = "ax_state_v2";
pub const CAPABILITY_ADAPTIVE_SETTLE_V2: &str = "adaptive_settle_v2";

pub const MAX_AX_NODES: u16 = 800;
pub const MAX_AX_DEPTH: u8 = 20;
pub const MAX_AX_TEXT_PER_NODE: u16 = 160;
pub const MAX_AX_TOTAL_TEXT_BYTES: u32 = 16 * 1024;
pub const MAX_AX_VISIBLE_ROWS_PER_CONTAINER: u8 = 20;
pub const MAX_SETTLE_TIMEOUT_MS: u32 = 5_000;
pub const DEFAULT_AX_NODES: u16 = 600;
pub const DEFAULT_AX_TOTAL_TEXT_BYTES: u32 = 12 * 1024;
pub const DEFAULT_AX_VISIBLE_ROWS_PER_CONTAINER: u8 = 12;
pub const MAX_RESPONSE_MESSAGE_CHARACTERS: usize = 4_096;
pub const MAX_AX_ROLE_CHARACTERS: usize = 80;
pub const MAX_AX_ACTIONS_PER_NODE: usize = 16;
pub const MAX_AX_ACTION_CHARACTERS: usize = 128;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ActionRequestV2 {
    pub version: u8,
    pub request_id: Uuid,
    pub context: RequestContextV2,
    pub lease_until: DateTime<Utc>,
    pub observation: ObservationPolicy,
    pub action: ActionV2,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RequestContextV2 {
    pub user_id: Uuid,
    pub device_id: Uuid,
    pub tool_session_id: Uuid,
    pub device_session_id: Uuid,
    pub node_id: Uuid,
    pub platform: Platform,
    pub generation: u64,
    pub monotonic_sequence: u64,
    pub current_state_generation: u64,
    pub current_screenshot_generation: u64,
    pub base_state_id: Option<Uuid>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ObservationMode {
    None,
    AxDiff,
    AxFull,
    Screenshot,
    Both,
    Auto,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SettleMode {
    None,
    Auto,
    Fixed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ObservationPolicy {
    pub mode: ObservationMode,
    pub max_nodes: u16,
    pub max_depth: u8,
    pub max_text_per_node: u16,
    pub max_total_text_bytes: u32,
    pub max_visible_rows_per_container: u8,
    pub settle: SettleMode,
    pub settle_timeout_ms: u32,
    pub image_profile: ImageProfile,
    pub region: Option<[u16; 4]>,
}

impl ObservationPolicy {
    pub fn validate(&self) -> bool {
        self.max_nodes > 0
            && self.max_nodes <= MAX_AX_NODES
            && self.max_depth > 0
            && self.max_depth <= MAX_AX_DEPTH
            && self.max_text_per_node > 0
            && self.max_text_per_node <= MAX_AX_TEXT_PER_NODE
            && self.max_total_text_bytes > 0
            && self.max_total_text_bytes <= MAX_AX_TOTAL_TEXT_BYTES
            && self.max_visible_rows_per_container > 0
            && self.max_visible_rows_per_container <= MAX_AX_VISIBLE_ROWS_PER_CONTAINER
            && self.settle_timeout_ms <= MAX_SETTLE_TIMEOUT_MS
            && match self.settle {
                SettleMode::None => self.settle_timeout_ms == 0,
                SettleMode::Auto | SettleMode::Fixed => self.settle_timeout_ms > 0,
            }
            && self
                .region
                .map(|value| value[2] > 0 && value[3] > 0)
                .unwrap_or(true)
            && (matches!(self.image_profile, ImageProfile::Region) == self.region.is_some())
    }
}

impl Default for ObservationPolicy {
    fn default() -> Self {
        Self {
            mode: ObservationMode::Auto,
            max_nodes: DEFAULT_AX_NODES,
            max_depth: MAX_AX_DEPTH,
            max_text_per_node: MAX_AX_TEXT_PER_NODE,
            max_total_text_bytes: DEFAULT_AX_TOTAL_TEXT_BYTES,
            max_visible_rows_per_container: DEFAULT_AX_VISIBLE_ROWS_PER_CONTAINER,
            settle: SettleMode::Auto,
            settle_timeout_ms: MAX_SETTLE_TIMEOUT_MS,
            image_profile: ImageProfile::Compact,
            region: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ImageProfile {
    None,
    Compact,
    Standard,
    Region,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum ActionV2 {
    Observe {
        application: Option<String>,
    },
    Coordinate {
        action: Action,
    },
    Press {
        target: ElementTarget,
    },
    SetValue {
        target: ElementTarget,
        value: String,
    },
    SelectText {
        target: ElementTarget,
        text: String,
        prefix: Option<String>,
        suffix: Option<String>,
        selection_type: SelectionType,
    },
    ScrollElement {
        target: ElementTarget,
        direction: ScrollDirection,
        pages: u8,
    },
    SecondaryAction {
        target: ElementTarget,
        action_name: String,
    },
    ReadClipboard,
}

impl ActionV2 {
    pub fn validate_parameters(&self) -> bool {
        match self {
            Self::Observe { application } => application
                .as_ref()
                .map(|value| valid_bounded_text(value, 255))
                .unwrap_or(true),
            Self::Coordinate { action } => {
                is_coordinate_action(action) && action.validate_parameters()
            }
            Self::Press { target } => target.validate(),
            Self::SetValue { target, value } => target.validate() && value.chars().count() <= 4_096,
            Self::SelectText {
                target,
                text,
                prefix,
                suffix,
                ..
            } => {
                target.validate()
                    && valid_bounded_text(text, 4_096)
                    && prefix
                        .as_ref()
                        .map(|value| value.chars().count() <= 256)
                        .unwrap_or(true)
                    && suffix
                        .as_ref()
                        .map(|value| value.chars().count() <= 256)
                        .unwrap_or(true)
            }
            Self::ScrollElement { target, pages, .. } => {
                target.validate() && (1..=10).contains(pages)
            }
            Self::SecondaryAction {
                target,
                action_name,
            } => target.validate() && valid_bounded_text(action_name, 128),
            Self::ReadClipboard => true,
        }
    }
}

fn is_coordinate_action(action: &Action) -> bool {
    !matches!(
        action,
        Action::Screenshot
            | Action::ScreenshotApplication { .. }
            | Action::ReadClipboard
            | Action::Zoom { .. }
    )
}

fn valid_bounded_text(value: &str, maximum_characters: usize) -> bool {
    !value.is_empty()
        && value.chars().count() <= maximum_characters
        && value.trim() == value
        && !value.chars().any(char::is_control)
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ElementTarget {
    pub state_id: Uuid,
    pub state_generation: u64,
    pub application_digest: String,
    pub window_id: u32,
    pub display_fingerprint: String,
    pub element_index: u32,
}

impl ElementTarget {
    pub fn validate(&self) -> bool {
        self.state_generation > 0
            && self.application_digest.len() == 64
            && self
                .application_digest
                .bytes()
                .all(|value| value.is_ascii_hexdigit())
            && valid_bounded_text(&self.display_fingerprint, 256)
            && self.element_index < u32::MAX
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SelectionType {
    Text,
    CursorBefore,
    CursorAfter,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScrollDirection {
    Up,
    Down,
    Left,
    Right,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ActionResponseV2 {
    pub request_id: Uuid,
    pub monotonic_sequence: u64,
    pub state_generation: u64,
    pub screenshot_generation: u64,
    pub state_id: Option<Uuid>,
    pub application_digest: Option<String>,
    pub window_id: Option<u32>,
    pub display_fingerprint: Option<String>,
    pub base_state_id: Option<Uuid>,
    pub status: ResponseStatusV2,
    pub message: String,
    pub observation: Option<AccessibilityObservation>,
    pub settle: SettleResult,
    pub image: Option<ImagePayloadV2>,
}

impl ActionResponseV2 {
    pub fn discard_unsafe_ax_actions(&mut self) {
        let Some(observation) = &mut self.observation else {
            return;
        };
        for node in &mut observation.nodes {
            node.actions.retain(|action| {
                !action.is_empty()
                    && action.chars().count() <= MAX_AX_ACTION_CHARACTERS
                    && !action.chars().any(char::is_control)
            });
        }
    }

    pub fn validate_payload(&self, policy: &ObservationPolicy) -> bool {
        self.validate_payload_reason(policy).is_ok()
    }

    pub fn validate_payload_reason(&self, policy: &ObservationPolicy) -> Result<(), &'static str> {
        if self.message.is_empty() {
            return Err("response_message_empty");
        }
        if self.message.chars().count() > MAX_RESPONSE_MESSAGE_CHARACTERS {
            return Err("response_message_length");
        }
        if self.settle.elapsed_ms > MAX_SETTLE_TIMEOUT_MS {
            return Err("settle_elapsed");
        }
        if let Some(observation) = &self.observation {
            observation.validate_reason(policy)?;
        }
        if let Some(image) = &self.image {
            image.validate_reason(policy)?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResponseStatusV2 {
    Success,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AccessibilityObservation {
    pub kind: AccessibilityObservationKind,
    pub reset: bool,
    pub truncated: bool,
    pub nodes: Vec<AccessibilityNode>,
    pub removed: Vec<u32>,
}

impl AccessibilityObservation {
    fn validate_reason(&self, policy: &ObservationPolicy) -> Result<(), &'static str> {
        if self.nodes.len() > usize::from(policy.max_nodes) {
            return Err("ax_node_count");
        }
        if self.removed.len() > usize::from(policy.max_nodes) {
            return Err("ax_removed_count");
        }
        if matches!(self.kind, AccessibilityObservationKind::Full) && !self.removed.is_empty() {
            return Err("ax_full_has_removed");
        }

        let mut indexes = BTreeSet::new();
        let mut removed = BTreeSet::new();
        let mut text_bytes = 0_usize;
        for node in &self.nodes {
            if node.index >= u32::from(policy.max_nodes) {
                return Err("ax_node_index");
            }
            if !indexes.insert(node.index) {
                return Err("ax_duplicate_index");
            }
            if node.depth > policy.max_depth {
                return Err("ax_node_depth");
            }
            if node
                .parent_index
                .is_some_and(|index| index >= u32::from(policy.max_nodes))
            {
                return Err("ax_parent_index");
            }
            if node.role.is_empty() {
                return Err("ax_role_empty");
            }
            if node.role.chars().count() > MAX_AX_ROLE_CHARACTERS {
                return Err("ax_role_length");
            }
            if node.actions.len() > MAX_AX_ACTIONS_PER_NODE {
                return Err("ax_action_count");
            }
            if node.actions.iter().any(|action| action.is_empty()) {
                return Err("ax_action_empty");
            }
            if node
                .actions
                .iter()
                .any(|action| action.chars().count() > MAX_AX_ACTION_CHARACTERS)
            {
                return Err("ax_action_length");
            }
            if node
                .actions
                .iter()
                .any(|action| action.chars().any(char::is_control))
            {
                return Err("ax_action_control_character");
            }
            if node.frame.is_some_and(|frame| frame[2] < 0 || frame[3] < 0) {
                return Err("ax_frame");
            }
            text_bytes = match text_bytes.checked_add(node.role.len()) {
                Some(total) => total,
                None => return Err("ax_total_text_overflow"),
            };
            for value in [
                node.title.as_deref(),
                node.label.as_deref(),
                node.value.as_deref(),
                node.placeholder.as_deref(),
                node.url.as_deref(),
            ]
            .into_iter()
            .flatten()
            {
                if value.chars().count() > usize::from(policy.max_text_per_node) {
                    return Err("ax_node_text_length");
                }
                text_bytes = match text_bytes.checked_add(value.len()) {
                    Some(total) => total,
                    None => return Err("ax_total_text_overflow"),
                };
            }
            for action in &node.actions {
                text_bytes = match text_bytes.checked_add(action.len()) {
                    Some(total) => total,
                    None => return Err("ax_total_text_overflow"),
                };
            }
        }
        if text_bytes > policy.max_total_text_bytes as usize {
            return Err("ax_total_text_bytes");
        }
        for index in &self.removed {
            if *index >= u32::from(policy.max_nodes) {
                return Err("ax_removed_index");
            }
            if indexes.contains(index) {
                return Err("ax_removed_present");
            }
            if !removed.insert(*index) {
                return Err("ax_duplicate_removed");
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AccessibilityObservationKind {
    Full,
    Diff,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AccessibilityNode {
    pub index: u32,
    pub parent_index: Option<u32>,
    pub depth: u8,
    pub role: String,
    pub title: Option<String>,
    pub label: Option<String>,
    pub value: Option<String>,
    pub placeholder: Option<String>,
    pub url: Option<String>,
    pub frame: Option<[i32; 4]>,
    pub settable: bool,
    pub actions: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SettleStatus {
    Settled,
    Timeout,
    NotRequested,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SettleResult {
    pub status: SettleStatus,
    pub elapsed_ms: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ImagePayloadV2 {
    pub base64_data: String,
    pub mime_type: String,
    pub pixel_width: u16,
    pub pixel_height: u16,
    pub profile: ImageProfile,
}

impl ImagePayloadV2 {
    fn validate_reason(&self, policy: &ObservationPolicy) -> Result<(), &'static str> {
        let expected_profile = match policy.image_profile {
            ImageProfile::None => ImageProfile::Compact,
            profile => profile,
        };
        if self.profile != expected_profile {
            return Err("image_profile");
        }
        if matches!(self.profile, ImageProfile::None) {
            return Err("image_profile_none");
        }
        if self.pixel_width == 0 || self.pixel_height == 0 {
            return Err("image_empty_dimensions");
        }
        if self.pixel_width > 4_096 || self.pixel_height > 4_096 {
            return Err("image_dimensions");
        }
        if u32::from(self.pixel_width) * u32::from(self.pixel_height) > 4_000_000 {
            return Err("image_pixel_count");
        }
        if !matches!(self.mime_type.as_str(), "image/png" | "image/jpeg") {
            return Err("image_mime_type");
        }
        if self.base64_data.is_empty() {
            return Err("image_data_empty");
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn swift_v2_vector_decodes_strictly() {
        let raw = include_str!("../../protocol/test-vectors/action-request-v2-valid.json");
        let request: ActionRequestV2 = serde_json::from_str(raw).expect("valid v2 fixture");
        assert_eq!(request.version, PROTOCOL_VERSION_V2);
        assert_eq!(request.context.monotonic_sequence, 8);
        assert!(request.observation.validate());
        assert!(request.action.validate_parameters());
    }

    #[test]
    fn swift_v2_response_vector_decodes_and_stays_bounded() {
        let raw = include_str!("../../protocol/test-vectors/action-response-v2-valid.json");
        let response: ActionResponseV2 =
            serde_json::from_str(raw).expect("valid v2 response fixture");
        assert_eq!(response.monotonic_sequence, 8);
        assert!(response.validate_payload(&ObservationPolicy::default()));
    }

    #[test]
    fn default_policy_stays_within_compiled_bounds() {
        assert!(ObservationPolicy::default().validate());
    }

    #[test]
    fn policy_rejects_oversized_ax_and_settle_budgets() {
        let oversized_nodes = ObservationPolicy {
            max_nodes: MAX_AX_NODES + 1,
            ..ObservationPolicy::default()
        };
        assert!(!oversized_nodes.validate());

        let oversized_settle = ObservationPolicy {
            settle_timeout_ms: MAX_SETTLE_TIMEOUT_MS + 1,
            ..ObservationPolicy::default()
        };
        assert!(!oversized_settle.validate());
    }

    #[test]
    fn region_profile_requires_a_nonempty_region() {
        let missing = ObservationPolicy {
            image_profile: ImageProfile::Region,
            ..ObservationPolicy::default()
        };
        assert!(!missing.validate());

        let present = ObservationPolicy {
            image_profile: ImageProfile::Region,
            region: Some([1, 2, 3, 4]),
            ..ObservationPolicy::default()
        };
        assert!(present.validate());
    }

    #[test]
    fn set_value_accepts_an_empty_string_for_clearing_editable_controls() {
        let action = ActionV2::SetValue {
            target: ElementTarget {
                state_id: Uuid::new_v4(),
                state_generation: 1,
                application_digest: "a".repeat(64),
                window_id: 1,
                display_fingerprint: "display".to_owned(),
                element_index: 0,
            },
            value: String::new(),
        };
        assert!(action.validate_parameters());
    }

    #[test]
    fn response_payload_rejects_oversized_or_ambiguous_ax_state() {
        let policy = ObservationPolicy {
            max_nodes: 2,
            max_text_per_node: 4,
            max_total_text_bytes: 16,
            ..ObservationPolicy::default()
        };
        let response = ActionResponseV2 {
            request_id: Uuid::new_v4(),
            monotonic_sequence: 1,
            state_generation: 1,
            screenshot_generation: 0,
            state_id: Some(Uuid::new_v4()),
            application_digest: Some("a".repeat(64)),
            window_id: Some(1),
            display_fingerprint: Some("display".to_owned()),
            base_state_id: None,
            status: ResponseStatusV2::Success,
            message: "ok".to_owned(),
            observation: Some(AccessibilityObservation {
                kind: AccessibilityObservationKind::Diff,
                reset: false,
                truncated: false,
                nodes: vec![AccessibilityNode {
                    index: 0,
                    parent_index: None,
                    depth: 0,
                    role: "AXButton".to_owned(),
                    title: None,
                    label: None,
                    value: None,
                    placeholder: None,
                    url: None,
                    frame: Some([0, 0, 10, 10]),
                    settable: false,
                    actions: vec![],
                }],
                removed: vec![0],
            }),
            settle: SettleResult {
                status: SettleStatus::Settled,
                elapsed_ms: 10,
            },
            image: None,
        };
        assert!(!response.validate_payload(&policy));
        assert_eq!(
            response.validate_payload_reason(&policy),
            Err("ax_removed_present")
        );
    }

    #[test]
    fn discards_protocol_unsafe_ax_actions_without_dropping_the_node() {
        let raw = include_str!("../../protocol/test-vectors/action-response-v2-valid.json");
        let mut response: ActionResponseV2 =
            serde_json::from_str(raw).expect("valid v2 response fixture");
        let node = &mut response.observation.as_mut().expect("observation").nodes[0];
        node.actions = vec![
            "AXPress".to_owned(),
            "AXCustom\nAction".to_owned(),
            "".to_owned(),
            "A".repeat(MAX_AX_ACTION_CHARACTERS + 1),
        ];

        assert_eq!(
            response.validate_payload_reason(&ObservationPolicy::default()),
            Err("ax_action_empty")
        );
        response.discard_unsafe_ax_actions();
        assert!(response.validate_payload(&ObservationPolicy::default()));
        assert_eq!(
            response.observation.expect("observation").nodes[0].actions,
            vec!["AXPress"]
        );
    }
}
