import LyraCore
import XCTest

final class DiarizationTests: XCTestCase {
    private func norm(_ v: [Float]) -> Float { v.reduce(0) { $0 + $1 * $1 }.squareRoot() }

    func testDatabasePreferredOverSegments() {
        let out = Diarization.normalisedCentroids(database: ["S1": [3, 4]], segments: [("S1", [1, 0])])
        XCTAssertEqual(out["S1"] ?? [], [0.6, 0.8], accuracy: 1e-6)
    }

    func testFallsBackToSegmentMean() {
        let segments: [(speaker: String, embedding: [Float])] = [("S1", [2, 0]), ("S1", [0, 2]), ("S2", [0, 5])]
        for database in [nil, ["S2": [0, 1]]] as [[String: [Float]]?] {
            let out = Diarization.normalisedCentroids(database: database, segments: segments)
            XCTAssertEqual(out["S1"] ?? [], [0.7071068, 0.7071068], accuracy: 1e-6)
            XCTAssertEqual(out["S2"] ?? [], [0, 1], accuracy: 1e-6)
        }
    }

    func testDegenerateVectorsSkipped() {
        let out = Diarization.normalisedCentroids(
            database: ["zero": [0, 0], "nan": [.nan, 1], "inf": [.infinity, 1], "empty": []],
            segments: [("zero", [1, 0]), ("nan", [1, 0]), ("inf", [1, 0]), ("empty", []),
                       ("ragged", [1, 0]), ("ragged", [1, 0, 0]), ("ok", [0, 0, 2])])
        XCTAssertEqual(Set(out.keys), ["ok"])
        XCTAssertEqual(out["ok"] ?? [], [0, 0, 1], accuracy: 1e-6)
    }

    func testOutputsUnitLength() {
        let out = Diarization.normalisedCentroids(database: ["S1": [0.1, -7, 3]], segments: [("S1", []), ("S2", [5, 5, 5]), ("S2", [1, 2, 3])])
        XCTAssertEqual(out.count, 2)
        for v in out.values { XCTAssertEqual(norm(v), 1, accuracy: 1e-6) }
    }
}

private func XCTAssertEqual(_ a: [Float], _ b: [Float], accuracy: Float, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
