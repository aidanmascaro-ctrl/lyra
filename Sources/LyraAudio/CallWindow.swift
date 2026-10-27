import AppKit
import CoreGraphics
import ImageIO
import LyraCore
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// The meeting app's call window: finding it (`CallWindowRule`), taking one frame of it, and reading its text.
/// Frames live in memory; only `writeJPEG` (a slide, when Aidan switched slides on) ever saves one.
public enum CallWindow {
    private static let maximumPixelWidth = 2400
    private static let minimumLineLength = 3
    private static let jpegQuality = 0.9

    /// One frame of the call window of the app owning `pid`, or nil without Screen Recording permission, without a
    /// call window (a browser showing another tab), or on any failure.
    public static func frame(pid: pid_t, startTitle: String) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let app = CoreAudioMicUsage.owningApp(of: pid)
        let owner = app?.processIdentifier ?? pid
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        // The app's windows (Chrome's, for its audio helper), and any of the process's own.
        let windows = content.windows.filter { [owner, pid].contains($0.owningApplication?.processID) && $0.windowLayer == 0 }
        let infos = windows.map { WindowInfo(id: $0.windowID, title: $0.title ?? "", width: $0.frame.width, height: $0.frame.height) }
        guard let picked = CallWindowRule.pick(infos, appName: app?.localizedName ?? "", startTitle: startTitle),
              let window = windows.first(where: { $0.windowID == picked.id }) else { return nil }
        return await capture(window)
    }

    private static func capture(_ window: SCWindow) async -> CGImage? {
        let scale = min(2.0, Double(maximumPixelWidth) / max(window.frame.width, 1))
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// A smaller copy of the frame as RGBA pixels (top row first), `width` pixels across.
    public static func pixels(_ image: CGImage, width: Int) -> PixelFrame? {
        let w = min(width, image.width), h = max(1, image.height * w / max(image.width, 1))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? PixelFrame(width: w, height: h, rgba: bytes) : nil
    }

    /// Text lines in reading order, each with how far down `region` its bottom edge sits (0 top … 1 bottom).
    /// `region` is a fraction of the image, top-left origin; nil reads the whole image. Names read better with
    /// `correct` off: language correction turns unusual names into words.
    public static func lines(in image: CGImage, region: (x: Double, y: Double, width: Double, height: Double)? = nil,
                             correct: Bool = true) -> [(text: String, bottom: Double)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-AU"]
        request.usesLanguageCorrection = correct
        if let r = region {  // Vision's origin is bottom-left
            request.regionOfInterest = CGRect(x: r.x, y: 1 - r.y - r.height, width: r.width, height: r.height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
        // Boxes are relative to the region. Sort top to bottom, then left to right.
        let observations = (request.results ?? []).sorted {
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01
                ? $0.boundingBox.midY > $1.boundingBox.midY
                : $0.boundingBox.minX < $1.boundingBox.minX
        }
        var seen: Set<String> = []
        return observations.compactMap { o in
            guard let text = o.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                  text.count >= minimumLineLength, seen.insert(text).inserted else { return nil }
            return (text, 1 - Double(o.boundingBox.minY))
        }
    }

    /// Saves a slide. Only ever called with slides switched on.
    public static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }
}
