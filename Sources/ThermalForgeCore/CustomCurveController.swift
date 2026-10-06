//
//  CustomCurveController.swift
//  ThermalForge
//
//  The control loop for a custom fan curve: turns a temperature reading into "leave
//  the fans alone", "hand them back to the system", or "set this speed". Pure state
//  machine, no timers, no SMC; time is passed in, so it tests deterministically.
//
//  Between the raw temperature and the fan speed sit three things that keep the fans
//  from hunting when the reading wobbles by a degree or two:
//
//   1. Hysteresis on the temperature the curve is read at. It follows a rising
//      temperature immediately (heat is never ignored). A falling one is followed
//      only once it has stayed more than `hysteresisC` below the held value for
//      `coolDownDelaySec` without once climbing back out of that band; the held value
//      then drops to `hysteresisC` above the reading. A reading that wobbles, even one
//      that flips between two values on every poll, therefore never moves the speed,
//      while a real cool-down, which stays low, is followed.
//   2. A rate limit. Speed rises by at most `rampUpPerSec` and falls by at most
//      `rampDownPerSec` per second, scaled by the real time since the last tick, so
//      it behaves the same at a 1 s poll as at a 2 s one. The speed-up limit is
//      lifted at `CustomFanCurve.urgentTemp`: when it's that hot, getting to the
//      target fast matters more than a gentle ramp.
//   3. A minimum step. A change smaller than 1% of max RPM isn't sent (except to
//      reach the hardware minimum or the maximum exactly), so the daemon isn't
//      written to for noise.
//
//  Fans engage after the temperature has stayed at or above the first point for
//  `engageDelaySec`, and are handed back to the system only once it is
//  `releaseMarginC` below it, so a start/stop cycle never happens at one temperature.
//
//  What this does NOT do: it has no say over the 95 °C safety override. ThermalMonitor
//  checks that before it ever reaches this controller, and the daemon's thermal floor
//  backs it up independently.
//

import Foundation

public struct CustomCurveController {
    public enum Decision: Equatable {
        /// Nothing to send.
        case none
        /// Hand the fans back to the system (Apple's automatic control).
        case release
        /// Hold all fans at this fraction of their maximum RPM (minFraction...1).
        case set(fraction: Float)
    }

    public private(set) var curve: CustomFanCurve
    /// Whether this controller has the fans under manual control.
    public private(set) var isRunning = false
    /// The fraction of max RPM last asked for.
    public private(set) var lastFraction: Float = 0

    private var heldTemp: Float?
    private var aboveSince: TimeInterval?
    /// When the reading first went below the dead band, without leaving it since.
    private var fallingSince: TimeInterval?

    /// The smallest speed change worth sending (fraction of max RPM).
    public static let minStep: Float = 0.01
    /// Longest elapsed time one tick may account for. After a sleep the clock jumps;
    /// a ramp shouldn't leap with it.
    public static let maxStepSeconds: TimeInterval = 6

    public init(curve: CustomFanCurve) {
        self.curve = curve.normalized()
    }

    /// Swap in an edited curve, keeping the running state so the fans don't glitch.
    public mutating func replaceCurve(_ curve: CustomFanCurve) {
        self.curve = curve.normalized()
    }

    /// Forget everything: a profile switch. The caller sends its own reset to the fans.
    public mutating func reset() {
        isRunning = false
        lastFraction = 0
        heldTemp = nil
        aboveSince = nil
        fallingSince = nil
    }

    /// Something else set the fans (the 95 °C override maxed them): continue ramping
    /// from there rather than from a stale value.
    public mutating func syncApplied(fraction: Float) {
        isRunning = true
        lastFraction = min(max(fraction, 0), 1)
    }

    /// One control step.
    /// - temp: peak CPU/GPU temperature (°C).
    /// - dt: seconds since the previous step.
    /// - now: monotonic seconds, for the engage delay.
    /// - minFraction: the fan's minimum RPM over its maximum.
    public mutating func update(temp: Float, dt: TimeInterval, now: TimeInterval,
                                minFraction: Float) -> Decision {
        guard let firstTemp = curve.points.first?.temp, temp.isFinite else { return .none }
        let floorFraction = min(max(minFraction, 0), 1)
        let held = holdTemperature(temp, now: now)

        var justEngaged = false
        if !isRunning {
            guard temp >= firstTemp else {
                aboveSince = nil
                return .none
            }
            let since = aboveSince ?? now
            aboveSince = since
            guard now - since >= TimeInterval(curve.engageDelaySec) else { return .none }
            isRunning = true
            lastFraction = floorFraction
            justEngaged = true
        } else if temp < firstTemp - curve.releaseMarginC {
            isRunning = false
            lastFraction = 0
            heldTemp = nil
            aboveSince = nil
            fallingSince = nil
            return .release
        }

        let target = curve.fraction(at: held, minFraction: floorFraction)
        let step = Float(min(max(dt, 0.01), Self.maxStepSeconds))

        var next = target
        if next > lastFraction {
            if held < CustomFanCurve.urgentTemp {
                next = min(next, lastFraction + curve.rampUpPerSec * step)
            }
        } else if next < lastFraction {
            next = max(next, lastFraction - curve.rampDownPerSec * step)
        }
        next = min(max(next, floorFraction), 1)

        let atEndpoint = next <= floorFraction + 0.0001 || next >= 1 - 0.0001
        let changed = abs(next - lastFraction) >= Self.minStep || (next != lastFraction && atEndpoint)
        if justEngaged || changed {
            lastFraction = next
            return .set(fraction: next)
        }
        return .none
    }

    // MARK: - Hysteresis

    /// The temperature the curve is read at: up at once; down only after the reading has
    /// stayed below the dead band for the cool-down delay, then to the band's edge.
    private mutating func holdTemperature(_ temp: Float, now: TimeInterval) -> Float {
        let band = max(curve.hysteresisC, 0)
        guard let current = heldTemp else {
            heldTemp = temp
            fallingSince = nil
            return temp
        }
        if temp >= current {
            heldTemp = temp
            fallingSince = nil
        } else if current - temp > band {
            let since = fallingSince ?? now
            fallingSince = since
            if now - since >= TimeInterval(curve.coolDownDelaySec) {
                heldTemp = temp + band
                fallingSince = nil
            }
        } else {
            fallingSince = nil
        }
        return heldTemp ?? temp
    }
}
