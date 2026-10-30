import Foundation
import Testing
@testable import CookCore

@Suite("Newton EWMA estimator")
struct EstimatorTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Exact Newton heating curve: T(t) = Ta − (Ta − T0)·e^(−kt).
    private func newton(_ t: TimeInterval, ambient: Double = 120, start: Double = 5, k: Double = 0.00015) -> Double {
        ambient - (ambient - start) * exp(-k * t)
    }

    private func feed(_ estimator: inout NewtonEWMAEstimator, until end: TimeInterval, every step: TimeInterval = 15,
                      ambient: Double? = 120, k: Double = 0.00015) {
        var t = 0.0
        while t <= end {
            estimator.ingest(EstimatorInput(time: t0.addingTimeInterval(t),
                                            probeCelsius: newton(t, ambient: ambient ?? 120, k: k),
                                            ambientCelsius: ambient))
            t += step
        }
    }

    @Test func warmingUpBeforeEnoughData() {
        var e = NewtonEWMAEstimator()
        feed(&e, until: 5 * 60)
        #expect(e.estimate(target: Temperature(celsius: 90), now: t0.addingTimeInterval(300)).state == .warmingUp)
    }

    @Test func noDataIsUnavailable() {
        #expect(NewtonEWMAEstimator().estimate(target: Temperature(celsius: 90), now: t0).state == .unavailable)
    }

    @Test func recoversKAndPredictsETAOnCleanNewtonCurve() throws {
        var e = NewtonEWMAEstimator()
        let k = 0.00015
        feed(&e, until: 60 * 60, k: k)
        let estimate = e.estimate(target: Temperature(celsius: 90), now: t0.addingTimeInterval(3600))

        #expect(estimate.state == .estimating)
        #expect(estimate.method == .newton)
        let fittedK = try #require(estimate.k)
        #expect(abs(fittedK - k) / k < 0.05)

        // Analytical: t = ln((Ta − T0)/(Ta − target)) / k
        let truth = t0.addingTimeInterval(log((120.0 - 5) / (120 - 90)) / k)
        let error = abs(try #require(estimate.eta).timeIntervalSince(truth))
        #expect(error < 0.05 * truth.timeIntervalSince(t0.addingTimeInterval(3600)))
    }

    @Test func sparseSamplesStillEstimate() throws {
        // One reading every 12.5 min — wider than the 5 min slope window (e.g. app was suspended).
        var e = NewtonEWMAEstimator()
        feed(&e, until: 3 * 3600, every: 750)
        let estimate = e.estimate(target: Temperature(celsius: 100), now: t0.addingTimeInterval(3 * 3600))
        #expect(estimate.state == .estimating)
        #expect(estimate.method == .newton)
    }

    @Test func fallsBackToLinearWithoutAmbient() {
        var e = NewtonEWMAEstimator()
        feed(&e, until: 30 * 60, ambient: nil)
        let estimate = e.estimate(target: Temperature(celsius: 90), now: t0.addingTimeInterval(1800))
        #expect(estimate.state == .estimating)
        #expect(estimate.method == .linear)
        #expect(estimate.k == nil)
    }

    @Test func fallsBackToLinearWhenAmbientBelowTarget() {
        var e = NewtonEWMAEstimator()
        feed(&e, until: 30 * 60, ambient: 60)
        let estimate = e.estimate(target: Temperature(celsius: 70), now: t0.addingTimeInterval(1800))
        #expect(estimate.method == .linear)
    }

    @Test func reachedWhenAtOrAboveTarget() {
        var e = NewtonEWMAEstimator()
        feed(&e, until: 2 * 60)
        let estimate = e.estimate(target: Temperature(celsius: 6), now: t0.addingTimeInterval(120))
        #expect(estimate.state == .reached)
    }

    @Test func detectsStallInBand() {
        var e = NewtonEWMAEstimator()
        for i in 0...240 { // 1 hour flat at 68 °C
            e.ingest(EstimatorInput(time: t0.addingTimeInterval(Double(i) * 15), probeCelsius: 68, ambientCelsius: 120))
        }
        #expect(e.estimate(target: Temperature(celsius: 95), now: t0.addingTimeInterval(3600)).state == .stalled)
    }

    @Test func flatOutsideStallBandIsUnavailable() {
        var e = NewtonEWMAEstimator()
        for i in 0...240 {
            e.ingest(EstimatorInput(time: t0.addingTimeInterval(Double(i) * 15), probeCelsius: 30, ambientCelsius: 120))
        }
        #expect(e.estimate(target: Temperature(celsius: 95), now: t0.addingTimeInterval(3600)).state == .unavailable)
    }

    @Test func outOfOrderReadingsAreIgnored() {
        var e = NewtonEWMAEstimator()
        e.ingest(EstimatorInput(time: t0.addingTimeInterval(60), probeCelsius: 10))
        e.ingest(EstimatorInput(time: t0, probeCelsius: 99))
        #expect(e.estimate(target: Temperature(celsius: 50), now: t0).state != .reached)
    }

    @Test func leastSquaresSlope() throws {
        let points = (0..<10).map { EstimatorInput(time: t0.addingTimeInterval(Double($0) * 10), probeCelsius: 2 * Double($0) * 10 + 7) }
        #expect(abs(try #require(NewtonEWMAEstimator.leastSquaresSlope(points)) - 2) < 1e-9)
        #expect(NewtonEWMAEstimator.leastSquaresSlope(Array(points.prefix(1))) == nil)
    }

    @Test func blendIsTimeAwareEWMA() {
        #expect(NewtonEWMAEstimator.blend(nil, 5, 0.1) == 5)
        #expect(abs(NewtonEWMAEstimator.blend(10, 0, 0.25) - 7.5) < 1e-12)
    }

    @Test func remainingIsClampedAtZero() {
        let estimate = Estimate(state: .estimating, eta: t0)
        #expect(estimate.remaining(from: t0.addingTimeInterval(100)) == 0)
    }
}
