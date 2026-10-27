import XCTest
@testable import Lyra

/// The sign-in redirect lands on this Mac: a real listener on loopback, reached like a browser would.
final class LoopbackListenerTests: XCTestCase {
    func testCallbackArrivesOnLocalhostAndTheBrowserIsToldItIsDone() async throws {
        for host in ["127.0.0.1", "localhost"] {
            let listener = LoopbackListener()
            let port = try await listener.start()
            let (data, response) = try await URLSession.shared.data(from: URL(string: "http://\(host):\(port)/?state=s&code=c")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, host)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("You can close this tab"), host)
            let target = try await listener.callbackTarget()
            XCTAssertEqual(target, "/?state=s&code=c", host)
            listener.stop()
        }
    }

    func testFaviconIsNotTheCallbackAndStopEndsTheWait() async throws {
        let listener = LoopbackListener()
        let port = try await listener.start()
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        listener.stop()
        do { _ = try await listener.callbackTarget(); XCTFail("expected cancellation") } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testStopBeforeStartDoesNotHang() async throws {
        let listener = LoopbackListener()
        listener.stop()
        do { _ = try await listener.start(); XCTFail("expected cancellation") } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
