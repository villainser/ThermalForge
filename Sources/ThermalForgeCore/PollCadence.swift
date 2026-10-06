//
//  PollCadence.swift
//  ThermalForge
//
//  How often the monitor should read the sensors. Pure decision logic: no timers, no
//  SMC, the clock is an input. ThermalMonitor feeds it what happened this tick and
//  reschedules its timer to whatever it returns.
//
//  Three rates, matching what each situation can tolerate:
//    active (1 s)       fans are being controlled or are about to be, or anything
//                       suggests the machine is heating up
//    steady (2 s)       a fan-controlling profile holding a steady speed
//    hands-off (5 s)    Silent: Apple's thermald runs the fans, so ThermalForge only
//                       watches for the menu bar readout and the 95 °C backstop
//
//  Safety comes before saving CPU. The slow rates are only ever reached after the
//  machine has been quiet for `settle` seconds, and any of these snaps back to the
//  active rate at once:
//    - the peak is at or above `safetyWatchTemp` (85 °C), or the 95 °C override is on
//    - the peak rose by `riseTrigger` (3 °C) since the previous poll; it then stays
//      active for `riseHold` seconds
//    - a fan-controlling profile is engaging, or just changed the fan speed
//    - the menu is open (a live readout shouldn't update every 5 s)
//    - a sensor read just failed
//  Hands-off only gets the 5 s rate below `handsOffRelaxCeiling` (70 °C); above that
//  it polls at the steady rate.
//

import Foundation

public struct PollCadence {
    public struct Tuning: Equatable {
        /// Fast rate. ThermalMonitor sets this from `start(interval:)`.
        public var active: TimeInterval = 1.0
        /// Fan-controlling profile, holding steady.
        public var steady: TimeInterval = 2.0
        /// Hands-off (Silent) profile, cool and quiet.
        public var handsOffIdle: TimeInterval = 5.0
        /// At or above this peak, always poll at the active rate (°C).
        public var safetyWatchTemp: Float = 85
        /// Hands-off only relaxes to `handsOffIdle` below this peak (°C).
        public var handsOffRelaxCeiling: Float = 70
        /// A rise this large between two polls forces the active rate (°C).
        public var riseTrigger: Float = 3
        /// How long a rise keeps the active rate (seconds).
        public var riseHold: TimeInterval = 10
        /// Quiet time required before any slow rate is used (seconds).
        public var settle: TimeInterval = 10

        public init() {}
    }

    /// What happened on the tick that just ran.
    public struct Input {
        public var now: TimeInterval
        /// Peak CPU/GPU temperature (°C).
        public var peak: Float
        /// The active profile drives the fans (anything but hands-off).
        public var controlsFans: Bool
        /// A fan-controlling profile is counting toward turning the fans on.
        public var engaging: Bool
        /// The applied fan speed, or whether fans are running, changed this tick.
        public var fanChanged: Bool
        /// The 95 °C safety override is active.
        public var safetyOverride: Bool
        /// Something is showing live readings (the menu is open).
        public var uiVisible: Bool

        public init(now: TimeInterval, peak: Float, controlsFans: Bool, engaging: Bool,
                    fanChanged: Bool, safetyOverride: Bool, uiVisible: Bool) {
            self.now = now
            self.peak = peak
            self.controlsFans = controlsFans
            self.engaging = engaging
            self.fanChanged = fanChanged
            self.safetyOverride = safetyOverride
            self.uiVisible = uiVisible
        }
    }

    public private(set) var tuning: Tuning

    private var lastPeak: Float?
    private var lastBusy: TimeInterval?
    private var riseUntil: TimeInterval = -.infinity

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// Back to the active rate: a profile switch, or a fresh start.
    public mutating func reset() {
        lastPeak = nil
        lastBusy = nil
        riseUntil = -.infinity
    }

    /// A sensor read failed: stay (or go back to) active until things have been
    /// quiet for `settle` again.
    public mutating func noteFailure(now: TimeInterval) {
        lastBusy = now
    }

    /// The interval to wait before the next poll.
    public mutating func next(_ input: Input) -> TimeInterval {
        defer { lastPeak = input.peak }

        if let last = lastPeak, input.peak - last >= tuning.riseTrigger {
            riseUntil = input.now + tuning.riseHold
        }

        let busy = input.safetyOverride
            || input.peak >= tuning.safetyWatchTemp
            || input.fanChanged
            || input.engaging
            || input.now < riseUntil

        // The first call counts as busy: a fresh start polls fast until it has seen
        // the machine quiet for `settle` seconds.
        if busy || lastBusy == nil { lastBusy = input.now }

        let quietFor = input.now - (lastBusy ?? input.now)

        var interval: TimeInterval
        if quietFor < tuning.settle {
            interval = tuning.active
        } else if input.controlsFans {
            interval = tuning.steady
        } else if input.peak < tuning.handsOffRelaxCeiling {
            interval = tuning.handsOffIdle
        } else {
            interval = tuning.steady
        }

        if input.uiVisible { interval = min(interval, tuning.active) }
        return interval
    }
}
