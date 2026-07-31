use std::{io::Cursor, sync::Arc};

use base64::{engine::general_purpose::STANDARD, Engine};
use image::{ImageFormat, ImageReader, Limits};
use rmcp::{
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{CallToolResult, ContentBlock, ServerCapabilities, ServerInfo},
    schemars, tool, tool_handler, tool_router, ServerHandler,
};
use serde::Deserialize;
use tokio::sync::Mutex;

use crate::{
    protocol::{Action, Point, Region},
    transport::{DeviceResult, DeviceTransport},
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
    tool_router: ToolRouter<Self>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PointParameters {
    pub coordinate: Point,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TypeParameters {
    pub text: String,
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

impl DeviceMcp {
    pub fn new(transport: Arc<dyn DeviceTransport>) -> Self {
        Self {
            transport,
            operation_guard: Arc::new(Mutex::new(())),
            tool_router: Self::tool_router(),
        }
    }

    async fn dispatch(&self, action: Action) -> Result<CallToolResult, String> {
        if !action.validate_parameters() {
            return Err("action parameters are outside the supported bounds".to_owned());
        }
        let _operation = self.operation_guard.lock().await;
        let result = self
            .transport
            .execute(action)
            .await
            .map_err(|error| error.to_string())?;
        if result.screenshot.is_none() {
            return device_result(result);
        }
        tokio::task::spawn_blocking(move || device_result(result))
            .await
            .map_err(|error| format!("device image validation task failed: {error}"))?
    }
}

fn device_result(result: DeviceResult) -> Result<CallToolResult, String> {
    let mut content = vec![ContentBlock::text(result.message)];
    if let Some(image) = result.screenshot {
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
        content.push(ContentBlock::image(image.base64_data, image.mime_type));
    }
    Ok(CallToolResult::success(content))
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
    #[tool(description = "Capture the currently approved macOS applications")]
    async fn screenshot(&self) -> Result<CallToolResult, String> {
        self.dispatch(Action::Screenshot).await
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

#[tool_handler(router = self.tool_router)]
impl ServerHandler for DeviceMcp {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build()).with_instructions(
            "Controls only the macOS applications approved for the current agent-remote device session.",
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
                "double_click",
                "hold_key",
                "key",
                "left_click",
                "left_click_drag",
                "left_mouse_down",
                "left_mouse_up",
                "middle_click",
                "mouse_move",
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
