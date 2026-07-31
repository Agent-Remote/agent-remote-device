use chrono::{DateTime, Utc};
use thiserror::Error;
use uuid::Uuid;

use crate::protocol::{Action, ActionRequest, Platform, PROTOCOL_VERSION};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ControlLevel {
    ViewOnly,
    ClickOnly,
    FullControl,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionBinding {
    pub user_id: Uuid,
    pub device_id: Uuid,
    pub tool_session_id: Uuid,
    pub device_session_id: Uuid,
    pub node_id: Uuid,
    pub platform: Platform,
    pub generation: u64,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ValidationError {
    #[error("unsupported protocol version")]
    Version,
    #[error("request binding does not match active session")]
    Binding,
    #[error("request sequence is not the exact next sequence")]
    Sequence,
    #[error("request screenshot generation is stale")]
    ScreenshotGeneration,
    #[error("request counter is exhausted")]
    CounterExhausted,
    #[error("device-session lease has expired")]
    LeaseExpired,
    #[error("action is not permitted by the approved control level")]
    ControlLevel,
    #[error("action parameter is outside protocol bounds")]
    Parameter,
}

#[derive(Debug)]
pub struct ActionValidator {
    binding: SessionBinding,
    next_sequence: u64,
    screenshot_generation: u64,
    control_level: ControlLevel,
}

impl ActionValidator {
    pub fn new(
        binding: SessionBinding,
        next_sequence: u64,
        screenshot_generation: u64,
        control_level: ControlLevel,
    ) -> Self {
        Self {
            binding,
            next_sequence,
            screenshot_generation,
            control_level,
        }
    }

    pub fn validate(
        &self,
        request: &ActionRequest,
        now: DateTime<Utc>,
    ) -> Result<(), ValidationError> {
        if request.version != PROTOCOL_VERSION {
            return Err(ValidationError::Version);
        }
        let context = &request.context;
        if context.user_id != self.binding.user_id
            || context.device_id != self.binding.device_id
            || context.tool_session_id != self.binding.tool_session_id
            || context.device_session_id != self.binding.device_session_id
            || context.node_id != self.binding.node_id
            || context.platform != self.binding.platform
            || context.generation != self.binding.generation
        {
            return Err(ValidationError::Binding);
        }
        if context.monotonic_sequence != self.next_sequence {
            return Err(ValidationError::Sequence);
        }
        if context.current_screenshot_generation != self.screenshot_generation {
            return Err(ValidationError::ScreenshotGeneration);
        }
        if self.next_sequence == u64::MAX || self.screenshot_generation == u64::MAX {
            return Err(ValidationError::CounterExhausted);
        }
        if request.lease_until <= now {
            return Err(ValidationError::LeaseExpired);
        }
        self.validate_action(&request.action)
    }

    pub fn accept(&mut self, request: &ActionRequest) -> Result<(), ValidationError> {
        let next_sequence = request
            .context
            .monotonic_sequence
            .checked_add(1)
            .ok_or(ValidationError::CounterExhausted)?;
        let screenshot_generation = self
            .screenshot_generation
            .checked_add(1)
            .ok_or(ValidationError::CounterExhausted)?;
        self.next_sequence = next_sequence;
        self.screenshot_generation = screenshot_generation;
        Ok(())
    }

    fn validate_action(&self, action: &Action) -> Result<(), ValidationError> {
        let required = match action {
            Action::Screenshot | Action::Zoom { .. } | Action::Wait { .. } => {
                ControlLevel::ViewOnly
            }
            Action::LeftClick { .. }
            | Action::MouseMove { .. }
            | Action::Scroll { .. }
            | Action::LeftClickDrag { .. }
            | Action::RightClick { .. }
            | Action::MiddleClick { .. }
            | Action::DoubleClick { .. }
            | Action::TripleClick { .. }
            | Action::LeftMouseDown
            | Action::LeftMouseUp => ControlLevel::ClickOnly,
            Action::Type { .. } | Action::Key { .. } | Action::HoldKey { .. } => {
                ControlLevel::FullControl
            }
        };
        if rank(self.control_level) < rank(required) {
            return Err(ValidationError::ControlLevel);
        }
        action
            .validate_parameters()
            .then_some(())
            .ok_or(ValidationError::Parameter)
    }
}

fn rank(level: ControlLevel) -> u8 {
    match level {
        ControlLevel::ViewOnly => 0,
        ControlLevel::ClickOnly => 1,
        ControlLevel::FullControl => 2,
    }
}

#[cfg(test)]
mod tests {
    use chrono::Duration;
    use proptest::prelude::*;

    use super::*;
    use crate::protocol::{ActionRequest, RequestContext};

    fn binding() -> SessionBinding {
        SessionBinding {
            user_id: Uuid::from_u128(1),
            device_id: Uuid::from_u128(2),
            tool_session_id: Uuid::from_u128(3),
            device_session_id: Uuid::from_u128(4),
            node_id: Uuid::from_u128(5),
            platform: Platform::Macos,
            generation: 2,
        }
    }

    fn request(action: Action) -> ActionRequest {
        let binding = binding();
        ActionRequest {
            version: 1,
            request_id: Uuid::from_u128(6),
            context: RequestContext {
                user_id: binding.user_id,
                device_id: binding.device_id,
                tool_session_id: binding.tool_session_id,
                device_session_id: binding.device_session_id,
                node_id: binding.node_id,
                platform: binding.platform,
                generation: binding.generation,
                monotonic_sequence: 9,
                current_screenshot_generation: 4,
            },
            lease_until: Utc::now() + Duration::minutes(1),
            action,
        }
    }

    #[test]
    fn rejects_typing_at_click_only_level() {
        let validator = ActionValidator::new(binding(), 9, 4, ControlLevel::ClickOnly);
        assert_eq!(
            validator.validate(
                &request(Action::Type {
                    text: "secret".into()
                }),
                Utc::now()
            ),
            Err(ValidationError::ControlLevel)
        );
    }

    #[test]
    fn rejects_cross_generation_and_replay() {
        let validator = ActionValidator::new(binding(), 10, 4, ControlLevel::FullControl);
        assert_eq!(
            validator.validate(&request(Action::Screenshot), Utc::now()),
            Err(ValidationError::Sequence)
        );
        let mut wrong = request(Action::Screenshot);
        wrong.context.monotonic_sequence = 10;
        wrong.context.generation = 1;
        assert_eq!(
            validator.validate(&wrong, Utc::now()),
            Err(ValidationError::Binding)
        );
    }

    #[test]
    fn rejects_exhausted_sequence_and_screenshot_counters() {
        let mut sequence_request = request(Action::Screenshot);
        sequence_request.context.monotonic_sequence = u64::MAX;
        let sequence_validator = ActionValidator::new(
            binding(),
            u64::MAX,
            sequence_request.context.current_screenshot_generation,
            ControlLevel::FullControl,
        );
        assert_eq!(
            sequence_validator.validate(&sequence_request, Utc::now()),
            Err(ValidationError::CounterExhausted)
        );

        let mut screenshot_request = request(Action::Screenshot);
        screenshot_request.context.current_screenshot_generation = u64::MAX;
        let screenshot_validator = ActionValidator::new(
            binding(),
            screenshot_request.context.monotonic_sequence,
            u64::MAX,
            ControlLevel::FullControl,
        );
        assert_eq!(
            screenshot_validator.validate(&screenshot_request, Utc::now()),
            Err(ValidationError::CounterExhausted)
        );
    }

    #[test]
    fn accepting_any_action_advances_both_counters() {
        let action = request(Action::LeftClick { coordinate: [1, 1] });
        let mut validator = ActionValidator::new(binding(), 9, 4, ControlLevel::FullControl);

        validator.accept(&action).expect("accept action");

        assert_eq!(validator.next_sequence, 10);
        assert_eq!(validator.screenshot_generation, 5);
    }

    proptest! {
        #[test]
        fn only_exact_sequence_is_accepted(sequence in any::<u64>().prop_filter("different", |value| *value != 9)) {
            let validator = ActionValidator::new(binding(), 9, 4, ControlLevel::FullControl);
            let mut candidate = request(Action::Screenshot);
            candidate.context.monotonic_sequence = sequence;
            prop_assert_eq!(validator.validate(&candidate, Utc::now()), Err(ValidationError::Sequence));
        }
    }
}
