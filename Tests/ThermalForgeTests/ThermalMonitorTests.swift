//
//  ThermalMonitorTests.swift
//  ThermalForge
//
//  The monitor's behaviour, driven tick by tick on a fake SMC with a fake clock:
//   - the 95 °C safety override, for every profile including custom curves
//   - the built-in profiles (Balanced, Performance, Max, Smart, Silent) still trigger,
//     ramp and release the way they did, whatever the poll rate
//   - the adaptive poll rate as the monitor applies it
//   - what a poll reads when the menu is closed, and when it is open
//   - time-based anomaly logging
//

import Foundation
import Testing

@testable import ThermalForgeCore

/// A monitor wired to a fake SMC, recording what it commands, logs and publishes.
private final class Rig {
    let smc: FakeSMC
    let fan: FanControl
    let monitor: ThermalMonitor
    var now: TimeInterval = 1000
    let start: TimeInterval = 1000

    var commands: [(at: TimeInterval, command: FanCommand)] = []
    var logs: [String] = []
    var fullUpdates = 0
    var summaries: [(peak: Float, state: MonitorState)] = []

    init(profile: FanProfile, menuOpen: Bool = true, cpu: Float = 40) {
        smc = FakeSMC.standard(cpu: cpu, gpu: 30)
        fan = FanControl(smc: smc)
        fan.logSink = { _ in }
        monitor = ThermalMonitor(fanControl: fan, profile: profile)
        monitor.fullStatusWanted = menuOpen
        monitor.logSink = { [unowned self] in self.logs.append($0) }
        monitor.onFanCommand = { [unowned self] command in self.commands.append((self.now, command)) }
        monitor.onUpdate = { [unowned self] _, _, _ in self.fullUpdates += 1 }
        monitor.onPeakUpdate = { [unowned self] peak, _, state in self.summaries.append((peak, state)) }
    }

    /// One tick at the current time with the CPU at `temp` (the second CPU sensor 2 °C
    /// below it, the GPU at 30 °C, so the CPU is the peak above 32 °C).
    func tick(_ temp: Float) {
        smc.set("Tp01", float: temp)
        smc.set("Tp05", float: temp - 2)
        monitor.tick(now: now)
    }

    /// Ticks every `dt` seconds for `seconds`, starting at the current time.
    func run(_ temp: Float, seconds: Double, dt: Double) {
        let origin = now
        var i = 0
        while Double(i) * dt <= seconds {
            now = origin + Double(i) * dt
            tick(temp)
            i += 1
        }
        now = origin + seconds
    }

    var rpms: [Float] {
        commands.compactMap { entry in
            if case .setRPM(let rpm) = entry.command { return rpm }
            return nil
        }
    }

    var kinds: [FanCommand] { commands.map { $0.command } }
}

@Suite("ThermalMonitor")
struct ThermalMonitorTests {

    static let minRPM: Float = 2317
    static let maxRPM: Float = 7826

    private func rig(_ profile: FanProfile, menuOpen: Bool = true, cpu: Float = 40) -> Rig {
        Rig(profile: profile, menuOpen: menuOpen, cpu: cpu)
    }

    private func customRig(_ curve: CustomFanCurve = .example(), menuOpen: Bool = true) -> Rig {
        let r = Rig(profile: FanProfile(custom: curve), menuOpen: menuOpen)
        r.monitor.switchToCustom(curve)
        r.monitor.drainQueue()
        return r
    }

    // MARK: - 95 °C safety override

    @Test("At 95 °C every profile maxes the fans, once, with the menu open or closed")
    func overrideForEveryProfile() {
        let profiles: [(String, () -> Rig)] = [
            ("balanced", { Rig(profile: .balanced) }),
            ("performance", { Rig(profile: .performance) }),
            ("max", { Rig(profile: .max) }),
            ("smart", { Rig(profile: .smart) }),
            ("silent", { Rig(profile: .silent) }),
            ("custom", { self.customRig() }),
            ("balanced, menu closed", { Rig(profile: .balanced, menuOpen: false) }),
            ("silent, menu closed", { Rig(profile: .silent, menuOpen: false) }),
            ("custom, menu closed", { self.customRig(menuOpen: false) }),
        ]
        for (name, make) in profiles {
            let r = make()
            r.tick(96)
            #expect(r.kinds == [.setMax], "\(name): \(r.kinds)")
            #expect(r.monitor.state == .safetyOverride, "\(name)")

            // Still hot: not commanded again.
            r.now += 1
            r.tick(97)
            #expect(r.kinds == [.setMax], "\(name) repeated: \(r.kinds)")

            // Cooled below the 5 °C hysteresis: the override is cleared.
            r.now += 1
            r.tick(80)
            #expect(r.monitor.state != .safetyOverride, "\(name) after cooling")
        }
    }

    @Test("The threshold is exactly 95 °C: 94.9 does not trigger it, 95.0 does")
    func overrideBoundary() {
        let below = rig(.balanced)
        below.tick(94.9)
        #expect(!below.kinds.contains(.setMax))
        #expect(below.monitor.state != .safetyOverride)

        let at = rig(.balanced)
        at.tick(95.0)
        #expect(at.kinds == [.setMax])
        #expect(at.monitor.state == .safetyOverride)
    }

    @Test("The override reads the hottest of the CPU and GPU sensors, not just the CPU")
    func overrideFromGPU() {
        let r = rig(.balanced)
        r.smc.set("Tg05", float: 96)
        r.tick(50)
        #expect(r.kinds == [.setMax])
    }

    @Test("A custom curve cannot outrank the override, even one that asks for the minimum speed everywhere")
    func overrideBeatsACustomCurve() {
        let timid = CustomFanCurve(name: "Timid", points: [CurvePoint(temp: 45, percent: 0), CurvePoint(temp: 94, percent: 0)])
        let r = customRig(timid)
        r.tick(96)
        #expect(r.kinds == [.setMax])
        #expect(r.monitor.state == .safetyOverride)

        // Once it has cooled, the curve eases the fans down from the maximum rather than
        // dropping them to its own idea of low in one step.
        r.now += 1
        r.tick(80)
        let rpm = r.rpms.last ?? 0
        #expect(abs(rpm - Self.maxRPM * 0.97) < 2, "first step down from max: \(rpm)")
    }

    @Test("The override still works on the very first tick after a custom curve is selected")
    func overrideImmediatelyAfterSelectingACurve() {
        let r = customRig()
        r.tick(95)
        #expect(r.kinds == [.setMax])
    }

    // MARK: - Built-in profiles

    @Test("Balanced engages after its 8 s sustained trigger and ramps up at 5% per second, at any poll rate")
    func balancedAtAnyPollRate() {
        for dt in [0.1, 0.5, 1.0, 2.0] {
            let r = rig(.balanced, cpu: 75)
            r.run(75, seconds: 40, dt: dt)

            let first = (r.commands.first?.at ?? 0) - r.start
            #expect(first >= 8 && first <= 8 + dt + 0.001, "dt \(dt): first command at \(first) s")
            #expect(r.rpms.first == Self.minRPM, "dt \(dt): starts at the minimum RPM")

            // Climbs to 60% of max RPM and stays there.
            let top = r.rpms.last ?? 0
            #expect(abs(top - Self.maxRPM * 0.6) < 1, "dt \(dt): settles at \(top)")
            #expect(zip(r.rpms, r.rpms.dropFirst()).allSatisfy { $0 <= $1 }, "dt \(dt): never steps back while hot")

            // Reaches the top at about the same real time whatever the poll rate.
            let reached = ((r.commands.first { entry in
                if case .setRPM(let rpm) = entry.command { return rpm >= Self.maxRPM * 0.6 - 1 }
                return false
            })?.at ?? 0) - r.start
            #expect(reached >= 17.9 && reached <= 20.1, "dt \(dt): reached the top at \(reached) s")
        }
    }

    @Test("Performance engages after 4 s and ramps at 10% per second")
    func performance() {
        for dt in [0.5, 1.0] {
            let r = rig(.performance, cpu: 70)
            r.run(70, seconds: 30, dt: dt)
            let first = (r.commands.first?.at ?? 0) - r.start
            #expect(first >= 4 && first <= 4 + dt + 0.001, "dt \(dt): first command at \(first) s")
            #expect(abs((r.rpms.last ?? 0) - Self.maxRPM * 0.85) < 1, "dt \(dt)")
        }
    }

    @Test("Max jumps straight to 100% after its 5 s trigger, with no ramp, in one command")
    func maxJumpsToFull() {
        for dt in [0.1, 1.0, 2.0] {
            let r = rig(.max, cpu: 66)
            r.run(66, seconds: 30, dt: dt)
            let first = (r.commands.first?.at ?? 0) - r.start
            #expect(first >= 5 && first <= 5 + dt + 0.001, "dt \(dt): first command at \(first) s")
            #expect(r.kinds == [.setRPM(Self.maxRPM)], "dt \(dt): \(r.kinds)")
        }
    }

    @Test("Silent never commands the fans, however hot, until the 95 °C override")
    func silentIsHandsOff() {
        let r = rig(.silent, cpu: 85)
        r.run(85, seconds: 120, dt: 1)
        #expect(r.commands.isEmpty)
        #expect(r.monitor.state == .idle)
    }

    @Test("Smart stays off below its 53 °C floor")
    func smartBelowFloor() {
        let r = rig(.smart, cpu: 50)
        r.run(50, seconds: 60, dt: 1)
        #expect(r.commands.isEmpty)
    }

    @Test("Smart engages after its 6 s trigger, within the hardware range")
    func smartEngages() {
        let r = rig(.smart, cpu: 70)
        r.run(70, seconds: 40, dt: 1)
        let first = (r.commands.first?.at ?? 0) - r.start
        #expect(first >= 6 && first <= 7.001, "first command at \(first) s")
        #expect(!r.rpms.isEmpty)
        #expect(r.rpms.allSatisfy { $0 >= Self.minRPM && $0 <= Self.maxRPM })
    }

    @Test("A built-in profile hands the fans back below its stop temperature")
    func balancedReleases() {
        let r = rig(.balanced, cpu: 75)
        r.run(75, seconds: 30, dt: 1)
        #expect(r.monitor.state == .active(profileName: "Balanced"))
        r.now += 1
        r.tick(45)
        #expect(r.kinds.last == .resetAuto)
        #expect(r.monitor.state == .idle)
    }

    @Test("In the band between stop and start the fans ease down at the slow-down rate and hold the minimum")
    func balancedHysteresisBand() {
        let r = rig(.balanced, cpu: 75)
        r.run(75, seconds: 30, dt: 1)
        let before = r.rpms.count
        r.now += 1
        r.run(52, seconds: 25, dt: 1)
        let down = Array(r.rpms.dropFirst(before))
        #expect(!down.isEmpty)
        #expect(zip(down, down.dropFirst()).allSatisfy { $0 - $1 <= 0.025 * Self.maxRPM + 1 },
                "slow-down rate respected")
        #expect((down.last ?? 0) >= Self.minRPM && (down.last ?? 0) <= Self.minRPM + 1)
        #expect(!r.kinds.contains(.resetAuto), "not released inside the band")
    }

    // MARK: - Profile curves (the math every built-in uses, unchanged)

    @Test("Built-in curves give the same fan speed as before at known temperatures")
    func builtInCurveValues() {
        func target(_ p: FanProfile, _ t: Float, running: Bool = false) -> Float? {
            p.curve.targetPercent(at: t, fansCurrentlyRunning: running)
        }
        // Balanced: ease-in, 55 -> 70 °C, 60%
        #expect(abs((target(.balanced, 62.5) ?? -1) - 0.15) < 0.0001)
        #expect(abs((target(.balanced, 70) ?? -1) - 0.60) < 0.0001)
        #expect(abs((target(.balanced, 85) ?? -1) - 0.60) < 0.0001)
        #expect(target(.balanced, 52) == nil)
        #expect(target(.balanced, 52, running: true) == 0.001)
        #expect(target(.balanced, 50, running: true) == nil)
        // Performance: linear, 55 -> 65 °C, 85%
        #expect(abs((target(.performance, 60) ?? -1) - 0.425) < 0.0001)
        #expect(abs((target(.performance, 65) ?? -1) - 0.85) < 0.0001)
        // Max: 100% from 65 °C, instantly
        #expect(target(.max, 65) == 1.0)
        #expect(target(.max, 66) == 1.0)
        #expect(target(.max, 64.9) == nil)
        // Smart: S-curve, 53 -> 85 °C
        #expect(abs((target(.smart, 69) ?? -1) - 0.5) < 0.0001)
        #expect(target(.smart, 85) == 1.0)
        // Silent: hands off at any temperature
        for t: Float in [20, 55, 80, 94] {
            #expect(target(.silent, t) == nil)
            #expect(target(.silent, t, running: true) == nil)
        }
    }

    // MARK: - Custom curve through the monitor

    @Test("A custom curve engages, follows its points within the hardware range, and releases")
    func customEndToEnd() {
        let r = customRig()
        r.run(46, seconds: 10, dt: 1)
        #expect(r.monitor.state == .active(profileName: "My curve"))
        #expect(!r.rpms.isEmpty)

        r.run(80, seconds: 30, dt: 1)
        let rpm80 = r.rpms.last ?? 0
        #expect(abs(rpm80 - 0.875 * Self.maxRPM) < 2, "80 °C -> 87.5%: \(rpm80)")
        #expect(r.rpms.allSatisfy { $0 >= Self.minRPM && $0 <= Self.maxRPM })

        r.run(88, seconds: 5, dt: 1)
        #expect(r.rpms.last == Self.maxRPM)        // exactly the hardware maximum, never above

        r.run(30, seconds: 3, dt: 1)
        #expect(r.kinds.last == .resetAuto)
        #expect(r.monitor.state == .idle)
    }

    @Test("A custom curve ramps no faster than its limit")
    func customRampLimit() {
        let r = customRig()
        r.run(46, seconds: 5, dt: 1)
        let before = r.rpms.count
        r.run(80, seconds: 12, dt: 1)
        let climb = Array(r.rpms.dropFirst(before - 1))
        #expect(zip(climb, climb.dropFirst()).allSatisfy { $1 - $0 <= 0.08 * Self.maxRPM + 1 })
    }

    @Test("Switching from a custom curve to a built-in profile uses the built-in logic")
    func leavingACustomCurve() {
        let r = customRig()
        r.monitor.switchProfile(.balanced)
        r.monitor.drainQueue()
        r.now += 1
        r.run(75, seconds: 20, dt: 1)
        let first = (r.commands.first?.at ?? 0) - (r.start + 1)
        #expect(first >= 8 && first <= 9.001, "Balanced's 8 s trigger applies: \(first)")
    }

    // MARK: - Adaptive cadence as applied

    @Test("Silent, quiet, menu closed: the poll interval relaxes from 1 s to 5 s after 10 s, and wakes on a rise")
    func silentRelaxesAndWakes() {
        let r = rig(.silent, menuOpen: false, cpu: 45)
        for t in 0..<10 {
            r.now = r.start + Double(t)
            r.tick(45)
            #expect(r.monitor.currentInterval == 1.0, "t=\(t)")
        }
        r.now = r.start + 10
        r.tick(45)
        #expect(r.monitor.currentInterval == 5.0)

        r.now = r.start + 15
        r.tick(49)                                  // +4 °C
        #expect(r.monitor.currentInterval == 1.0)
    }

    @Test("A fan-controlling profile, quiet below its start temperature, relaxes to 2 s")
    func balancedRelaxesToTwoSeconds() {
        let r = rig(.balanced, menuOpen: false, cpu: 45)
        r.run(45, seconds: 30, dt: 1)
        #expect(r.monitor.currentInterval == 2.0)
    }

    @Test("An open menu keeps the interval at 1 s")
    func menuOpenKeepsFast() {
        let r = rig(.silent, menuOpen: true, cpu: 45)
        r.run(45, seconds: 60, dt: 1)
        #expect(r.monitor.currentInterval == 1.0)
    }

    @Test("At 85 °C and above the interval is 1 s for every profile, menu closed")
    func hotStaysFast() {
        for profile in [FanProfile.silent, .balanced, .max] {
            let r = rig(profile, menuOpen: false, cpu: 86)
            r.run(86, seconds: 60, dt: 1)
            #expect(r.monitor.currentInterval == 1.0, "\(profile.id)")
        }
    }

    @Test("Switching profile returns to the fast rate")
    func switchingResetsCadence() {
        let r = rig(.silent, menuOpen: false, cpu: 45)
        r.run(45, seconds: 30, dt: 1)
        #expect(r.monitor.currentInterval == 5.0)
        r.monitor.switchProfile(.balanced)
        r.monitor.drainQueue()
        r.now += 1
        r.tick(45)
        #expect(r.monitor.currentInterval == 1.0)
    }

    @Test("A failed read goes back to the fast rate and acts on nothing")
    func failedReadStaysFast() {
        let r = rig(.silent, menuOpen: false, cpu: 45)
        r.run(45, seconds: 30, dt: 1)
        #expect(r.monitor.currentInterval == 5.0)
        r.smc.failing = ["Tp01", "Tp05", "Tg05"]
        r.now += 5
        r.tick(45)
        #expect(r.monitor.currentInterval == 1.0)
        #expect(r.commands.isEmpty)
    }

    // MARK: - What a poll reads

    @Test("Menu closed: a poll reads only the CPU and GPU sensors, once each")
    func lightPollWhenClosed() {
        let r = rig(.silent, menuOpen: false, cpu: 45)
        r.tick(45)                                   // warm-up: probe, fan limits
        r.smc.resetCounts()
        r.run(45, seconds: 4, dt: 1)                 // 5 ticks
        #expect(r.smc.reads("Tp01") == 5)
        #expect(r.smc.reads("Tp05") == 5)
        #expect(r.smc.reads("Tg05") == 5)
        for key in ["Tm02", "TH0x", "TA0P", "F0Ac", "F0Tg", "F0Md", "F1Ac", "FNum", "F0Mn", "F0Mx"] {
            #expect(r.smc.reads(key) == 0, "\(key) read while the menu is closed")
        }
        #expect(r.fullUpdates == 0, "no full status is built or published")
    }

    @Test("Menu open: a poll builds the full status, and no CPU/GPU sensor is read twice")
    func fullPollWhenOpen() {
        let r = rig(.silent, menuOpen: true, cpu: 45)
        r.tick(45)                                   // warm-up: probe, fan limits
        r.smc.resetCounts()
        let published = r.fullUpdates
        r.run(45, seconds: 4, dt: 1)                 // 5 ticks
        #expect(r.smc.reads("Tp01") == 5, "one read per tick, not two")
        #expect(r.smc.reads("Tg05") == 5)
        #expect(r.smc.reads("Tm02") == 5)
        #expect(r.smc.reads("F0Ac") == 5)
        #expect(r.fullUpdates - published == 5)
        #expect(r.monitor.latestStatus != nil)
    }

    @Test("Headline numbers are published only when the rounded peak, state or profile changes")
    func headlinePublishedOnChange() {
        let r = rig(.silent, menuOpen: false, cpu: 45)
        let temps: [Float] = [45.2, 45.4, 44.6, 45.1, 46.0, 46.2]
        for (i, t) in temps.enumerated() {
            r.now = r.start + Double(i)
            r.tick(t)
        }
        // 45, 45, 45, 45 -> one publish; 46, 46 -> one more.
        #expect(r.summaries.map { $0.peak } == [45, 46])
    }

    @Test("Opening the menu builds a full status straight away, off the regular schedule")
    func refreshNowBuildsAStatus() {
        let r = rig(.silent, menuOpen: false, cpu: 45)
        r.run(45, seconds: 10, dt: 1)
        #expect(r.fullUpdates == 0)
        r.monitor.fullStatusWanted = true
        r.monitor.refreshNow()
        r.monitor.drainQueue()
        #expect(r.fullUpdates == 1)
    }

    // MARK: - Time-based anomaly logging

    @Test("A 6 °C jump between two samples 2 s apart is logged as an instant spike, with the real interval")
    func spikeAtTwoSeconds() {
        let r = rig(.silent, cpu: 50)
        r.tick(50)
        r.now += 2
        r.tick(56.5)
        #expect(r.logs.contains { $0.contains("Instant spike") && $0.contains("in 2s") }, "\(r.logs)")
        #expect(r.logs.contains { $0.contains("Pre-spike process history") })
    }

    @Test("It is still caught at the 5 s hands-off poll, and reported as 5 s")
    func spikeAtFiveSeconds() {
        let r = rig(.silent, cpu: 50)
        r.tick(50)
        r.now += 5
        r.tick(56.5)
        #expect(r.logs.contains { $0.contains("Instant spike") && $0.contains("in 5s") }, "\(r.logs)")
    }

    @Test("A drop is logged as a drop")
    func drop() {
        let r = rig(.silent, cpu: 60)
        r.tick(60)
        r.now += 2
        r.tick(53.5)
        #expect(r.logs.contains { $0.contains("Instant drop") })
    }

    @Test("Samples too far apart (after a long gap) are not 'consecutive': no instant spike")
    func noSpikeAcrossAGap() {
        let r = rig(.silent, cpu: 50)
        r.tick(50)
        r.now += 10
        r.tick(60)
        #expect(!r.logs.contains { $0.contains("Instant") })
    }

    @Test("A 4 °C change is not a spike")
    func smallChangeIsQuiet() {
        let r = rig(.silent, cpu: 50)
        r.tick(50)
        r.now += 2
        r.tick(54)
        #expect(!r.logs.contains { $0.contains("Instant") })
    }

    @Test("A sustained 12 °C change over about 30 s is logged")
    func sustainedChange() {
        let r = rig(.silent, cpu: 50)
        // 50 -> 62 °C in 1 °C steps every 2.5 s (never more than 5 °C between samples).
        for i in 0...12 {
            r.now = r.start + Double(i) * 2.5
            r.tick(50 + Float(i))
        }
        #expect(r.logs.contains { $0.contains("Sustained spike") }, "\(r.logs)")
    }

    // MARK: - Time handling

    @Test("A huge gap between ticks (a sleep) doesn't leap the ramp")
    func sleepGapDoesNotLeapTheRamp() {
        let r = rig(.balanced, cpu: 75)
        r.run(75, seconds: 12, dt: 1)                // engaged, part way up the ramp
        let before = r.rpms.last ?? 0
        r.now += 5000                                // the machine slept
        r.tick(75)
        let after = r.rpms.last ?? 0
        #expect(after - before <= 0.05 * 6 * Self.maxRPM + 1, "ramp moved \(after - before) RPM across a sleep")
    }

    @Test("The sustained trigger is measured in seconds: dropping below the start temperature restarts it")
    func sustainedTriggerRestarts() {
        let r = rig(.balanced, cpu: 75)
        r.run(75, seconds: 6, dt: 1)
        r.now += 1
        r.tick(45)                                   // dips below the 55 °C start
        r.now += 1
        r.run(75, seconds: 10, dt: 1)
        let first = (r.commands.first?.at ?? 0) - (r.start + 8)
        #expect(first >= 8 && first <= 9.001, "restarted from the second crossing: \(first)")
    }
}
