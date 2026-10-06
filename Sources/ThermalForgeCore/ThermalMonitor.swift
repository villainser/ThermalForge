//
//  ThermalMonitor.swift
//  ThermalForge
//
//  Polling engine that reads temperatures and applies fan profiles.
//
//  Timing is wall-clock, not tick-counting. The poll rate changes while the app runs
//  (see PollCadence), so everything that used to be "N ticks" is now seconds: the
//  sustained trigger, the ramp governors (rate x real elapsed time), the monitor
//  cadence (process capture + anomaly detection, about every 2 s) and the UI cadence
//  (about every 0.5 s, but never faster than the poll). A profile therefore ramps and
//  triggers at the same real-world speed at a 1 s poll as it did at 100 ms.
//
//  What a tick reads depends on who is looking. With nothing showing live readings
//  (the menu is closed) it reads only the CPU/GPU sensors; the full status, with fans
//  and the display-only sensors, is built only when something wants it.
//
//  The 95 C safety override is evaluated on every tick, before any profile logic and
//  for every profile including custom curves, and nothing here can postpone it.
//

import Darwin
import Foundation

// MARK: - Fan Commands

public enum FanCommand: Equatable {
    case setMax
    case setRPM(Float)
    case setFan(index: Int, rpm: Float)
    case resetAuto

    /// A hold keeps fans at a manual setting (so an unsupervised one-shot could
    /// be reverted by the watchdog); resetAuto hands control back and isn't held.
    public var isHold: Bool {
        switch self {
        case .setMax, .setRPM, .setFan: return true
        case .resetAuto: return false
        }
    }

    /// Per-fan commands need the 0.1.5 `setfan` socket verb; older daemons
    /// reject them, so the router must version-gate and fall back to direct SMC.
    public var isPerFan: Bool {
        if case .setFan = self { return true }
        return false
    }
}

// MARK: - Monitor State

public enum MonitorState: Equatable {
    case idle
    case active(profileName: String)
    case safetyOverride
}

// MARK: - Thermal Monitor

public final class ThermalMonitor {
    private let fanControl: FanControl
    private var timer: DispatchSourceTimer?
    // .utility: the tier that actually earns timer coalescing and CPU throttling when
    // the machine is busy with something else. Fan COMMANDS are not sent from here;
    // they go through the command pump at its own priority.
    private let queue = DispatchQueue(label: "com.thermalforge.monitor", qos: .utility)
    private let clock: () -> TimeInterval

    public private(set) var activeProfile: FanProfile
    public private(set) var state: MonitorState = .idle
    public private(set) var latestStatus: ThermalStatus?

    // MARK: - Timing

    /// Monitor cadence: process capture + anomaly detection about every 2 seconds.
    private static let monitorInterval: TimeInterval = 2.0
    /// UI cadence: the full status is built about every 500 ms, never faster than polling.
    private static let uiInterval: TimeInterval = 0.5
    /// Timers fire a little early or late (leeway); don't let that skip a cadence.
    private static let timingSlack: TimeInterval = 0.05
    /// Longest elapsed time one tick may account for. After a sleep the clock jumps;
    /// ramps and triggers shouldn't leap with it.
    private static let maxTickDelta: TimeInterval = 6.0
    /// Smart's rate-of-change history is sampled this often.
    private static let smartSampleInterval: TimeInterval = 2.0

    /// The fast poll rate, from `start(interval:)`.
    private var activeInterval: TimeInterval = 1.0
    /// Whether the rate relaxes when nothing is happening (see PollCadence).
    private var adaptive = true
    private var cadence = PollCadence()
    /// The interval the timer is currently set to.
    private(set) var currentInterval: TimeInterval = 1.0

    private var lastTickTime: TimeInterval?
    private var lastMonitorTick: TimeInterval = -.infinity
    private var lastUIUpdate: TimeInterval = -.infinity

    // MARK: - Fan State

    private var lastAppliedRPMPercent: Float = 0
    private var fansCurrentlyRunning = false
    /// When the peak first reached the profile's start temperature without dipping back
    /// below it since; nil while it's below. The sustained trigger measures from here.
    private var sustainedSince: TimeInterval?

    // MARK: - Smart Profile State

    private var tempHistory: [(t: TimeInterval, temp: Float)] = []

    // MARK: - Custom Curve State

    /// Set while a custom curve is the active profile; the built-in logic is bypassed.
    private var customController: CustomCurveController?

    // MARK: - Anomaly Detection

    /// Peak temperature at each monitor tick, for the last ~30 seconds.
    private var anomalySamples: [(t: TimeInterval, temp: Float)] = []
    /// Two samples count as "consecutive" for the instant-spike check up to this far apart.
    private static let instantMaxGap: TimeInterval = 6.0
    private static let anomalyWindow: TimeInterval = 30.0
    private var isCalibrating = false

    // MARK: - Process Buffer

    /// Rolling buffer — captures what was running BEFORE a spike.
    /// 15 snapshots, about 2 seconds apart (as far apart as the poll allows).
    private var processBuffer: [(t: TimeInterval, timestamp: String, processes: String)] = []
    private let isoFormatter = ISO8601DateFormatter()
    /// Reused between captures: the process table is a few hundred KB, and allocating
    /// it afresh every cycle was most of what a capture cost.
    private var processTable: [kinfo_proc] = []

    /// Call this to suppress anomaly logging during calibration
    public func setCalibrating(_ value: Bool) {
        queue.async { self.isCalibrating = value }
    }
    private var calibration: CalibrationData? = {
        guard let data = CalibrationData.load() else { return nil }
        if let error = data.validationError {
            TFLogger.shared.error("Calibration data rejected: \(error)")
            return nil
        }
        return data
    }()

    // MARK: - Callbacks

    /// Called with the FULL status (fans and every live sensor) about every 500 ms, and
    /// only while `fullStatusWanted` is true.
    public var onUpdate: ((ThermalStatus, FanProfile, MonitorState) -> Void)?
    /// Called when the headline numbers change: the peak CPU/GPU temperature rounded to
    /// whole degrees, the profile, the state. Lighter than `onUpdate`, and unlike it,
    /// fires whether or not anything is showing the full status.
    public var onPeakUpdate: ((Float, FanProfile, MonitorState) -> Void)?
    /// Called when a fan command needs to be executed (may require privilege)
    public var onFanCommand: ((FanCommand) throws -> Void)?

    private struct Summary: Equatable {
        let peak: Float
        let state: MonitorState
        let profileID: String
    }
    private var lastSummary: Summary?

    /// Where log lines go. nil means TFLogger. Tests set it so a simulated tick never
    /// writes into the real log.
    var logSink: ((String) -> Void)?

    private enum LogKind { case fan, safety, info, error }

    private func log(_ kind: LogKind, _ message: String) {
        if let logSink {
            logSink(message)
            return
        }
        switch kind {
        case .fan: TFLogger.shared.fan(message)
        case .safety: TFLogger.shared.safety(message)
        case .info: TFLogger.shared.info(message)
        case .error: TFLogger.shared.error(message)
        }
    }

    // MARK: - Who Wants the Full Status

    private let wantsLock = NSLock()
    private var wantsFullStatus = true

    /// Whether anything is showing live readings. True by default (the CLI `watch`
    /// prints every update). The menu bar app sets it false while the menu is closed,
    /// which cuts each poll to the CPU/GPU sensors and lets the poll rate relax; it
    /// sets it true, then calls `refreshNow()`, when the menu opens.
    public var fullStatusWanted: Bool {
        get {
            wantsLock.lock()
            defer { wantsLock.unlock() }
            return wantsFullStatus
        }
        set {
            wantsLock.lock()
            wantsFullStatus = newValue
            wantsLock.unlock()
        }
    }

    public init(fanControl: FanControl, profile: FanProfile = .silent,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.fanControl = fanControl
        self.activeProfile = profile
        self.clock = clock
    }

    // MARK: - Lifecycle

    /// Start polling.
    /// - interval: the fast rate (seconds). With `adaptive` it is the rate used while
    ///   anything is happening; without it, the only rate.
    /// - adaptive: relax to slower rates while the machine is quiet (see PollCadence).
    public func start(interval: TimeInterval = 1.0, adaptive: Bool = true) {
        stop()

        queue.sync {
            activeInterval = max(interval, 0.05)
            self.adaptive = adaptive
            currentInterval = activeInterval
            var tuning = PollCadence.Tuning()
            tuning.active = activeInterval
            tuning.steady = max(tuning.steady, activeInterval)
            tuning.handsOffIdle = max(tuning.handsOffIdle, activeInterval)
            cadence = PollCadence(tuning: tuning)
            lastTickTime = nil
            lastUIUpdate = -.infinity
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        schedule(timer, interval: activeInterval, firstFireNow: true)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Poll once, soon, off the regular schedule. The menu bar app calls this when the
    /// menu opens, so a slow idle poll never leaves it showing "Reading sensors…".
    public func refreshNow() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastUIUpdate = -.infinity
            self.tick(now: self.clock())
        }
    }

    /// Blocks until work already queued on the monitor's queue (a profile switch,
    /// `refreshNow`) has run. For tests, which drive `tick(now:)` themselves and need
    /// those to have landed first.
    func drainQueue() {
        queue.sync {}
    }

    /// (Re)schedule the repeating timer. Leeway lets the OS coalesce wakeups: tight at
    /// the fast rate, where timing matters, looser at the slow ones.
    private func schedule(_ timer: DispatchSourceTimer, interval: TimeInterval, firstFireNow: Bool = false) {
        let leewayFraction = interval <= activeInterval ? 0.1 : 0.2
        let leewayMs = max(1, Int(interval * leewayFraction * 1000))
        timer.schedule(deadline: firstFireNow ? .now() : .now() + interval,
                       repeating: interval,
                       leeway: .milliseconds(leewayMs))
    }

    /// Update the active profile.
    public func switchProfile(_ profile: FanProfile) {
        queue.async { [self] in
            resetControlState(for: profile)
            customController = nil

            if profile.id == "smart" {
                // Reset Smart state and reload calibration data
                tempHistory.removeAll()
                let loaded = CalibrationData.load()
                if let error = loaded?.validationError {
                    log(.error, "Calibration data rejected on reload: \(error)")
                    calibration = nil
                } else {
                    calibration = loaded
                }
            }

            state = .idle
        }
    }

    /// Make a custom curve the active profile.
    /// - preservingState: an edit to the curve that is already running: keep its speed
    ///   and engaged/released state so the fans don't glitch while the curve changes.
    public func switchToCustom(_ curve: CustomFanCurve, preservingState: Bool = false) {
        queue.async { [self] in
            let profile = FanProfile(custom: curve)
            if preservingState, var controller = customController {
                controller.replaceCurve(curve)
                customController = controller
                activeProfile = profile
                lastSummary = nil
                return
            }
            resetControlState(for: profile)
            customController = CustomCurveController(curve: curve)
            state = .idle
        }
    }

    private func resetControlState(for profile: FanProfile) {
        activeProfile = profile
        lastAppliedRPMPercent = 0
        fansCurrentlyRunning = false
        sustainedSince = nil
        lastUIUpdate = -.infinity
        lastSummary = nil
        cadence.reset()
    }

    // MARK: - Polling

    private func tick() {
        tick(now: clock())
    }

    /// One poll. `now` is monotonic seconds; tests pass their own.
    func tick(now: TimeInterval) {
        let dt: TimeInterval
        if let last = lastTickTime {
            dt = min(max(now - last, 0.01), Self.maxTickDelta)
        } else {
            dt = currentInterval
        }
        lastTickTime = now

        // Read only what is wanted. The full status (fans + every live sensor) when
        // something is showing it and it's due; otherwise just the CPU/GPU sensors. The
        // control peak comes from the full status when we built one, so no sensor is
        // ever read twice in a tick.
        let uiDue = fullStatusWanted && now - lastUIUpdate >= Self.uiInterval - Self.timingSlack
        var status: ThermalStatus?
        var peak: Float = 0
        var gotReading = false
        if uiDue, let full = try? fanControl.status() {
            peak = full.safetyPeakTemp
            if peak > 0 {
                status = full
                latestStatus = full
                gotReading = true
            }
        }
        if !gotReading, let temps = fanControl.controlTemps() {
            peak = max(temps.cpu, temps.gpu)
            gotReading = true
        }
        guard gotReading else {
            // No usable CPU/GPU reading: nothing to act on, and no reason to slow down.
            cadence.noteFailure(now: now)
            setInterval(activeInterval)
            return
        }
        if status != nil { lastUIUpdate = now }

        // Monitor cadence: process capture + anomaly detection (about every 2 seconds)
        if now - lastMonitorTick >= Self.monitorInterval - Self.timingSlack {
            lastMonitorTick = now
            monitorTick(now: now, maxTemp: peak, status: status)
        }

        // Safety override: any CPU/GPU sensor at or above 95°C. Evaluated before any
        // profile logic runs and for every profile; a custom curve can't outrank it.
        if peak >= FanProfile.safetyTempThreshold {
            if state != .safetyOverride {
                applyCommand(.setMax)
                state = .safetyOverride
                fansCurrentlyRunning = true
                lastAppliedRPMPercent = 1.0
                customController?.syncApplied(fraction: 1.0)
                log(.safety, "Override triggered: \(String(format: "%.1f", peak))°C — fans maxed")
            }
            publish(status: status, peak: peak)
            applyCadence(now: now, peak: peak, fanChanged: true)
            return
        }

        // Clear safety override with hysteresis
        if state == .safetyOverride
            && peak < FanProfile.safetyTempThreshold - FanProfile.hysteresisDegrees
        {
            state = .idle
        }

        // Sustained trigger: how long the peak has been at or above the start threshold.
        // Per-profile duration, measured in real seconds.
        let startThreshold = activeProfile.curve.startTemp
        if peak >= startThreshold {
            if sustainedSince == nil { sustainedSince = now }
        } else {
            sustainedSince = nil
        }

        // Profile-specific logic. Fan min/max are firmware constants (kept after the
        // first read), so they aren't re-read here every tick.
        let appliedBefore = lastAppliedRPMPercent
        let runningBefore = fansCurrentlyRunning
        let limits = fanControl.primaryFanLimits()
        if customController != nil {
            tickCustom(peakTemp: peak, limits: limits, now: now, dt: dt)
        } else if activeProfile.id == "smart" {
            tickSmart(peakTemp: peak, limits: limits, now: now, dt: dt)
        } else {
            tickCurve(peakTemp: peak, limits: limits, now: now, dt: dt)
        }
        // Did the applied fan speed move this tick? That is the signal for polling fast
        // (ramping) versus relaxing (holding steady).
        let fanChanged = lastAppliedRPMPercent != appliedBefore || fansCurrentlyRunning != runningBefore

        publish(status: status, peak: peak)
        applyCadence(now: now, peak: peak, fanChanged: fanChanged)
    }

    /// Hand results to the callbacks. The full status goes out only when one was built;
    /// the headline numbers go out only when they changed.
    private func publish(status: ThermalStatus?, peak: Float) {
        if let status { onUpdate?(status, activeProfile, state) }

        let rounded = peak.rounded()
        let summary = Summary(peak: rounded, state: state, profileID: activeProfile.id)
        if summary != lastSummary {
            lastSummary = summary
            onPeakUpdate?(rounded, activeProfile, state)
        }
    }

    // MARK: - Adaptive Cadence

    private func applyCadence(now: TimeInterval, peak: Float, fanChanged: Bool) {
        guard adaptive else { return }
        let controlsFans = !activeProfile.curve.handsOff
        let input = PollCadence.Input(
            now: now,
            peak: peak,
            controlsFans: controlsFans,
            engaging: controlsFans && !fansCurrentlyRunning && sustainedSince != nil,
            fanChanged: fanChanged,
            safetyOverride: state == .safetyOverride,
            uiVisible: fullStatusWanted
        )
        setInterval(max(cadence.next(input), activeInterval))
    }

    /// Change the poll interval, rescheduling the timer only on a real change.
    private func setInterval(_ interval: TimeInterval) {
        guard abs(interval - currentInterval) > 0.0005 else { return }
        currentInterval = interval
        if let timer { schedule(timer, interval: interval) }
    }

    // MARK: - Monitor Cadence (about every 2 seconds)

    /// Heavy operations: process capture + anomaly detection.
    /// Runs about every 2 seconds (no faster than the poll) to keep sysctl overhead low.
    private func monitorTick(now: TimeInterval, maxTemp: Float, status: ThermalStatus?) {
        // Rolling process buffer — always capturing, like a security camera
        let currentProcs = captureTopProcesses()
        let ts = isoFormatter.string(from: Date())
        processBuffer.append((t: now, timestamp: ts, processes: currentProcs))
        if processBuffer.count > 15 { processBuffer.removeFirst() }

        // Anomaly detection: two tiers
        // Tier 1: instant spike — >5°C between consecutive readings (about 2 seconds)
        // Tier 2: sustained change — >10°C over 30 seconds
        if !isCalibrating {
            var spikeDetected = false

            // Tier 1: check against previous reading
            if let prev = anomalySamples.last {
                let elapsed = now - prev.t
                let instantDelta = maxTemp - prev.temp
                if elapsed <= Self.instantMaxGap && abs(instantDelta) > 5 {
                    let direction = instantDelta > 0 ? "spike" : "drop"
                    let fan0 = (status ?? (try? fanControl.status()))?.fans.first
                    log(.info,
                        "Instant \(direction): \(String(format: "%.1f", prev.temp))→\(String(format: "%.1f", maxTemp))°C " +
                        "(\(String(format: "%+.1f", instantDelta))°C in \(Int(elapsed.rounded()))s) | " +
                        "Fan0: \(fan0?.actualRPM ?? 0) RPM (\(fan0?.mode ?? "?")) | " +
                        "Profile: \(activeProfile.name)"
                    )
                    spikeDetected = true
                }
            }

            // Tier 2: check over the 30-second window
            if let oldest = anomalySamples.first, now - oldest.t >= Self.anomalyWindow - 2 {
                let sustainedDelta = maxTemp - oldest.temp
                if abs(sustainedDelta) > 10 {
                    let direction = sustainedDelta > 0 ? "spike" : "drop"
                    let fan0 = (status ?? (try? fanControl.status()))?.fans.first
                    log(.info,
                        "Sustained \(direction): \(String(format: "%.1f", oldest.temp))→\(String(format: "%.1f", maxTemp))°C " +
                        "(\(String(format: "%+.1f", sustainedDelta))°C in \(Int((now - oldest.t).rounded()))s) | " +
                        "Fan0: \(fan0?.actualRPM ?? 0) RPM (\(fan0?.mode ?? "?")) | " +
                        "Profile: \(activeProfile.name)"
                    )
                    spikeDetected = true
                    anomalySamples.removeAll()
                }
            }

            // Dump the rolling buffer on any spike — shows what was running BEFORE
            if spikeDetected {
                let span = Int((now - (processBuffer.first?.t ?? now)).rounded())
                log(.info, "Pre-spike process history (last \(span)s):")
                for entry in processBuffer {
                    log(.info, "  \(entry.timestamp): \(entry.processes)")
                }
            }
        }

        anomalySamples.append((t: now, temp: maxTemp))
        while let first = anomalySamples.first, now - first.t > Self.anomalyWindow + 2 {
            anomalySamples.removeFirst()
        }
    }

    // MARK: - Smart Profile

    /// Target temperature ceiling — keep below this to avoid any throttling
    private static let smartCeiling: Float = 85.0
    /// Smart starts earlier than other profiles to get ahead of rising temps
    private static let smartFloor: Float = 53.0

    /// All profiles share the same off threshold — 50°C matches Apple's observed stop range
    private static let smartStopTemp: Float = 50.0

    private func tickSmart(peakTemp: Float, limits: (minRPM: Float, maxRPM: Float),
                           now: TimeInterval, dt: TimeInterval) {
        // Sample temperature history about every 2 seconds for a stable rate-of-change
        if now - (tempHistory.last?.t ?? -.infinity) >= Self.smartSampleInterval - Self.timingSlack {
            tempHistory.append((t: now, temp: peakTemp))
            if tempHistory.count > 4 { tempHistory.removeFirst() }
        }

        let maxRPM = limits.maxRPM
        let minRPM = limits.minRPM
        let minPct = minRPM / maxRPM

        // Below stop threshold and fans running: turn off (with hysteresis)
        if peakTemp < Self.smartStopTemp && fansCurrentlyRunning && rateOfChange() <= 0 {
            applyCommand(.resetAuto)
            lastAppliedRPMPercent = 0
            fansCurrentlyRunning = false
            state = .idle
            log(.fan, "Smart fans off: \(String(format: "%.1f", peakTemp))°C below \(Int(Self.smartStopTemp))°C")
            return
        }

        // Below floor and fans not running: stay off
        if peakTemp < Self.smartFloor && !fansCurrentlyRunning {
            return
        }

        // In hysteresis band (50-53°C): maintain current state
        if peakTemp >= Self.smartStopTemp && peakTemp < Self.smartFloor && !fansCurrentlyRunning {
            return
        }

        // Sustained trigger: per-profile duration
        let sustained = sustainedElapsed(now)
        let sustainedNeeded = TimeInterval(activeProfile.curve.sustainedTriggerSec)
        if !fansCurrentlyRunning && sustained < sustainedNeeded {
            if sustained == 0 {
                log(.fan, "Sustained trigger: \(String(format: "%.1f", peakTemp))°C — waiting (\(Int(sustainedNeeded))s) [Smart]")
            }
            return
        }

        let rate = rateOfChange()
        var targetPct: Float

        if let cal = calibration, let calPct = cal.fanPercentForTemp(peakTemp) {
            // Calibrated: use machine-specific temp→fan lookup
            targetPct = calPct

            if rate > 0 {
                // Rising: boost proportionally to rate and proximity to ceiling
                let urgency = min(max((peakTemp - Self.smartFloor) / (Self.smartCeiling - Self.smartFloor), 0), 1)
                targetPct = min(targetPct + rate * 0.15 * (1 + urgency), 1.0)
            }
        } else {
            // Uncalibrated: S-curve (matches profile curveShape)
            let range = Self.smartCeiling - Self.smartFloor
            let position = min(max((peakTemp - Self.smartFloor) / range, 0), 1)
            targetPct = position * position * (3 - 2 * position)

            if rate > 0 {
                targetPct = min(targetPct + rate * 0.2, 1.0)
            }
        }

        if peakTemp > Self.smartCeiling {
            targetPct = 1.0
        }

        // Clamp to valid range, enforce minimum RPM
        targetPct = min(max(targetPct, 0), 1.0)
        if targetPct > 0 && targetPct < minPct {
            targetPct = minPct
        }

        // Ramp governors — per-profile rates per second, times the real time elapsed
        let rampUp = activeProfile.curve.rampUpPerSec * Float(dt)
        let rampDown = activeProfile.curve.rampDownPerSec * Float(dt)

        if targetPct > lastAppliedRPMPercent {
            targetPct = min(targetPct, lastAppliedRPMPercent + rampUp)
        } else if targetPct < lastAppliedRPMPercent {
            targetPct = max(targetPct, lastAppliedRPMPercent - rampDown)
        }

        // Apply if changed meaningfully
        if abs(targetPct - lastAppliedRPMPercent) > 0.002 {
            let targetRPM = max(maxRPM * targetPct, minRPM)
            applyCommand(.setRPM(targetRPM))

            if !fansCurrentlyRunning {
                log(.fan, "Smart fans on: \(Int(targetRPM)) RPM at \(String(format: "%.1f", peakTemp))°C")
            }

            lastAppliedRPMPercent = targetPct
            fansCurrentlyRunning = true
            state = .active(profileName: "Smart")
        } else if fansCurrentlyRunning {
            state = .active(profileName: "Smart")
        }
    }

    /// Temperature rate of change in °C per second (smoothed over history).
    /// History is sampled about every 2 seconds, so this covers about 6 seconds.
    private func rateOfChange() -> Float {
        guard let oldest = tempHistory.first, let newest = tempHistory.last else { return 0 }
        let seconds = Float(newest.t - oldest.t)
        guard seconds > 0 else { return 0 }
        return (newest.temp - oldest.temp) / seconds
    }

    // MARK: - Curve-Based Profiles

    private func tickCurve(peakTemp: Float, limits: (minRPM: Float, maxRPM: Float),
                           now: TimeInterval, dt: TimeInterval) {
        let curve = activeProfile.curve
        let maxRPM = limits.maxRPM
        let minRPM = limits.minRPM

        // Hands-off profiles (Silent): don't control fans, just monitor
        if curve.handsOff {
            if fansCurrentlyRunning {
                applyCommand(.resetAuto)
                fansCurrentlyRunning = false
                lastAppliedRPMPercent = 0
                state = .idle
            }
            return
        }

        // Get target from curve (now applies curve shape: easeIn, linear, easeOut, sCurve)
        guard let rawTarget = curve.targetPercent(at: peakTemp, fansCurrentlyRunning: fansCurrentlyRunning) else {
            // Curve says fans should be off
            if fansCurrentlyRunning {
                applyCommand(.resetAuto)
                fansCurrentlyRunning = false
                lastAppliedRPMPercent = 0
                state = .idle
                log(.fan, "Fans off: \(String(format: "%.1f", peakTemp))°C below \(Int(curve.stopTemp))°C [\(activeProfile.name)]")
            }
            return
        }

        // Sustained trigger: per-profile duration, in real seconds.
        let sustained = sustainedElapsed(now)
        let sustainedNeeded = TimeInterval(curve.sustainedTriggerSec)
        if !fansCurrentlyRunning && sustained < sustainedNeeded {
            if sustained == 0 {
                log(.fan, "Sustained trigger: \(String(format: "%.1f", peakTemp))°C — waiting (\(Int(sustainedNeeded))s) [\(activeProfile.name)]")
            }
            return
        }

        // 0.001 signals "keep at minimum" (hysteresis band)
        var targetPct = rawTarget <= 0.001 ? minRPM / maxRPM : rawTarget

        // Clamp to valid range
        targetPct = min(max(targetPct, minRPM / maxRPM), curve.maxRPMPercent)

        // Ramp governors — per-profile rates per second, times the real time elapsed
        let rampUp = curve.rampUpPerSec * Float(dt)
        let rampDown = curve.rampDownPerSec * Float(dt)

        if targetPct > lastAppliedRPMPercent {
            if !curve.instantEngage {
                // Governed ramp-up
                targetPct = min(targetPct, lastAppliedRPMPercent + rampUp)
            }
            // instantEngage: skip governor, jump directly to target
        } else if targetPct < lastAppliedRPMPercent {
            // Ramp-down governor always applies (even for instantEngage profiles)
            targetPct = max(targetPct, lastAppliedRPMPercent - rampDown)
        }

        // Apply if changed meaningfully
        if abs(targetPct - lastAppliedRPMPercent) > 0.002 {
            let targetRPM = max(maxRPM * targetPct, minRPM)
            applyCommand(.setRPM(targetRPM))

            if !fansCurrentlyRunning {
                log(.fan, "Fans on: \(Int(targetRPM)) RPM at \(String(format: "%.1f", peakTemp))°C [\(activeProfile.name)]")
            }

            lastAppliedRPMPercent = targetPct
            fansCurrentlyRunning = true
            state = .active(profileName: activeProfile.name)
        } else if fansCurrentlyRunning {
            state = .active(profileName: activeProfile.name)
        }
    }

    // MARK: - Custom Curve

    private func tickCustom(peakTemp: Float, limits: (minRPM: Float, maxRPM: Float),
                            now: TimeInterval, dt: TimeInterval) {
        guard var controller = customController else { return }
        let minFraction = limits.minRPM / limits.maxRPM
        let decision = controller.update(temp: peakTemp, dt: dt, now: now, minFraction: minFraction)
        customController = controller

        switch decision {
        case .none:
            if fansCurrentlyRunning { state = .active(profileName: activeProfile.name) }

        case .release:
            applyCommand(.resetAuto)
            fansCurrentlyRunning = false
            lastAppliedRPMPercent = 0
            state = .idle
            log(.fan, "Fans off: \(String(format: "%.1f", peakTemp))°C below curve start [\(activeProfile.name)]")

        case .set(let fraction):
            // Never outside what the hardware reports it can do.
            let rpm = min(max(limits.maxRPM * fraction, limits.minRPM), limits.maxRPM)
            applyCommand(.setRPM(rpm))
            if !fansCurrentlyRunning {
                log(.fan, "Fans on: \(Int(rpm)) RPM at \(String(format: "%.1f", peakTemp))°C [\(activeProfile.name)]")
            }
            lastAppliedRPMPercent = fraction
            fansCurrentlyRunning = true
            state = .active(profileName: activeProfile.name)
        }
    }

    // MARK: - Process Capture

    /// Capture top 5 processes by CPU for anomaly logging
    private func captureTopProcesses() -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return "unavailable" }

        // A little headroom for processes that start between the two calls, and the
        // table is kept for next time instead of being allocated again.
        let stride = MemoryLayout<kinfo_proc>.stride
        let needed = size / stride + 16
        if processTable.count < needed {
            processTable = [kinfo_proc](repeating: kinfo_proc(), count: needed)
        }
        size = processTable.count * stride
        guard sysctl(&mib, 4, &processTable, &size, nil, 0) == 0 else { return "unavailable" }

        let actualCount = size / stride
        var results: [(name: String, cpu: Double)] = []

        for i in 0..<actualCount {
            let proc = processTable[i]
            let pid = proc.kp_proc.p_pid
            guard pid > 0 else { continue }

            let name = withUnsafePointer(to: proc.kp_proc.p_comm) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            }

            guard !name.isEmpty, name != "kernel_task" else { continue }
            let cpuPct = Double(proc.kp_proc.p_pctcpu) / 100.0
            if cpuPct > 0.1 {
                results.append((name, cpuPct))
            }
        }

        let top5 = results.sorted { $0.cpu > $1.cpu }.prefix(5)
        if top5.isEmpty { return "idle" }
        return top5.map { "\($0.name)(\(String(format: "%.1f", $0.cpu))%)" }.joined(separator: ", ")
    }

    // MARK: - Helpers

    /// Seconds the peak has stayed at or above the profile's start temperature; 0 on the
    /// first tick it crosses, and while it's below.
    private func sustainedElapsed(_ now: TimeInterval) -> TimeInterval {
        guard let since = sustainedSince else { return 0 }
        return now - since
    }

    private func applyCommand(_ command: FanCommand) {
        do {
            try onFanCommand?(command)
        } catch {
            log(.error, "Fan command failed: \(command) — \(error)")
        }
    }

}
