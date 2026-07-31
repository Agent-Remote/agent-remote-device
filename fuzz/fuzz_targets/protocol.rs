#![no_main]

use agent_remote_device_proxy::protocol::{ActionRequest, MAX_FRAME_BYTES};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if data.len() > MAX_FRAME_BYTES {
        return;
    }
    if let Ok(request) = serde_json::from_slice::<ActionRequest>(data) {
        let encoded = serde_json::to_vec(&request).expect("validated request must encode");
        let decoded: ActionRequest =
            serde_json::from_slice(&encoded).expect("encoded request must decode");
        assert_eq!(decoded, request);
    }
});
