//
//  PollCadenceTests.swift
//  ThermalForge
//
//  The adaptive polling policy. Rates asserted here: 1 s while anything is happening,
//  2 s for a fan-controlling profile holding steady, 5 s for a quiet hands-off (Silent)
//  profile, and every condition that must snap back to 1 s.
//

import Testing

@testable import ThermalForgeCore

@Suite("Adaptive poll cadence")
struct PollCadenceTests {

    /// Feed the same situation once a second for `seconds` and return the last answer.
    private func steady(_ cadence: inout PollCadence, from start: Double = 0, seconds: Int,
                        peak: Float, controls: Bool = false, ui: Bool = false) -> Double {
        var last = 0.0
        for i in 0...seconds {
            last = cadence.next(.init(now: start + Double(i), peak: peak, controlsFans: controls,
                                      engaging: false, fanChanged: false, safetyOverride: false,
                                      uiVisible: ui))
        }
        return last
    }

    private func input(_ now: Double, peak: Float = 45, controls: Bool = false, engaging: Bool = false,
                       fanChanged: Bool = false, overridden: Bool = false,
                       ui: Bool = false) -> PollCadence.Input {
        .init(now: now, peak: peak, controlsFans: controls, engaging: engaging,
              fanChanged: fanChanged, safetyOverride: overridden, uiVisible: ui)
    }

    // MARK: - The three rates

    @Test("A fresh start polls at the active rate until it has seen 10 s of quiet")
    func startsFast() {
        var cadence = PollCadence()
        for t in 0..<10 {
            #expect(cadence.next(input(Double(t))) == 1.0, "t=\(t)")
        }
        #expect(cadence.next(input(10)) == 5.0)
    }

    @Test("Hands-off (Silent), cool and quiet: 5 s")
    func handsOffIdle() {
        var cadence = PollCadence()
        #expect(steady(&cadence, seconds: 30, peak: 45) == 5.0)
    }

    @Test("A fan-controlling profile holding steady: 2 s")
    func controllingSteady() {
        var cadence = PollCadence()
        #expect(steady(&cadence, seconds: 30, peak: 56, controls: true) == 2.0)
    }

    @Test("Hands-off only gets 5 s below 70 °C; at and above it polls at 2 s")
    func handsOffCeiling() {
        var cool = PollCadence()
        #expect(steady(&cool, seconds: 30, peak: 69.9) == 5.0)
        var warm = PollCadence()
        #expect(steady(&warm, seconds: 30, peak: 70) == 2.0)
        var hot = PollCadence()
        #expect(steady(&hot, seconds: 30, peak: 80) == 2.0)
    }

    // MARK: - What snaps back to the active rate

    @Test("At or above 85 °C the rate is always active, for every profile")
    func safetyWatch() {
        for controls in [false, true] {
            var cadence = PollCadence()
            #expect(steady(&cadence, seconds: 60, peak: 85, controls: controls) == 1.0)
            var below = PollCadence()
            #expect(steady(&below, seconds: 60, peak: 84.9, controls: controls) != 1.0)
        }
    }

    @Test("The 95 °C override keeps the active rate")
    func overrideKeepsActive() {
        var cadence = PollCadence()
        _ = steady(&cadence, seconds: 30, peak: 45)
        #expect(cadence.next(input(31, peak: 45, overridden: true)) == 1.0)
    }

    @Test("A 3 °C rise between polls wakes a relaxed poll and holds it for 10 s")
    func riseWakes() {
        var cadence = PollCadence()
        _ = steady(&cadence, seconds: 30, peak: 45)
        #expect(cadence.next(input(35, peak: 45)) == 5.0)

        #expect(cadence.next(input(40, peak: 48)) == 1.0)          // +3 °C
        #expect(cadence.next(input(45, peak: 48)) == 1.0)          // still held
        #expect(cadence.next(input(49.9, peak: 48)) == 1.0)
        // Held for 10 s from the rise, then quiet for 10 s more before relaxing.
        #expect(cadence.next(input(50.1, peak: 48)) == 1.0)
        #expect(cadence.next(input(60, peak: 48)) == 5.0)
    }

    @Test("A 2.9 °C rise is not enough")
    func smallRiseIgnored() {
        var cadence = PollCadence()
        _ = steady(&cadence, seconds: 30, peak: 45)
        #expect(cadence.next(input(35, peak: 47.9)) == 5.0)
    }

    @Test("Engaging or changing the fan speed keeps the active rate, then it settles")
    func fanActivity() {
        var cadence = PollCadence()
        _ = steady(&cadence, seconds: 30, peak: 56, controls: true)
        #expect(cadence.next(input(31, peak: 56, controls: true, fanChanged: true)) == 1.0)
        #expect(cadence.next(input(40, peak: 56, controls: true)) == 1.0)
        #expect(cadence.next(input(41, peak: 56, controls: true)) == 2.0)

        var engaging = PollCadence()
        _ = steady(&engaging, seconds: 30, peak: 56, controls: true)
        #expect(engaging.next(input(31, peak: 56, controls: true, engaging: true)) == 1.0)
    }

    @Test("An open menu caps every rate at the active rate")
    func uiVisible() {
        var cadence = PollCadence()
        #expect(steady(&cadence, seconds: 30, peak: 45) == 5.0)
        #expect(cadence.next(input(31, peak: 45, ui: true)) == 1.0)
        // Closing it lets the slow rate come straight back: there was no activity.
        #expect(cadence.next(input(32, peak: 45, ui: false)) == 5.0)
    }

    @Test("A failed sensor read forces the active rate for 10 s")
    func failure() {
        var cadence = PollCadence()
        _ = steady(&cadence, seconds: 30, peak: 45)
        cadence.noteFailure(now: 31)
        #expect(cadence.next(input(32)) == 1.0)
        #expect(cadence.next(input(40.9)) == 1.0)
        #expect(cadence.next(input(41)) == 5.0)
    }

    @Test("reset() goes back to the active rate, as after a profile switch")
    func reset() {
        var cadence = PollCadence()
        _ = steady(&cadence, seconds: 30, peak: 45)
        cadence.reset()
        #expect(cadence.next(input(31)) == 1.0)
    }

    // MARK: - Tuning

    @Test("The rates follow the tuning, e.g. a slower active rate")
    func tuning() {
        var tuning = PollCadence.Tuning()
        tuning.active = 0.5
        var cadence = PollCadence(tuning: tuning)
        #expect(cadence.next(input(0)) == 0.5)
    }

    // MARK: - Worst case for the 95 °C backstop

    @Test("From the slowest rate, the 95 °C check is at most 5 s away below 70 °C, 2 s below 85 °C, 1 s above")
    func worstCaseLatency() {
        // Silent, quiet at 45 °C: 5 s. Crossing 70 °C moves it to 2 s, and 85 °C to 1 s,
        // so the interval in force whenever the peak could reach 95 °C is never longer
        // than 2 s once it is above 70 °C.
        var cadence = PollCadence()
        _ = steady(&cadence, seconds: 30, peak: 45)
        var now = 40.0
        var interval = 5.0
        for peak in stride(from: Float(46), through: 94, by: 1) {
            interval = cadence.next(input(now, peak: peak))
            now += interval
            if peak >= 85 { #expect(interval == 1.0, "peak \(peak)") }
            else if peak >= 70 { #expect(interval <= 2.0, "peak \(peak)") }
        }
    }
}
