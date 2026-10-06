//
//  CustomFanCurve.swift
//  ThermalForge
//
//  A user-defined fan curve: temperature -> fan speed through any number of points,
//  interpolated between them. This is an additional mode next to the built-in
//  profiles (Balanced, Performance, Max, Smart, Silent); it never replaces them and
//  it never outranks the 95 °C thermal safety override, which stays in ThermalMonitor
//  and the daemon's thermal floor.
//
//  Pure model, no hardware: the fan's min/max RPM are passed in where speeds are
//  resolved, so every function here tests without an SMC.
//
//  Speed units. A point's `percent` is a share of the fan's MAXIMUM RPM (0...100), so a
//  curve means the same thing on any Mac whatever its fans' range. 0 means "the fan's
//  minimum RPM" (fans never run below it once running). Anything under the hardware
//  minimum resolves to the minimum, and nothing ever resolves above the maximum.
//

import Foundation

// MARK: - Point

public struct CurvePoint: Codable, Equatable {
    /// Temperature in °C.
    public var temp: Float
    /// Share of the fan's maximum RPM, 0...100. 0 = the fan's minimum RPM.
    public var percent: Float

    public init(temp: Float, percent: Float) {
        self.temp = temp
        self.percent = percent
    }
}

// MARK: - Validation errors

public enum CurveValidationError: Error, Equatable, CustomStringConvertible {
    case invalidID
    case emptyName
    case nameTooLong(Int)
    case tooFewPoints(Int)
    case tooManyPoints(Int)
    case temperatureOutOfRange(Float)
    case percentOutOfRange(Float)
    /// This point is out of order or within `minPointSpacing` of the one before it.
    case pointsTooClose(atTemp: Float)
    /// Fan speed must not drop as temperature rises.
    case speedDecreases(atTemp: Float)
    case parameterOutOfRange(String)

    public var description: String {
        switch self {
        case .invalidID:
            return "The curve has an invalid id."
        case .emptyName:
            return "Give the curve a name."
        case .nameTooLong(let n):
            return "The name is \(n) characters; the limit is \(CustomFanCurve.maxNameLength)."
        case .tooFewPoints(let n):
            return "A curve needs at least \(CustomFanCurve.minPoints) points (it has \(n))."
        case .tooManyPoints(let n):
            return "A curve can have at most \(CustomFanCurve.maxPoints) points (it has \(n))."
        case .temperatureOutOfRange(let t):
            return "Temperature \(Int(t)) °C is outside \(Int(CustomFanCurve.minTemp))–\(Int(CustomFanCurve.maxTemp)) °C."
        case .percentOutOfRange(let p):
            return "Fan speed \(Int(p))% is outside 0–100%."
        case .pointsTooClose(let t):
            return "The point at \(Int(t)) °C is out of order or closer than \(Int(CustomFanCurve.minPointSpacing)) °C to the previous one."
        case .speedDecreases(let t):
            return "Fan speed drops at \(Int(t)) °C; it must not decrease as temperature rises."
        case .parameterOutOfRange(let name):
            return "\(name) is out of range."
        }
    }
}

// MARK: - Curve

public struct CustomFanCurve: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Ascending by temperature; speed never decreases (see `normalized()`).
    public var points: [CurvePoint]
    /// Falling-temperature dead band (°C). The curve is read at the highest recent
    /// temperature until the measured one has stayed more than this far below it for
    /// `coolDownDelaySec`, so a reading that wobbles by a degree or two doesn't move
    /// the fans. A rising temperature is followed at once; heat is never ignored.
    public var hysteresisC: Float
    /// Fastest speed-up, as a fraction of max RPM per second.
    public var rampUpPerSec: Float
    /// Fastest slow-down, as a fraction of max RPM per second.
    public var rampDownPerSec: Float
    /// How long (seconds) the temperature must stay below the dead band, without once
    /// climbing back out of it, before the curve starts following it down. This is what
    /// keeps a reading that flips between two values every poll from making the fans
    /// hunt, while a real cool-down (which stays low) is still followed. 0 follows a
    /// falling temperature as soon as it leaves the dead band.
    public var coolDownDelaySec: Float
    /// Fans are handed back to the system once the temperature is this far below the
    /// first point (°C), so a start/stop cycle never happens at a single temperature.
    public var releaseMarginC: Float
    /// Seconds the temperature must stay at or above the first point before fans engage.
    public var engageDelaySec: Float

    // MARK: Limits and defaults

    public static let idPrefix = "custom-"
    public static let minPoints = 2
    public static let maxPoints = 16
    public static let maxNameLength = 40
    public static let minTemp: Float = 30
    /// Points above this would be unreachable: at 95 °C the safety override takes over.
    public static let maxTemp: Float = FanProfile.safetyTempThreshold - 1
    public static let minPointSpacing: Float = 1
    /// At or above this temperature the speed-up limit is lifted: when it's this hot,
    /// reaching the target quickly matters more than a gentle ramp.
    public static let urgentTemp: Float = 85

    public static let hysteresisRange: ClosedRange<Float> = 0...6
    public static let rampUpRange: ClosedRange<Float> = 0.01...1.0
    public static let rampDownRange: ClosedRange<Float> = 0.005...0.5
    public static let releaseMarginRange: ClosedRange<Float> = 2...15
    public static let coolDownDelayRange: ClosedRange<Float> = 0...60
    public static let engageDelayRange: ClosedRange<Float> = 0...30

    public static let defaultHysteresisC: Float = 2
    public static let defaultRampUpPerSec: Float = 0.08
    public static let defaultRampDownPerSec: Float = 0.03
    public static let defaultReleaseMarginC: Float = 5
    public static let defaultCoolDownDelaySec: Float = 8
    public static let defaultEngageDelaySec: Float = 3

    // MARK: Init

    public init(id: String = CustomFanCurve.makeID(),
                name: String,
                points: [CurvePoint],
                hysteresisC: Float = CustomFanCurve.defaultHysteresisC,
                rampUpPerSec: Float = CustomFanCurve.defaultRampUpPerSec,
                rampDownPerSec: Float = CustomFanCurve.defaultRampDownPerSec,
                releaseMarginC: Float = CustomFanCurve.defaultReleaseMarginC,
                engageDelaySec: Float = CustomFanCurve.defaultEngageDelaySec,
                coolDownDelaySec: Float = CustomFanCurve.defaultCoolDownDelaySec) {
        self.id = id
        self.name = name
        self.points = points
        self.hysteresisC = hysteresisC
        self.rampUpPerSec = rampUpPerSec
        self.rampDownPerSec = rampDownPerSec
        self.releaseMarginC = releaseMarginC
        self.engageDelaySec = engageDelaySec
        self.coolDownDelaySec = coolDownDelaySec
    }

    /// A fresh curve to start editing from: minimum RPM at 45 °C, 30% at 55, 50% at 65,
    /// 75% at 75, 100% at 85.
    public static func example(name: String = "My curve") -> CustomFanCurve {
        CustomFanCurve(name: name, points: [
            CurvePoint(temp: 45, percent: 0),
            CurvePoint(temp: 55, percent: 30),
            CurvePoint(temp: 65, percent: 50),
            CurvePoint(temp: 75, percent: 75),
            CurvePoint(temp: 85, percent: 100),
        ])
    }

    /// A new id that can't collide with a built-in profile id and is safe as a file name.
    public static func makeID() -> String {
        idPrefix + String(UUID().uuidString.lowercased().prefix(8))
    }

    /// Lower-case letters, digits and "-" only, after the prefix: safe as a file name,
    /// and never one of the built-in ids.
    public static func isValidID(_ id: String) -> Bool {
        guard id.hasPrefix(idPrefix), id.count > idPrefix.count, id.count <= 40 else { return false }
        return id.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
    }

    // MARK: Codable (older files may lack the tuning fields)

    private enum CodingKeys: String, CodingKey {
        case id, name, points, hysteresisC, rampUpPerSec, rampDownPerSec, releaseMarginC, engageDelaySec, coolDownDelaySec
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        points = try c.decode([CurvePoint].self, forKey: .points)
        hysteresisC = try c.decodeIfPresent(Float.self, forKey: .hysteresisC) ?? Self.defaultHysteresisC
        rampUpPerSec = try c.decodeIfPresent(Float.self, forKey: .rampUpPerSec) ?? Self.defaultRampUpPerSec
        rampDownPerSec = try c.decodeIfPresent(Float.self, forKey: .rampDownPerSec) ?? Self.defaultRampDownPerSec
        releaseMarginC = try c.decodeIfPresent(Float.self, forKey: .releaseMarginC) ?? Self.defaultReleaseMarginC
        engageDelaySec = try c.decodeIfPresent(Float.self, forKey: .engageDelaySec) ?? Self.defaultEngageDelaySec
        coolDownDelaySec = try c.decodeIfPresent(Float.self, forKey: .coolDownDelaySec) ?? Self.defaultCoolDownDelaySec
    }

    // MARK: Interpolation

    /// The fraction of the fan's maximum RPM this curve asks for at `temp`, always in
    /// `minFraction...1` (`minFraction` is the hardware minimum over the maximum).
    ///
    /// Each point is first brought into that range, then speeds are interpolated
    /// linearly between neighbouring points. So the point that says "minimum RPM"
    /// really does start the climb from the hardware minimum, and the result can never
    /// fall below the minimum or exceed the maximum. Below the first point the curve
    /// holds the first point's speed; above the last it holds the last's.
    /// Needs `points` ascending by temperature (see `normalized()`).
    public func fraction(at temp: Float, minFraction: Float) -> Float {
        let floorFraction = min(max(minFraction, 0), 1)
        func resolved(_ p: CurvePoint) -> Float {
            min(max(p.percent / 100, floorFraction), 1)
        }
        guard let first = points.first, let last = points.last else { return floorFraction }
        if temp <= first.temp { return resolved(first) }
        if temp >= last.temp { return resolved(last) }
        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            if temp <= b.temp {
                let span = b.temp - a.temp
                guard span > 0 else { return resolved(b) }
                let t = (temp - a.temp) / span
                // Clamped again: float rounding must never nudge the result a hair
                // past the hardware range that the points themselves respect.
                return min(max(resolved(a) + (resolved(b) - resolved(a)) * t, floorFraction), 1)
            }
        }
        return resolved(last)
    }

    /// The same, as an RPM within the fan's reported `minRPM...maxRPM`.
    public func rpm(at temp: Float, minRPM: Float, maxRPM: Float) -> Float {
        guard maxRPM > 0 else { return minRPM }
        let f = fraction(at: temp, minFraction: minRPM / maxRPM)
        return min(max(f * maxRPM, minRPM), maxRPM)
    }

    // MARK: Normalizing and validating

    /// A safe version of this curve: name trimmed, points clamped to the allowed ranges,
    /// sorted by temperature, points closer than `minPointSpacing` merged (keeping the
    /// higher speed), speed forced not to decrease as temperature rises, and every
    /// tuning value clamped to its range. Idempotent. Used on everything loaded from
    /// disk, so a hand-edited file can't produce a curve that slows the fans as it
    /// gets hotter.
    public func normalized() -> CustomFanCurve {
        var c = self
        c.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNameLength))

        var sorted = points.map {
            CurvePoint(temp: Self.clamped($0.temp, Self.minTemp...Self.maxTemp),
                       percent: Self.clamped($0.percent, 0...100))
        }
        sorted.sort { $0.temp < $1.temp }

        var result: [CurvePoint] = []
        for p in sorted {
            guard let last = result.last else {
                result.append(p)
                continue
            }
            if p.temp - last.temp < Self.minPointSpacing {
                result[result.count - 1].percent = max(last.percent, p.percent)
            } else {
                result.append(CurvePoint(temp: p.temp, percent: max(p.percent, last.percent)))
            }
        }
        c.points = result

        c.hysteresisC = Self.clamped(hysteresisC, Self.hysteresisRange)
        c.rampUpPerSec = Self.clamped(rampUpPerSec, Self.rampUpRange)
        c.rampDownPerSec = Self.clamped(rampDownPerSec, Self.rampDownRange)
        c.releaseMarginC = Self.clamped(releaseMarginC, Self.releaseMarginRange)
        c.engageDelaySec = Self.clamped(engageDelaySec, Self.engageDelayRange)
        c.coolDownDelaySec = Self.clamped(coolDownDelaySec, Self.coolDownDelayRange)
        return c
    }

    /// Everything wrong with this curve as it stands, or empty when it's usable. The
    /// editor shows these; the store refuses to save a curve that has any.
    public func validate() -> [CurveValidationError] {
        var errors: [CurveValidationError] = []

        if !Self.isValidID(id) { errors.append(.invalidID) }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { errors.append(.emptyName) }
        if trimmed.count > Self.maxNameLength { errors.append(.nameTooLong(trimmed.count)) }

        if points.count < Self.minPoints { errors.append(.tooFewPoints(points.count)) }
        if points.count > Self.maxPoints { errors.append(.tooManyPoints(points.count)) }

        for p in points {
            if !p.temp.isFinite || p.temp < Self.minTemp || p.temp > Self.maxTemp {
                errors.append(.temperatureOutOfRange(p.temp))
            }
            if !p.percent.isFinite || p.percent < 0 || p.percent > 100 {
                errors.append(.percentOutOfRange(p.percent))
            }
        }

        for i in points.indices.dropFirst() {
            let a = points[i - 1]
            let b = points[i]
            if b.temp - a.temp < Self.minPointSpacing {
                errors.append(.pointsTooClose(atTemp: b.temp))
            } else if b.percent < a.percent {
                errors.append(.speedDecreases(atTemp: b.temp))
            }
        }

        func check(_ value: Float, _ range: ClosedRange<Float>, _ label: String) {
            if !value.isFinite || !range.contains(value) { errors.append(.parameterOutOfRange(label)) }
        }
        check(hysteresisC, Self.hysteresisRange, "Hysteresis")
        check(rampUpPerSec, Self.rampUpRange, "Speed-up rate")
        check(rampDownPerSec, Self.rampDownRange, "Slow-down rate")
        check(releaseMarginC, Self.releaseMarginRange, "Release margin")
        check(engageDelaySec, Self.engageDelayRange, "Engage delay")
        check(coolDownDelaySec, Self.coolDownDelayRange, "Cool-down delay")

        return errors
    }

    // MARK: Editing (used by the editor; kept here so it tests without a UI)

    /// Insert a point, keeping order and non-decreasing speed. False when the curve is
    /// full or the temperature is within `minPointSpacing` of an existing point.
    @discardableResult
    public mutating func addPoint(temp: Float, percent: Float) -> Bool {
        guard points.count < Self.maxPoints, temp.isFinite, percent.isFinite else { return false }
        let t = Self.clamped(temp, Self.minTemp...Self.maxTemp)
        if points.contains(where: { abs($0.temp - t) < Self.minPointSpacing }) { return false }
        let index = points.firstIndex(where: { $0.temp > t }) ?? points.count
        let lower: Float = index > 0 ? points[index - 1].percent : 0
        let upper: Float = index < points.count ? points[index].percent : 100
        let p = min(max(percent, lower), max(lower, upper))
        points.insert(CurvePoint(temp: t, percent: p), at: index)
        return true
    }

    /// Remove a point, never going below `minPoints`.
    @discardableResult
    public mutating func removePoint(at index: Int) -> Bool {
        guard points.count > Self.minPoints, points.indices.contains(index) else { return false }
        points.remove(at: index)
        return true
    }

    /// Move a point, clamped so the curve stays ordered, spaced and non-decreasing:
    /// a point can't be dragged past its neighbours.
    public mutating func movePoint(at index: Int, toTemp temp: Float, toPercent percent: Float) {
        guard points.indices.contains(index), temp.isFinite, percent.isFinite else { return }
        let lowT = index > 0 ? points[index - 1].temp + Self.minPointSpacing : Self.minTemp
        let highT = index < points.count - 1 ? points[index + 1].temp - Self.minPointSpacing : Self.maxTemp
        if lowT <= highT { points[index].temp = min(max(temp, lowT), highT) }
        let lowP: Float = index > 0 ? points[index - 1].percent : 0
        let highP: Float = index < points.count - 1 ? points[index + 1].percent : 100
        if lowP <= highP { points[index].percent = min(max(percent, lowP), highP) }
    }

    // MARK: Helpers

    private static func clamped(_ value: Float, _ range: ClosedRange<Float>) -> Float {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: - Profile facade

extension FanProfile {
    /// A `FanProfile` standing in for a custom curve, so the code that shows the active
    /// profile (name, picker, the monitor's start threshold and hands-off check) keeps
    /// working unchanged. The real control is `CustomCurveController`; the numbers here
    /// only mirror the curve's span.
    public init(custom curve: CustomFanCurve) {
        let c = curve.normalized()
        let first = c.points.first?.temp ?? CustomFanCurve.minTemp
        let last = c.points.last
        self.init(
            id: c.id,
            name: c.name,
            curve: Curve(stopTemp: first - c.releaseMarginC,
                         startTemp: first,
                         ceilingTemp: Swift.max(last?.temp ?? first, first),
                         maxRPMPercent: (last?.percent ?? 100) / 100,
                         handsOff: false, alwaysOn: false, curveShape: .linear,
                         rampUpPerSec: c.rampUpPerSec, rampDownPerSec: c.rampDownPerSec,
                         sustainedTriggerSec: c.engageDelaySec, instantEngage: false)
        )
    }

    /// True for a profile that stands in for a user-defined curve.
    public var isCustom: Bool { id.hasPrefix(CustomFanCurve.idPrefix) }
}
