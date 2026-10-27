import AudioToolbox
import CoreAudio
import Foundation
import LyraCore

/// Records one app's audio output via a Core Audio process tap. Hears the app even with system
/// output muted (`muteBehavior = .unmuted`), and never touches what the user hears.
public final class AppAudioRecorder: TrackRecorder {
    private let target: MicUser
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var writer: CAFWriter?
    private var paused = false

    public init(target: MicUser) { self.target = target }

    public func start(writingTo url: URL) throws {
        guard writer == nil, procID == nil else { throw AudioError(description: "app audio recorder already started") }
        let processes = matchingProcesses()
        guard !processes.isEmpty else {
            throw AudioError(description: "no Core Audio process for \(target.appName) (pid \(target.pid), bundle '\(target.bundleID)')")
        }
        do {
            let tap = CATapDescription(stereoMixdownOfProcesses: processes)
            tap.uuid = UUID()
            tap.name = "Lyra meeting tap"
            tap.isPrivate = true
            tap.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(tap, &tapID), "create process tap")

            guard let format = CoreAudioObject.value(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()) else {
                throw AudioError(description: "read tap format failed")
            }
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Lyra meeting capture",
                kAudioAggregateDeviceUIDKey: "au.aidos.lyra.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "create aggregate device")

            let writer = try CAFWriter(url: url, format: format)
            self.writer = writer
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, input, inputTime, _, _ in
                writer.write(input, hostTime: inputTime.pointee.mHostTime)
            }, "create IO proc")
            try check(AudioDeviceStart(deviceID, procID), "start aggregate device")
        } catch {
            _ = teardown()
            throw error
        }
    }

    public var level: Float { writer?.recentPeak ?? 0 }

    public func pause() throws {
        guard let procID, !paused else { return }
        try check(AudioDeviceStop(deviceID, procID), "pause aggregate device")
        paused = true
    }

    public func resume() throws {
        guard let procID else { throw AudioError(description: "app audio recorder isn't running") }
        guard paused else { return }
        try check(AudioDeviceStart(deviceID, procID), "restart aggregate device")
        paused = false
    }

    nonisolated(nonsending) public func stop() async -> TrackResult {
        teardown() ?? TrackResult(kind: .meeting, url: URL(fileURLWithPath: "/dev/null"), seconds: 0, peakLevel: 0, error: "not recording")
    }

    deinit { _ = teardown() }

    /// Bundle match covers helpers (com.google.Chrome.helper); processes with no bundle match by PID.
    private func matchingProcesses() -> [AudioObjectID] {
        CoreAudioObject.processObjects().filter { object in
            if target.bundleID.isEmpty {
                let pid: pid_t? = CoreAudioObject.scalar(object, kAudioProcessPropertyPID)
                return pid == target.pid
            }
            let bundle = CoreAudioObject.string(object, kAudioProcessPropertyBundleID) ?? ""
            return bundle == target.bundleID || bundle.hasPrefix(target.bundleID + ".")
        }
    }

    /// Stops IO before closing the file; safe to call repeatedly. Returns a result only if a file was open.
    private func teardown() -> TrackResult? {
        var problems: [String] = []
        if let procID {
            if !paused, AudioDeviceStop(deviceID, procID) != noErr { problems.append("stop device failed") }
            paused = false
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
        }
        if deviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        guard let writer else { return nil }
        self.writer = nil
        return writer.finish(kind: .meeting, extraError: problems.isEmpty ? nil : problems.joined(separator: "; "))
    }
}
