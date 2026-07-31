import AppKit
import CoreGraphics
import CryptoKit
import DeviceProtocol
import DeviceSecurity
import Foundation
import ImageIO
import ScreenCaptureKit
import Security
import UniformTypeIdentifiers

public struct CaptureProfile: Equatable, Sendable {
    public let maximumWidth: Int
    public let maximumHeight: Int

    public init(maximumWidth: Int, maximumHeight: Int) {
        precondition(maximumWidth > 0 && maximumHeight > 0)
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
    }
}

public struct CapturedWindow: @unchecked Sendable {
    public let pngData: Data
    public let pixelWidth: UInt16
    public let pixelHeight: UInt16
    public let windowID: CGWindowID
    public let windowFrame: CGRect
    public let coordinateFrame: CGRect
    public let processID: pid_t
    public let application: ApplicationIdentity
    public let displayFingerprint: String

    public init(
        pngData: Data,
        pixelWidth: UInt16,
        pixelHeight: UInt16,
        windowID: CGWindowID,
        windowFrame: CGRect,
        coordinateFrame: CGRect,
        processID: pid_t,
        application: ApplicationIdentity,
        displayFingerprint: String
    ) {
        self.pngData = pngData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.windowID = windowID
        self.windowFrame = windowFrame
        self.coordinateFrame = coordinateFrame
        self.processID = processID
        self.application = application
        self.displayFingerprint = displayFingerprint
    }
}

public enum CaptureFailure: Error, Equatable {
    case screenRecordingPermissionMissing
    case approvedApplicationNotFrontmost
    case signingIdentifierMismatch
    case approvedWindowMissing
    case displayMissing
    case invalidCaptureSize
    case encodingFailed
    case cropOutOfBounds
}

public struct WindowCapture: Sendable {
    private let profile: CaptureProfile
    private let excludedBundleIdentifier: String

    public init(profile: CaptureProfile, excludedBundleIdentifier: String = "dev.agentremote.device") {
        self.profile = profile
        self.excludedBundleIdentifier = excludedBundleIdentifier
    }

    public func capture(application: ApplicationIdentity) async throws -> CapturedWindow {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureFailure.screenRecordingPermissionMissing
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier == application.bundleIdentifier,
              frontmost.bundleIdentifier != excludedBundleIdentifier
        else {
            throw CaptureFailure.approvedApplicationNotFrontmost
        }
        guard Self.signingIdentifier(for: frontmost) == application.signingIdentifier else {
            throw CaptureFailure.signingIdentifierMismatch
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == frontmost.processIdentifier
                && $0.isOnScreen
                && $0.frame.width > 1
                && $0.frame.height > 1
        }) else {
            throw CaptureFailure.approvedWindowMissing
        }
        guard let display = Self.selectedDisplay(
            for: window.frame,
            from: content.displays
        ) else {
            throw CaptureFailure.displayMissing
        }
        let size = Self.scaledSize(
            sourceWidth: window.frame.width,
            sourceHeight: window.frame.height,
            maximumWidth: profile.maximumWidth,
            maximumHeight: profile.maximumHeight
        )
        guard size.width > 0, size.height > 0,
              size.width <= Int(UInt16.max), size.height <= Int(UInt16.max)
        else {
            throw CaptureFailure.invalidCaptureSize
        }
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = true
        configuration.capturesAudio = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        guard let pngData = Self.pngData(image) else { throw CaptureFailure.encodingFailed }
        return CapturedWindow(
            pngData: pngData,
            pixelWidth: UInt16(size.width),
            pixelHeight: UInt16(size.height),
            windowID: window.windowID,
            windowFrame: window.frame,
            coordinateFrame: window.frame,
            processID: frontmost.processIdentifier,
            application: application,
            displayFingerprint: Self.displayFingerprint(content.displays, selected: display)
        )
    }

    public static func cropped(_ capture: CapturedWindow, to region: Region) throws -> CapturedWindow {
        let maximumX = UInt32(region.x) + UInt32(region.width)
        let maximumY = UInt32(region.y) + UInt32(region.height)
        guard region.width > 0, region.height > 0,
              maximumX <= UInt32(capture.pixelWidth),
              maximumY <= UInt32(capture.pixelHeight),
              let source = CGImageSourceCreateWithData(capture.pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let croppedImage = image.cropping(to: CGRect(
                  x: Int(region.x),
                  y: Int(region.y),
                  width: Int(region.width),
                  height: Int(region.height)
              )),
              let pngData = pngData(croppedImage)
        else {
            throw CaptureFailure.cropOutOfBounds
        }

        let xScale = capture.coordinateFrame.width / CGFloat(capture.pixelWidth)
        let yScale = capture.coordinateFrame.height / CGFloat(capture.pixelHeight)
        let coordinateFrame = CGRect(
            x: capture.coordinateFrame.minX + CGFloat(region.x) * xScale,
            y: capture.coordinateFrame.minY + CGFloat(region.y) * yScale,
            width: CGFloat(region.width) * xScale,
            height: CGFloat(region.height) * yScale
        )
        return CapturedWindow(
            pngData: pngData,
            pixelWidth: region.width,
            pixelHeight: region.height,
            windowID: capture.windowID,
            windowFrame: capture.windowFrame,
            coordinateFrame: coordinateFrame,
            processID: capture.processID,
            application: capture.application,
            displayFingerprint: capture.displayFingerprint
        )
    }

    public static func scaledSize(
        sourceWidth: CGFloat,
        sourceHeight: CGFloat,
        maximumWidth: Int,
        maximumHeight: Int
    ) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0, maximumWidth > 0, maximumHeight > 0 else {
            return (0, 0)
        }
        let scale = min(
            CGFloat(maximumWidth) / sourceWidth,
            CGFloat(maximumHeight) / sourceHeight,
            1
        )
        return (
            max(1, Int((sourceWidth * scale).rounded(.down))),
            max(1, Int((sourceHeight * scale).rounded(.down)))
        )
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func signingIdentifier(for application: NSRunningApplication) -> String? {
        guard let bundleURL = application.bundleURL else { return nil }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }
        let validationFlags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
        )
        guard SecStaticCodeCheckValidity(staticCode, validationFlags, nil) == errSecSuccess else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let values = information as? [String: Any]
        else {
            return nil
        }
        return values[kSecCodeInfoIdentifier as String] as? String
    }

    static func displayFingerprint(_ displays: [SCDisplay], selected: SCDisplay) -> String {
        let layout = displays
            .sorted { $0.displayID < $1.displayID }
            .map { "\($0.displayID):\($0.frame.origin.x):\($0.frame.origin.y):\($0.frame.width):\($0.frame.height)" }
            .joined(separator: "|")
        let value = "selected=\(selected.displayID)|\(layout)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func selectedDisplayID(
        for windowFrame: CGRect,
        from displays: [(displayID: CGDirectDisplayID, frame: CGRect)]
    ) -> CGDirectDisplayID? {
        displays.compactMap { display -> (displayID: CGDirectDisplayID, area: CGFloat)? in
            let intersection = display.frame.intersection(windowFrame)
            guard !intersection.isNull, !intersection.isInfinite,
                  intersection.width > 0, intersection.height > 0
            else {
                return nil
            }
            return (display.displayID, intersection.width * intersection.height)
        }.max { left, right in
            if left.area == right.area {
                return left.displayID > right.displayID
            }
            return left.area < right.area
        }?.displayID
    }

    static func selectedDisplay(for windowFrame: CGRect, from displays: [SCDisplay]) -> SCDisplay? {
        let selectedID = selectedDisplayID(
            for: windowFrame,
            from: displays.map { ($0.displayID, $0.frame) }
        )
        return displays.first { $0.displayID == selectedID }
    }
}
