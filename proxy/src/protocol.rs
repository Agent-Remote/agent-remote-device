use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const PROTOCOL_VERSION: u8 = 1;
pub const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_ACTIVE_DEVICE_SESSION_GENERATION: u64 = i64::MAX as u64 - 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ActionRequest {
    pub version: u8,
    pub request_id: Uuid,
    pub context: RequestContext,
    pub lease_until: DateTime<Utc>,
    pub action: Action,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RequestContext {
    pub user_id: Uuid,
    pub device_id: Uuid,
    pub tool_session_id: Uuid,
    pub device_session_id: Uuid,
    pub node_id: Uuid,
    pub platform: Platform,
    pub generation: u64,
    pub monotonic_sequence: u64,
    pub current_screenshot_generation: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Platform {
    Macos,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Action {
    Screenshot,
    ScreenshotApplication {
        application: String,
    },
    ReadClipboard,
    LeftClick {
        coordinate: Point,
    },
    Type {
        text: String,
    },
    Key {
        key: String,
    },
    MouseMove {
        coordinate: Point,
    },
    Scroll {
        delta_x: i32,
        delta_y: i32,
        coordinate: Option<Point>,
    },
    LeftClickDrag {
        start: Point,
        end: Point,
        duration_ms: Option<u32>,
    },
    RightClick {
        coordinate: Point,
    },
    MiddleClick {
        coordinate: Point,
    },
    DoubleClick {
        coordinate: Point,
    },
    TripleClick {
        coordinate: Point,
    },
    LeftMouseDown,
    LeftMouseUp,
    HoldKey {
        key: String,
        duration_ms: u32,
    },
    Wait {
        duration_ms: u32,
    },
    Zoom {
        region: Region,
    },
}

pub type Point = [u16; 2];
pub type Region = [u16; 4];

impl Action {
    pub fn validate_parameters(&self) -> bool {
        match self {
            Self::ScreenshotApplication { application } => {
                !application.is_empty()
                    && application.chars().count() <= 255
                    && application.trim() == application
                    && application.chars().all(|character| !character.is_control())
            }
            Self::Type { text } => !text.is_empty() && text.chars().count() <= 4096,
            Self::Key { key } | Self::HoldKey { key, .. } if !valid_key(key) => false,
            Self::Scroll {
                delta_x, delta_y, ..
            } => (-10_000..=10_000).contains(delta_x) && (-10_000..=10_000).contains(delta_y),
            Self::LeftClickDrag {
                duration_ms: Some(value),
                ..
            } => (100..=5_000).contains(value),
            Self::HoldKey { duration_ms, .. } => (50..=5_000).contains(duration_ms),
            Self::Wait { duration_ms } => (50..=10_000).contains(duration_ms),
            Self::Zoom { region } => region[2] != 0 && region[3] != 0,
            _ => true,
        }
    }
}

fn valid_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 64
        && key
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'+' | b' ' | b'-'))
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::*;

    #[test]
    fn cross_language_valid_vector_decodes() {
        let raw = include_str!("../../protocol/test-vectors/action-request-valid.json");
        let request: ActionRequest = serde_json::from_str(raw).expect("valid fixture");
        assert_eq!(request.version, PROTOCOL_VERSION);
        assert_eq!(request.context.monotonic_sequence, 7);
        assert_eq!(
            request.action,
            Action::LeftClick {
                coordinate: [320, 240]
            }
        );
    }

    #[test]
    fn unknown_top_level_field_is_rejected() {
        let raw = include_str!("../../protocol/test-vectors/action-request-unknown-field.json");
        assert!(serde_json::from_str::<ActionRequest>(raw).is_err());
    }

    proptest! {
        #[test]
        fn arbitrary_bounded_parser_input_never_breaks_round_trip(data in proptest::collection::vec(any::<u8>(), 0..8192)) {
            if let Ok(request) = serde_json::from_slice::<ActionRequest>(&data) {
                let encoded = serde_json::to_vec(&request).expect("validated request must encode");
                let decoded = serde_json::from_slice::<ActionRequest>(&encoded)
                    .expect("encoded request must decode");
                prop_assert_eq!(decoded, request);
            }
        }
    }
}
