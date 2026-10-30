import Foundation
import Testing
@testable import CookCore

@Suite("LTTB downsampling")
struct LTTBTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func series(_ count: Int, _ f: (Int) -> Double) -> [Sample] {
        (0..<count).map { Sample(time: t0.addingTimeInterval(Double($0) * 15), celsius: f($0)) }
    }

    @Test func passesThroughWhenSmallEnough() {
        let s = series(50) { Double($0) }
        #expect(LTTB.downsample(s, to: 100) == s)
        #expect(LTTB.downsample(s, to: 2) == s) // invalid threshold
    }

    @Test func returnsThresholdPointsAndKeepsEndpoints() {
        let s = series(10_000) { sin(Double($0) / 300) * 50 + 60 }
        let d = LTTB.downsample(s, to: 500)
        #expect(d.count == 500)
        #expect(d.first == s.first)
        #expect(d.last == s.last)
        #expect(zip(d, d.dropFirst()).allSatisfy { $0.time < $1.time })
    }

    @Test func preservesASpike() {
        let s = series(5_000) { $0 == 2_345 ? 200 : 50 }
        #expect(LTTB.downsample(s, to: 100).contains { $0.celsius == 200 })
    }
}
