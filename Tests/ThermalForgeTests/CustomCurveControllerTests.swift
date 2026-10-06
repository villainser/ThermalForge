//
//  CustomCurveControllerTests.swift
//  ThermalForge
//
//  The custom-curve control loop: engage and release, the rate limits, hysteresis and
//  the cool-down delay (the part that keeps the fans from hunting when the reading
//  wobbles), and the hardware bounds. Expected figures come from an independent model
//  of the same rules.
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Custom curve controller")
struct CustomCurveControllerTests {

    static let minFraction: Float = 2317 / 7826

    private typealias Decision = CustomCurveController.Decision

    private func controller(_ curve: CustomFanCurve = .example()) -> CustomCurveController {
        CustomCurveController(curve: curve)
    }

    /// One update at `now`, with `dt` since the previous one.
    @discardableResult
    private func step(_ c: inout CustomCurveController, _ temp: Float, at now: Double,
                      dt: Double = 1) -> Decision {
        c.update(temp: temp, dt: dt, now: now, minFraction: Self.minFraction)
    }

    private func fraction(of decision: Decision) -> Float? {
        if case .set(let f) = decision { return f }
        return nil
    }

    /// Warm up: sit at `temp` for `seconds`, one update per second, from `start`.
    @discardableResult
    private func settle(_ c: inout CustomCurveController, at temp: Float, seconds: Int,
                        from start: Double = 0) -> Double {
        var now = start
        for _ in 0..<seconds {
            step(&c, temp, at: now)
            now += 1
        }
        return now
    }

    // MARK: - Engage and release

    @Test("Fans engage only after the temperature has stayed at or above the first point for the engage delay")
    func engageDelay() {
        var c = controller()                       // first point 45 °C, delay 3 s
        let temps: [Float] = [44, 46, 46, 46, 46]
        var decisions: [Decision] = []
        for (i, t) in temps.enumerated() { decisions.append(step(&c, t, at: Double(i))) }
        #expect(Array(decisions[0...3]) == [.none, .none, .none, .none])
        let engaged = fraction(of: decisions[4])
        #expect(engaged != nil)
        #expect(c.isRunning)
        #expect(abs((engaged ?? 0) - Self.minFraction) < 0.01)   // starts from the hardware minimum
    }

    @Test("Dipping back below the first point restarts the engage delay")
    func engageDelayRestarts() {
        var c = controller()
        let temps: [Float] = [46, 46, 44, 46, 46, 46, 46]
        var decisions: [Decision] = []
        for (i, t) in temps.enumerated() { decisions.append(step(&c, t, at: Double(i))) }
        // Crossed again at t=3; engages 3 s later, at t=6.
        #expect(decisions[0...5].allSatisfy { $0 == .none })
        #expect(fraction(of: decisions[6]) != nil)
    }

    @Test("Below the first point, nothing is ever sent")
    func belowStartDoesNothing() {
        var c = controller()
        for i in 0..<60 { #expect(step(&c, 40, at: Double(i)) == .none) }
        #expect(!c.isRunning)
    }

    @Test("Fans are released only once the temperature is below the first point minus the release margin")
    func releaseMargin() {
        var c = controller()                       // first point 45, margin 5: release below 40
        var now = settle(&c, at: 46, seconds: 10)
        #expect(c.isRunning)
        #expect(step(&c, 40, at: now) != .release)  // exactly at the edge: still held
        now += 1
        #expect(step(&c, 39.9, at: now) == .release)
        #expect(!c.isRunning)
        now += 1
        // A release is followed by a fresh engage delay, not an instant restart.
        #expect(step(&c, 46, at: now) == .none)
    }

    @Test("Between the release point and the start point the fans stay on, at the curve's speed")
    func hysteresisBandKeepsRunning() {
        var c = controller()
        var now = settle(&c, at: 46, seconds: 10)
        for t in stride(from: Float(44), through: 41, by: -1) {
            #expect(step(&c, t, at: now) != .release, "at \(t) °C")
            now += 1
        }
        #expect(c.isRunning)
    }

    // MARK: - Rate limits

    @Test("Speed rises no faster than the speed-up limit below 85 °C")
    func rampUp() {
        var c = controller()                       // 0.08 per second
        var now = settle(&c, at: 46, seconds: 5)
        var previous = c.lastFraction
        var steps: [Float] = []
        for _ in 0..<8 {
            if let f = fraction(of: step(&c, 80, at: now)) {
                #expect(f - previous <= 0.08 + 0.00001, "step from \(previous) to \(f)")
                steps.append(f)
                previous = f
            }
            now += 1
        }
        #expect(abs(steps[0] - 0.3761) < 0.001)           // minimum + one step
        #expect(abs((steps.last ?? 0) - 0.875) < 0.001)   // the curve's value at 80 °C
    }

    @Test("From 85 °C up, the speed-up limit is lifted: the target is reached at once")
    func rampLiftedWhenUrgent() {
        var c = controller()
        let now = settle(&c, at: 46, seconds: 5)
        #expect(fraction(of: step(&c, 86, at: now)) == 1.0)
    }

    @Test("Speed falls no faster than the slow-down limit, and never below the hardware minimum")
    func rampDown() {
        var c = controller()                       // 0.03 per second, cool-down delay 8 s
        var now = settle(&c, at: 85, seconds: 20)
        #expect(c.lastFraction == 1.0)
        var previous = c.lastFraction
        for _ in 0..<120 {
            if let f = fraction(of: step(&c, 50, at: now)) {
                #expect(previous - f <= 0.03 + 0.00001, "step from \(previous) to \(f)")
                #expect(f >= Self.minFraction - 0.00001)
                previous = f
            }
            now += 1
        }
        #expect(abs(previous - 0.2988) < 0.002)    // curve value at 50 °C + the 2 °C band
    }

    @Test("The rate limit scales with elapsed time, so a 2 s poll moves twice as far as a 1 s poll")
    func rampScalesWithElapsedTime() {
        var one = controller()
        var two = controller()
        settle(&one, at: 46, seconds: 5)
        settle(&two, at: 46, seconds: 5)
        let a = fraction(of: step(&one, 80, at: 10, dt: 1)) ?? 0
        let b = fraction(of: step(&two, 80, at: 10, dt: 2)) ?? 0
        #expect(abs((b - Self.minFraction) - 2 * (a - Self.minFraction)) < 0.002)
    }

    @Test("A huge elapsed time (the clock jumped, say after sleep) moves the speed by at most 6 s of ramp")
    func elapsedTimeIsCapped() {
        var c = controller()
        settle(&c, at: 46, seconds: 5)
        let f = fraction(of: step(&c, 80, at: 10, dt: 1000)) ?? 0
        #expect(abs(f - (Self.minFraction + 0.48)) < 0.002)
    }

    // MARK: - No hunting

    /// Sits at 65 °C for 60 s, then flips ±`amplitude` every `dt` seconds for `seconds`.
    /// Returns how many commands the flipping caused, and when the last one was sent.
    private func oscillate(amplitude: Float, dt: Double, seconds: Double,
                           curve: CustomFanCurve = .example()) -> (commands: Int, lastAt: Double) {
        var c = controller(curve)
        var now = 0.0
        while now < 60 {
            step(&c, 65, at: now, dt: dt)
            now += dt
        }
        let start = now
        var commands = 0
        var lastAt = 0.0
        var high = true
        while now < start + seconds {
            let temp: Float = 65 + (high ? amplitude : -amplitude)
            if fraction(of: step(&c, temp, at: now, dt: dt)) != nil {
                commands += 1
                lastAt = now - start
            }
            high.toggle()
            now += dt
        }
        return (commands, lastAt)
    }

    @Test("A reading that flips between two values on every poll, ±0.5 to ±3 °C, at 1 s and 2 s polling, does not make the fans hunt")
    func oscillationDoesNotCauseHunting() {
        for amplitude: Float in [0.5, 1, 2, 3] {
            for dt in [1.0, 2.0] {
                let result = oscillate(amplitude: amplitude, dt: dt, seconds: 300)
                // At most the one step up to the peak, and nothing after the first 10 s.
                #expect(result.commands <= 2, "±\(amplitude) °C at \(dt) s: \(result.commands) commands")
                #expect(result.lastAt < 10, "±\(amplitude) °C at \(dt) s: last command at \(result.lastAt) s")
            }
        }
    }

    @Test("Without the cool-down delay the same oscillation does make the fans hunt (the delay is what prevents it)")
    func oscillationWithoutDelayHunts() {
        var curve = CustomFanCurve.example()
        curve.coolDownDelaySec = 0
        let result = oscillate(amplitude: 2, dt: 1, seconds: 300, curve: curve)
        #expect(result.commands > 100)
    }

    @Test("A slow, real swing in temperature is still followed")
    func slowSwingIsFollowed() {
        var c = controller()
        var now = settle(&c, at: 65, seconds: 60)
        var lowest: Float = 1
        var highest: Float = 0
        var commands = 0
        // 60 s period, ±5 °C, one reading a second.
        for i in 0..<300 {
            let temp: Float = 65 + (i % 60 < 30 ? 5 : -5)
            if let f = fraction(of: step(&c, temp, at: now)) {
                commands += 1
                lowest = min(lowest, f)
                highest = max(highest, f)
            }
            now += 1
        }
        #expect(commands > 5)
        #expect(highest - lowest > 0.1)
    }

    @Test("A real cool-down is followed after the cool-down delay, then eased down at the slow-down rate")
    func coolDownIsFollowed() {
        var c = controller()
        var now = settle(&c, at: 85, seconds: 20)
        var firstDropAt: Double?
        let start = now
        for i in 0..<60 {
            let temp = 85 - 35 * Float(i + 1) / 60       // 85 -> 50 °C over a minute
            if let f = fraction(of: step(&c, temp, at: now)), f < 1.0, firstDropAt == nil {
                firstDropAt = now - start
            }
            now += 1
        }
        // Nothing happens for the cool-down delay (8 s); then it starts to ease down.
        #expect((firstDropAt ?? 0) >= 8)
        #expect((firstDropAt ?? 100) < 20)
        #expect(c.lastFraction < 0.6)
    }

    // MARK: - Hardware bounds

    @Test("Every speed sent is within the fan's minimum and maximum, over a sweep of temperatures")
    func boundsOverASweep() {
        let curves = [
            CustomFanCurve.example(),
            CustomFanCurve(name: "Aggressive", points: [CurvePoint(temp: 40, percent: 100), CurvePoint(temp: 60, percent: 100)]),
            CustomFanCurve(name: "Timid", points: [CurvePoint(temp: 40, percent: 0), CurvePoint(temp: 94, percent: 1)]),
        ]
        for curve in curves {
            var c = controller(curve)
            var now = 0.0
            for round in 0..<3 {
                let rising = round % 2 == 0
                for i in 0..<100 {
                    let temp = rising ? 30 + Float(i) * 0.7 : 100 - Float(i) * 0.7
                    if let f = fraction(of: step(&c, temp, at: now)) {
                        #expect(f >= Self.minFraction - 0.00001, "\(curve.name) at \(temp) °C: \(f)")
                        #expect(f <= 1.0, "\(curve.name) at \(temp) °C: \(f)")
                    }
                    now += 1
                }
            }
        }
    }

    @Test("Far above the last point the speed reaches exactly 100%; at the hardware minimum it is exactly the minimum")
    func exactEndpoints() {
        var c = controller()
        let now = settle(&c, at: 46, seconds: 5)
        #expect(fraction(of: step(&c, 94, at: now)) == 1.0)

        var timid = controller(CustomFanCurve(name: "T", points: [CurvePoint(temp: 45, percent: 0), CurvePoint(temp: 85, percent: 0)]))
        settle(&timid, at: 60, seconds: 10)
        #expect(abs(timid.lastFraction - Self.minFraction) < 0.0001)
    }

    // MARK: - State handling

    @Test("After the 95 °C override maxed the fans, ramping continues down from 100%, not from a stale value")
    func syncAfterOverride() {
        var c = controller()
        c.syncApplied(fraction: 1.0)
        let decision = step(&c, 70, at: 0)
        #expect(abs((fraction(of: decision) ?? 0) - 0.97) < 0.0001)    // 1.0 - 0.03 per second
    }

    @Test("Replacing the curve keeps the running state; reset() forgets it")
    func replaceAndReset() {
        var c = controller()
        settle(&c, at: 65, seconds: 10)
        let before = c.lastFraction
        var other = CustomFanCurve.example()
        other.points = [CurvePoint(temp: 45, percent: 0), CurvePoint(temp: 90, percent: 100)]
        c.replaceCurve(other)
        #expect(c.isRunning)
        #expect(c.lastFraction == before)
        c.reset()
        #expect(!c.isRunning)
        #expect(c.lastFraction == 0)
    }

    @Test("A NaN reading is ignored")
    func nanIgnored() {
        var c = controller()
        settle(&c, at: 65, seconds: 10)
        let before = c.lastFraction
        #expect(step(&c, .nan, at: 11) == .none)
        #expect(c.lastFraction == before)
        #expect(c.isRunning)
    }

    @Test("Changes smaller than 1% of max RPM are not sent")
    func minimumStep() {
        var c = controller()
        let now = settle(&c, at: 65, seconds: 30)
        let sent = fraction(of: step(&c, 65.1, at: now))
        #expect(sent == nil)
    }
}
