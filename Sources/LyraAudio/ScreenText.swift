import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

/// Reads the words on a meeting app's front window (slide titles, workshop names) so Claude can name the meeting.
/// The screenshot lives in memory only and is never written anywhere.
public enum ScreenText {
    private static let minimumLineLength = 3
    private static let maximumPixelWidth = 2400

    /// Lines of text in reading order, or [] without Screen Recording permission or on any failure.
    public static func read(pid: pid_t) async -> [String] {
        guard CGPreflightScreenCaptureAccess() else { return [] }
        let owner = CoreAudioMicUsage.owningApp(of: pid)?.processIdentifier ?? pid
        guard let window = await frontWindow(ownedBy: owner), let image = await capture(window) else { return [] }
        return recognise(image)
    }

    /// The owning app's frontmost normal window, using the front-to-back order of `CGWindowList`.
    private static func frontWindow(ownedBy owner: pid_t) async -> SCWindow? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == owner && $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1
        }
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        return candidates.min { rank($0, in: order) < rank($1, in: order) }
    }

    private static func rank(_ window: SCWindow, in order: [CGWindowID]) -> Int {
        order.firstIndex(of: window.windowID) ?? Int.max
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

    private static func recognise(_ image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-AU"]
        request.usesLanguageCorrection = true
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
        // Vision's origin is bottom-left: higher y is higher on screen. Sort top to bottom, then left to right.
        let observations = (request.results ?? []).sorted {
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01
                ? $0.boundingBox.midY > $1.boundingBox.midY
                : $0.boundingBox.minX < $1.boundingBox.minX
        }
        var seen: Set<String> = []
        return observations
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= minimumLineLength && seen.insert($0).inserted }
    }
}
