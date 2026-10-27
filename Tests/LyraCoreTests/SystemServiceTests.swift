import XCTest
@testable import LyraCore

final class SystemServiceTests: XCTestCase {
    func testDictationAndSiriServicesAreNotMeetings() {
        XCTAssertTrue(SystemService.isBackground(executablePath: "/System/Library/PrivateFrameworks/CoreSpeech.framework/corespeechd"))
        XCTAssertTrue(SystemService.isBackground(executablePath: "/System/Library/Frameworks/Speech.framework/Versions/A/XPCServices/localspeechrecognition.xpc/Contents/MacOS/localspeechrecognition"))
    }

    func testRealAppsStayEligible() {
        XCTAssertFalse(SystemService.isBackground(executablePath: "/System/Applications/FaceTime.app/Contents/MacOS/FaceTime"))
        XCTAssertFalse(SystemService.isBackground(executablePath: "/Applications/zoom.us.app/Contents/MacOS/zoom.us"))
        XCTAssertFalse(SystemService.isBackground(executablePath: "/usr/libexec/avconferenced"))
        XCTAssertFalse(SystemService.isBackground(executablePath: nil))
    }
}
