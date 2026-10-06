//
//  CustomFanCurveTests.swift
//  ThermalForge
//
//  The custom-curve model: interpolation, the hardware min/max bounds, validation,
//  normalizing, the editing rules and the JSON form. Expected interpolation values were
//  computed independently of the Swift code (a separate model of the same rule).
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Custom fan curves")
struct CustomFanCurveTests {

    /// 2317...7826 RPM, a typical Apple Silicon fan.
    static let minRPM: Float = 2317
    static let maxRPM: Float = 7826
    static let minFraction: Float = 2317 / 7826

    private func curve(_ points: [(Float, Float)]) -> CustomFanCurve {
        CustomFanCurve(name: "T", points: points.map { CurvePoint(temp: $0.0, percent: $0.1) })
    }

    // MARK: - Interpolation

    @Test("The example curve (45°→min, 55°→30%, 65°→50%, 75°→75%, 85°→100%) interpolates between its points")
    func exampleInterpolation() {
        let c = CustomFanCurve.example()
        let cases: [(Float, Float)] = [
            (40, 0.2961), (45, 0.2961), (50, 0.2980), (55, 0.3000), (60, 0.4000), (65, 0.5000),
            (70, 0.6250), (75, 0.7500), (80, 0.8750), (85, 1.0000), (90, 1.0000),
        ]
        for (temp, expected) in cases {
            let got = c.fraction(at: temp, minFraction: Self.minFraction)
            #expect(abs(got - expected) < 0.0006, "at \(temp) °C: got \(got), expected \(expected)")
        }
    }

    @Test("Between two points the curve is exactly linear")
    func linearBetweenPoints() {
        let c = curve([(50, 20), (70, 80)])
        #expect(abs(c.fraction(at: 60, minFraction: 0) - 0.5) < 0.0001)
        #expect(abs(c.fraction(at: 55, minFraction: 0) - 0.35) < 0.0001)
        #expect(abs(c.fraction(at: 65, minFraction: 0) - 0.65) < 0.0001)
    }

    @Test("It passes through every point exactly")
    func passesThroughPoints() {
        let c = curve([(40, 10), (55, 35), (70, 60), (90, 100)])
        for p in c.points {
            #expect(abs(c.fraction(at: p.temp, minFraction: 0) - p.percent / 100) < 0.0001)
        }
    }

    @Test("Below the first point it holds the first point's speed; above the last, the last's")
    func holdsAtTheEnds() {
        let c = curve([(50, 30), (80, 70)])
        #expect(abs(c.fraction(at: 10, minFraction: 0) - 0.30) < 0.0001)
        #expect(abs(c.fraction(at: 50, minFraction: 0) - 0.30) < 0.0001)
        #expect(abs(c.fraction(at: 80, minFraction: 0) - 0.70) < 0.0001)
        #expect(abs(c.fraction(at: 94, minFraction: 0) - 0.70) < 0.0001)
        #expect(abs(c.fraction(at: 200, minFraction: 0) - 0.70) < 0.0001)
    }

    @Test("Any number of points works, from 2 up to the limit")
    func manyPoints() {
        for count in [2, 3, 8, CustomFanCurve.maxPoints] {
            let points = (0..<count).map { i in
                CurvePoint(temp: 40 + Float(i) * 3, percent: Float(i) * 100 / Float(count - 1))
            }
            let c = CustomFanCurve(name: "T", points: points)
            #expect(c.validate().isEmpty, "\(count) points")
            #expect(abs(c.fraction(at: points.last!.temp, minFraction: 0) - 1.0) < 0.0001)
        }
    }

    // MARK: - Hardware bounds

    @Test("The result is never below the fan's minimum or above its maximum, whatever the points say")
    func staysWithinHardwareRange() {
        let weird = curve([(40, 0), (60, 5), (80, 100)])
        for t in stride(from: Float(0), through: 140, by: 0.5) {
            let f = weird.fraction(at: t, minFraction: Self.minFraction)
            #expect(f >= Self.minFraction - 0.00001 && f <= 1.0, "fraction at \(t) °C: \(f)")
            let rpm = weird.rpm(at: t, minRPM: Self.minRPM, maxRPM: Self.maxRPM)
            #expect(rpm >= Self.minRPM && rpm <= Self.maxRPM, "rpm at \(t) °C: \(rpm)")
        }
    }

    @Test("A 'minimum RPM' point (0%) resolves to exactly the fan's minimum RPM; 100% to exactly its maximum")
    func minimumAndMaximumRPM() {
        let c = CustomFanCurve.example()
        #expect(c.rpm(at: 45, minRPM: Self.minRPM, maxRPM: Self.maxRPM) == Self.minRPM)
        #expect(c.rpm(at: 30, minRPM: Self.minRPM, maxRPM: Self.maxRPM) == Self.minRPM)
        #expect(c.rpm(at: 85, minRPM: Self.minRPM, maxRPM: Self.maxRPM) == Self.maxRPM)
        #expect(c.rpm(at: 94, minRPM: Self.minRPM, maxRPM: Self.maxRPM) == Self.maxRPM)
    }

    @Test("A speed under the hardware minimum resolves to the minimum; the climb starts from it")
    func belowMinimumResolvesToMinimum() {
        // 5% is under the 29.6% hardware floor, so the point sits at the floor.
        let c = curve([(40, 5), (80, 100)])
        #expect(abs(c.fraction(at: 40, minFraction: Self.minFraction) - Self.minFraction) < 0.0001)
        // Halfway between the floor and 100%.
        let mid = (Self.minFraction + 1) / 2
        #expect(abs(c.fraction(at: 60, minFraction: Self.minFraction) - mid) < 0.0001)
    }

    @Test("A fan that reports no maximum can't produce a speed above the minimum it gave")
    func zeroMaximumIsHandled() {
        let c = CustomFanCurve.example()
        #expect(c.rpm(at: 70, minRPM: 2000, maxRPM: 0) == 2000)
    }

    // MARK: - Validation

    @Test("The example curve is valid")
    func exampleIsValid() {
        #expect(CustomFanCurve.example().validate().isEmpty)
    }

    @Test("Too few points, too many points")
    func pointCountLimits() {
        #expect(curve([(50, 30)]).validate().contains(.tooFewPoints(1)))
        let many = (0..<17).map { CurvePoint(temp: 30 + Float($0) * 3, percent: Float($0) * 5) }
        #expect(CustomFanCurve(name: "T", points: many).validate().contains(.tooManyPoints(17)))
    }

    @Test("No point may be at or above the 95 °C safety limit, or below 30 °C")
    func temperatureRange() {
        #expect(CustomFanCurve.maxTemp < FanProfile.safetyTempThreshold)
        #expect(curve([(50, 30), (95, 100)]).validate().contains(.temperatureOutOfRange(95)))
        #expect(curve([(29, 30), (60, 100)]).validate().contains(.temperatureOutOfRange(29)))
        #expect(curve([(30, 0), (94, 100)]).validate().isEmpty)
    }

    @Test("Percent must be 0...100 and finite")
    func percentRange() {
        #expect(curve([(50, -1), (60, 50)]).validate().contains(.percentOutOfRange(-1)))
        #expect(curve([(50, 30), (60, 101)]).validate().contains(.percentOutOfRange(101)))
        #expect(!curve([(50, .nan), (60, 50)]).validate().isEmpty)
    }

    @Test("Points must be ordered and at least 1 °C apart")
    func spacing() {
        #expect(curve([(50, 30), (50.5, 40)]).validate().contains(.pointsTooClose(atTemp: 50.5)))
        #expect(curve([(60, 30), (50, 40)]).validate().contains(.pointsTooClose(atTemp: 50)))
        #expect(curve([(50, 30), (51, 40)]).validate().isEmpty)
    }

    @Test("Speed must not decrease as temperature rises")
    func monotonic() {
        #expect(curve([(50, 60), (60, 40)]).validate().contains(.speedDecreases(atTemp: 60)))
        #expect(curve([(50, 60), (60, 60)]).validate().isEmpty)
    }

    @Test("Name: required, at most 40 characters")
    func nameRules() {
        var c = CustomFanCurve.example()
        c.name = "   "
        #expect(c.validate().contains(.emptyName))
        c.name = String(repeating: "x", count: 41)
        #expect(c.validate().contains(.nameTooLong(41)))
        c.name = String(repeating: "x", count: 40)
        #expect(c.validate().isEmpty)
    }

    @Test("Tuning values must be in range")
    func parameterRanges() {
        var c = CustomFanCurve.example()
        c.hysteresisC = 7
        #expect(c.validate().contains(.parameterOutOfRange("Hysteresis")))
        c = CustomFanCurve.example()
        c.coolDownDelaySec = 61
        #expect(c.validate().contains(.parameterOutOfRange("Cool-down delay")))
        c = CustomFanCurve.example()
        c.rampUpPerSec = 0
        #expect(c.validate().contains(.parameterOutOfRange("Speed-up rate")))
        c = CustomFanCurve.example()
        c.rampDownPerSec = .nan
        #expect(c.validate().contains(.parameterOutOfRange("Slow-down rate")))
    }

    @Test("Ids: a made id is valid; built-in ids, odd characters and path tricks are not")
    func idRules() {
        #expect(CustomFanCurve.isValidID(CustomFanCurve.makeID()))
        #expect(CustomFanCurve.makeID().hasPrefix("custom-"))
        #expect(CustomFanCurve.makeID() != CustomFanCurve.makeID())
        for bad in ["balanced", "performance", "max", "silent", "smart", "custom-", "custom-A",
                    "custom-../x", "custom-a/b", "custom-a b", "../custom-a", ""] {
            #expect(!CustomFanCurve.isValidID(bad), "\(bad)")
        }
        var c = CustomFanCurve.example()
        c.id = "balanced"
        #expect(c.validate().contains(.invalidID))
    }

    // MARK: - Normalizing

    @Test("normalized() sorts, clamps, and forces speed not to decrease with temperature")
    func normalizing() {
        let messy = curve([(70, 80), (50, 20), (60, 10), (200, 150), (-5, -3)])
        let n = messy.normalized()
        #expect(n.points.map { $0.temp } == [30, 50, 60, 70, 94])
        // 60°→10 was lower than 50°→20: raised to 20. 94 was 150: clamped to 100.
        #expect(n.points.map { $0.percent } == [0, 20, 20, 80, 100])
        #expect(n.validate().isEmpty)
    }

    @Test("normalized() merges points closer than 1 °C, keeping the higher speed")
    func normalizingMerges() {
        let n = curve([(50, 20), (50.5, 30), (60, 40)]).normalized()
        #expect(n.points == [CurvePoint(temp: 50, percent: 30), CurvePoint(temp: 60, percent: 40)])
    }

    @Test("normalized() is idempotent and leaves a valid curve unchanged")
    func normalizingIdempotent() {
        let valid = CustomFanCurve.example()
        #expect(valid.normalized() == valid)
        let messy = curve([(70, 80), (50, 20), (60, 10)])
        #expect(messy.normalized().normalized() == messy.normalized())
    }

    @Test("normalized() clamps tuning values and trims the name")
    func normalizingParameters() {
        var c = CustomFanCurve.example()
        c.name = "  Hello  "
        c.hysteresisC = 99
        c.coolDownDelaySec = -4
        c.rampUpPerSec = .infinity
        let n = c.normalized()
        #expect(n.name == "Hello")
        #expect(n.hysteresisC == CustomFanCurve.hysteresisRange.upperBound)
        #expect(n.coolDownDelaySec == CustomFanCurve.coolDownDelayRange.lowerBound)
        #expect(n.rampUpPerSec.isFinite)
        #expect(n.validate().isEmpty)
    }

    // MARK: - Editing

    @Test("addPoint inserts in order and keeps speed non-decreasing")
    func addPoint() {
        var c = CustomFanCurve.example()
        #expect(c.addPoint(temp: 60, percent: 5))
        #expect(c.points.count == 6)
        #expect(c.points.map { $0.temp } == [45, 55, 60, 65, 75, 85])
        // 5% is below its neighbour at 55° (30%), so it was raised to keep the curve rising.
        #expect(c.points[2].percent == 30)
        #expect(c.validate().isEmpty)
    }

    @Test("addPoint refuses a point within 1 °C of an existing one, and a point beyond the limit")
    func addPointRefusals() {
        var c = CustomFanCurve.example()
        #expect(!c.addPoint(temp: 55.5, percent: 40))
        #expect(c.points.count == 5)

        var full = CustomFanCurve(name: "T", points: (0..<CustomFanCurve.maxPoints).map {
            CurvePoint(temp: 30 + Float($0) * 4, percent: Float($0) * 5)
        })
        #expect(!full.addPoint(temp: 31, percent: 1))
        #expect(full.points.count == CustomFanCurve.maxPoints)
    }

    @Test("addPoint clamps the temperature into the allowed range")
    func addPointClamps() {
        var c = curve([(50, 30), (60, 50)])
        #expect(c.addPoint(temp: 120, percent: 100))
        #expect(c.points.last?.temp == CustomFanCurve.maxTemp)
        #expect(c.validate().isEmpty)
    }

    @Test("removePoint never leaves fewer than 2 points")
    func removePoint() {
        var c = CustomFanCurve.example()
        #expect(c.removePoint(at: 2))
        #expect(c.points.count == 4)
        #expect(!c.removePoint(at: 99))
        #expect(c.removePoint(at: 0))
        #expect(c.removePoint(at: 0))
        #expect(c.points.count == 2)
        #expect(!c.removePoint(at: 0))
        #expect(c.points.count == 2)
    }

    @Test("movePoint can't drag a point past its neighbours, in temperature or speed")
    func movePoint() {
        var c = CustomFanCurve.example()   // 45/0, 55/30, 65/50, 75/75, 85/100
        c.movePoint(at: 1, toTemp: 80, toPercent: 100)
        #expect(c.points[1].temp == 64)      // one degree short of the next point (65)
        #expect(c.points[1].percent == 50)   // no higher than the next point's speed
        c.movePoint(at: 1, toTemp: 10, toPercent: -5)
        #expect(c.points[1].temp == 46)      // one degree past the previous point (45)
        #expect(c.points[1].percent == 0)    // no lower than the previous point's speed
        #expect(c.validate().isEmpty)
    }

    @Test("movePoint keeps the end points inside the allowed temperature range")
    func movePointEnds() {
        var c = CustomFanCurve.example()
        c.movePoint(at: 0, toTemp: 5, toPercent: 0)
        #expect(c.points[0].temp == CustomFanCurve.minTemp)
        c.movePoint(at: 4, toTemp: 150, toPercent: 100)
        #expect(c.points[4].temp == CustomFanCurve.maxTemp)
        #expect(c.validate().isEmpty)
    }

    @Test("movePoint ignores NaN and bad indices")
    func movePointIgnoresGarbage() {
        var c = CustomFanCurve.example()
        let before = c
        c.movePoint(at: 2, toTemp: .nan, toPercent: 50)
        c.movePoint(at: 99, toTemp: 60, toPercent: 50)
        c.movePoint(at: -1, toTemp: 60, toPercent: 50)
        #expect(c == before)
    }

    // MARK: - JSON

    @Test("A curve round-trips through JSON")
    func jsonRoundTrip() throws {
        let c = CustomFanCurve.example(name: "Quiet desk")
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(CustomFanCurve.self, from: data) == c)
    }

    @Test("A file without the tuning fields (an older save) loads with the defaults")
    func jsonDefaults() throws {
        let json = """
        {"id":"custom-abc12345","name":"Old","points":[{"temp":45,"percent":0},{"temp":85,"percent":100}]}
        """
        let c = try JSONDecoder().decode(CustomFanCurve.self, from: Data(json.utf8))
        #expect(c.hysteresisC == CustomFanCurve.defaultHysteresisC)
        #expect(c.rampUpPerSec == CustomFanCurve.defaultRampUpPerSec)
        #expect(c.rampDownPerSec == CustomFanCurve.defaultRampDownPerSec)
        #expect(c.releaseMarginC == CustomFanCurve.defaultReleaseMarginC)
        #expect(c.engageDelaySec == CustomFanCurve.defaultEngageDelaySec)
        #expect(c.coolDownDelaySec == CustomFanCurve.defaultCoolDownDelaySec)
        #expect(c.validate().isEmpty)
    }

    @Test("Unknown fields are ignored; missing required fields fail")
    func jsonStrictness() {
        let extra = #"{"id":"custom-abc12345","name":"X","points":[{"temp":45,"percent":0},{"temp":85,"percent":100}],"future":1}"#
        #expect((try? JSONDecoder().decode(CustomFanCurve.self, from: Data(extra.utf8))) != nil)
        let missing = #"{"id":"custom-abc12345","name":"X"}"#
        #expect((try? JSONDecoder().decode(CustomFanCurve.self, from: Data(missing.utf8))) == nil)
    }

    // MARK: - Profile facade

    @Test("FanProfile(custom:) stands in for the curve and is recognised as custom")
    func profileFacade() {
        let c = CustomFanCurve.example(name: "Mine")
        let profile = FanProfile(custom: c)
        #expect(profile.id == c.id)
        #expect(profile.name == "Mine")
        #expect(profile.isCustom)
        #expect(!profile.curve.handsOff)
        #expect(profile.curve.startTemp == 45)
        #expect(profile.curve.ceilingTemp == 85)
        #expect(profile.curve.stopTemp == 40)
        #expect(profile.curve.maxRPMPercent == 1.0)
    }

    @Test("The built-in profiles are not custom, and a custom id can't collide with one")
    func builtInsAreNotCustom() {
        for profile in FanProfile.builtIn + [FanProfile.smart] {
            #expect(!profile.isCustom, "\(profile.id)")
            #expect(!CustomFanCurve.isValidID(profile.id), "\(profile.id)")
        }
    }
}
