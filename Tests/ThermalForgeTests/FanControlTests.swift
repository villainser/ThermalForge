//
//  FanControlTests.swift
//  ThermalForge
//
//  What a poll costs in SMC reads, how the live-sensor probe behaves (including a sensor
//  that comes back), the cached hardware facts, the unlock shortcut, the RPM bounds, and
//  that control can always be handed back to the system. All against a fake key table.
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("FanControl")
struct FanControlTests {

    private func make(cpu: Float = 45, gpu: Float = 40) -> (smc: FakeSMC, fan: FanControl) {
        let smc = FakeSMC.standard(cpu: cpu, gpu: gpu)
        let fan = FanControl(smc: smc)
        fan.logSink = { _ in }
        return (smc, fan)
    }

    // MARK: - Reading

    @Test("status() reports the fans and the live sensors, and not the absent ones")
    func statusContent() throws {
        let (_, fan) = make()
        let status = try fan.status()
        #expect(status.fans.count == 2)
        #expect(status.fans[0].minRPM == 2317)
        #expect(status.fans[0].maxRPM == 7826)
        #expect(status.fans[0].mode == "auto")
        #expect(status.temperatures["Tp01"] == 45)
        #expect(status.temperatures["Tg05"] == 40)
        #expect(status.temperatures["Tm02"] == 38)
        #expect(status.temperatures["Tp0X"] == nil)
        #expect(status.temperatures.count == 6)
    }

    @Test("The first status probes every known key once; after that only the live keys are read")
    func liveKeysProbedOnce() throws {
        let (smc, fan) = make()
        _ = try fan.status()
        #expect(smc.reads("Tp01") == 2)     // probe + the read itself
        #expect(smc.reads("Tp0X") == 1)     // absent: asked about once, at the probe
        smc.resetCounts()
        _ = try fan.status()
        #expect(smc.reads("Tp01") == 1)
        #expect(smc.reads("Tp0X") == 0)     // not asked about again
        #expect(smc.reads("TCDX") == 0)
        #expect(smc.reads("TG0B") == 0)
    }

    @Test("A steady-state poll costs 12 reads here (6 fan reads + 6 live sensors), down from about 60")
    func pollCost() throws {
        let (smc, fan) = make()
        _ = try fan.status()                // warm up: probe, fan count, fan limits
        smc.resetCounts()
        _ = try fan.status()
        #expect(smc.totalReads == 12)
    }

    @Test("controlTemps() reads only the CPU and GPU sensors: no fans, no display-only sensors")
    func controlReadIsLight() throws {
        let (smc, fan) = make()
        _ = try fan.status()
        smc.resetCounts()
        let temps = fan.controlTemps()
        #expect(temps?.cpu == 45)
        #expect(temps?.gpu == 40)
        #expect(smc.reads("Tp01") == 1)
        #expect(smc.reads("Tp05") == 1)
        #expect(smc.reads("Tg05") == 1)
        for key in ["Tm02", "TH0x", "TA0P", "F0Ac", "F0Tg", "F0Md", "F0Mn", "F0Mx", "FNum"] {
            #expect(smc.reads(key) == 0, "\(key) should not be read by a control poll")
        }
        #expect(smc.totalReads == 3)
    }

    @Test("The control peak equals the peak the full status reports")
    func controlPeakMatchesStatus() throws {
        let (smc, fan) = make(cpu: 71.3, gpu: 66)
        smc.set("Tg05", float: 80.4)
        let status = try fan.status()
        let temps = try #require(fan.controlTemps())
        #expect(status.safetyPeakTemp == max(temps.cpu, temps.gpu))
        #expect(abs(status.safetyPeakTemp - 80.4) < 0.001)
    }

    @Test("A sensor that was absent at the first probe comes back after the re-probe interval, not never")
    func absentSensorComesBack() throws {
        let (smc, fan) = make()
        var clock = 0.0
        fan.sensorClock = { clock }
        smc.failing = ["Tp05"]

        let atStart = try fan.status().temperatures["Tp05"]
        #expect(atStart == nil)
        smc.failing = []

        // Not asked about again before the interval is up.
        let soon = try fan.status().temperatures["Tp05"]
        #expect(soon == nil)
        clock = FanControl.sensorReprobeInterval - 1
        let justBefore = try fan.status().temperatures["Tp05"]
        #expect(justBefore == nil)

        clock = FanControl.sensorReprobeInterval + 1
        let after = try fan.status().temperatures["Tp05"]
        #expect(after == 43)
    }

    @Test("If no CPU or GPU sensor can be read, the control read fails, and the keys are re-probed at the next chance")
    func controlReadRecoversFromTotalFailure() {
        let (smc, fan) = make()
        smc.failing = ["Tp01", "Tp05", "Tg05"]
        #expect(fan.controlTemps() == nil)
        smc.failing = []
        #expect(fan.controlTemps() != nil)
    }

    @Test("With no sensors at all, the status has no temperatures and the safety peak is 0")
    func noSensors() throws {
        let smc = FakeSMC()
        smc.set("FNum", byte: 1)
        smc.set("F0Ac", float: 0)
        smc.set("F0Tg", float: 0)
        smc.set("F0Mn", float: 2317)
        smc.set("F0Mx", float: 7826)
        smc.set("F0Md", byte: 0)
        let fan = FanControl(smc: smc)
        let status = try fan.status()
        #expect(status.temperatures.isEmpty)
        #expect(status.safetyPeakTemp == 0)
        #expect(fan.controlTemps() == nil)
    }

    @Test("Readings outside 0–150 °C are treated as no reading")
    func implausibleReadings() throws {
        let (smc, fan) = make()
        smc.set("Tp01", float: 0)
        smc.set("Tp05", float: 151)
        let status = try fan.status()
        #expect(status.temperatures["Tp01"] == nil)
        #expect(status.temperatures["Tp05"] == nil)
    }

    @Test("refreshHardwareCache() drops the sensor probe and the remembered key sizes")
    func refresh() throws {
        let (smc, fan) = make()
        _ = try fan.status()
        smc.resetCounts()
        fan.refreshHardwareCache()
        #expect(smc.cacheInvalidations == 1)
        _ = try fan.status()
        #expect(smc.reads("Tp0X") == 1)     // probed again from scratch
    }

    // MARK: - Hardware facts

    @Test("Fan count and the fan's min/max RPM are read once, then kept")
    func hardwareFactsAreCached() throws {
        let (smc, fan) = make()
        _ = try fan.status()
        smc.resetCounts()
        let count = try fan.fanCount()
        #expect(count == 2)
        let limits = fan.primaryFanLimits()
        #expect(limits.minRPM == 2317 && limits.maxRPM == 7826)
        _ = try fan.fanInfo(0)
        #expect(smc.reads("FNum") == 0)
        #expect(smc.reads("F0Mn") == 0)
        #expect(smc.reads("F0Mx") == 0)
        #expect(smc.reads("F0Ac") == 1)     // live values are still read every time
        #expect(smc.reads("F0Tg") == 1)
        #expect(smc.reads("F0Md") == 1)
    }

    @Test("A maximum that reads as 0 (a failed read at startup) is never kept")
    func zeroMaximumNotLatched() {
        let smc = FakeSMC.standard()
        smc.set("F0Mx", float: 0)
        smc.set("F0Mn", float: 0)
        let fan = FanControl(smc: smc)
        let first = fan.primaryFanLimits()
        #expect(first.minRPM == 2317 && first.maxRPM == 7826)      // the typical-range fallback

        smc.set("F0Mn", float: 1500)
        smc.set("F0Mx", float: 6000)
        let second = fan.primaryFanLimits()
        #expect(second.minRPM == 1500 && second.maxRPM == 6000)    // the real values, now read

        smc.set("F0Mx", float: 9999)
        #expect(fan.primaryFanLimits().maxRPM == 6000)             // and kept
    }

    @Test("With no fans, the limits fall back to the typical range")
    func noFans() {
        let smc = FakeSMC.standard(fans: 0)
        let fan = FanControl(smc: smc)
        let limits = fan.primaryFanLimits()
        #expect(limits.minRPM == 2317 && limits.maxRPM == 7826)
    }

    // MARK: - Unlock shortcut

    @Test("The unlock (Ftst write and half-second wait) runs once; later speed changes skip it")
    func unlockRunsOnce() throws {
        let smc = FakeSMC.standard()
        smc.set("Ftst", byte: 0)
        let fan = FanControl(smc: smc)
        fan.logSink = { _ in }

        try fan.setAllFans(rpm: 3000)
        let first = smc.writeLog.map { $0.key }
        #expect(first.contains("Ftst"))
        #expect(first.contains("F0Md") && first.contains("F1Md"))
        #expect(smc.stored("Ftst") == [1])

        smc.resetCounts()
        let started = Date()
        try fan.setAllFans(rpm: 3500)
        #expect(Date().timeIntervalSince(started) < 0.3, "no 0.5 s unlock wait on a repeat")
        let second = smc.writeLog.map { $0.key }
        #expect(!second.contains("Ftst"))
        #expect(!second.contains("F0Md") && !second.contains("F1Md"))
        #expect(second.contains("F0Tg") && second.contains("F1Tg"))
    }

    @Test("If the system takes a fan back, the next command unlocks again")
    func unlockRedoneAfterSystemTakesOver() throws {
        let smc = FakeSMC.standard()
        smc.set("Ftst", byte: 0)
        let fan = FanControl(smc: smc)
        fan.logSink = { _ in }
        try fan.setAllFans(rpm: 3000)

        smc.set("F1Md", byte: 0)               // thermalmonitord reclaimed one fan
        smc.resetCounts()
        try fan.setAllFans(rpm: 3500)
        let writes = smc.writeLog.map { $0.key }
        #expect(writes.contains("Ftst"))
        #expect(writes.contains("F1Md"))
        #expect(smc.stored("F1Md") == [1])
    }

    @Test("If Ftst was cleared, the next command unlocks again even with every fan in manual")
    func unlockRedoneWhenFtstCleared() throws {
        let smc = FakeSMC.standard()
        smc.set("Ftst", byte: 0)
        let fan = FanControl(smc: smc)
        fan.logSink = { _ in }
        try fan.setAllFans(rpm: 3000)

        smc.set("Ftst", byte: 0)
        smc.resetCounts()
        try fan.setAllFans(rpm: 3500)
        #expect(smc.writeLog.map { $0.key }.contains("Ftst"))
        #expect(smc.stored("Ftst") == [1])
    }

    @Test("A machine without Ftst (M5-style, lower-case mode keys, ioft GPU sensor) works the same way")
    func m5Style() throws {
        let smc = FakeSMC.standard()
        for i in 0..<2 {
            smc.remove("F\(i)Md")
            smc.set("F\(i)md", byte: 0)
        }
        smc.remove("Tg05")
        smc.setIoft("TG0B", 52.5)
        let fan = FanControl(smc: smc)
        fan.logSink = { _ in }

        let status = try fan.status()
        #expect(status.temperatures["TG0B"] == 52.5)
        #expect(fan.controlTemps()?.gpu == 52.5)

        try fan.setAllFans(rpm: 3000)
        #expect(!smc.writeLog.map { $0.key }.contains("Ftst"))
        #expect(smc.stored("F0md") == [1])

        smc.resetCounts()
        try fan.setAllFans(rpm: 3200)
        #expect(!smc.writeLog.map { $0.key }.contains("F0md"))      // already manual: shortcut taken
        #expect(smc.writeLog.map { $0.key }.contains("F0Tg"))
    }

    // MARK: - RPM bounds

    @Test("setSpeed accepts exactly the reported minimum and maximum, and refuses anything outside")
    func rpmBoundsSetSpeed() throws {
        let (_, fan) = make()
        try fan.setSpeed(fan: 0, rpm: 2317)
        try fan.setSpeed(fan: 0, rpm: 7826)
        #expect(throws: ThermalForgeError.self) { try fan.setSpeed(fan: 0, rpm: 2316.9) }
        #expect(throws: ThermalForgeError.self) { try fan.setSpeed(fan: 0, rpm: 7826.1) }
        #expect(throws: ThermalForgeError.self) { try fan.setSpeed(fan: 0, rpm: 0) }
    }

    @Test("setAllFans accepts exactly the reported minimum and maximum, and refuses anything outside")
    func rpmBoundsSetAll() throws {
        let (smc, fan) = make()
        try fan.setAllFans(rpm: 2317)
        try fan.setAllFans(rpm: 7826)
        let before = smc.writeLog.count
        #expect(throws: ThermalForgeError.self) { try fan.setAllFans(rpm: 2316.9) }
        #expect(throws: ThermalForgeError.self) { try fan.setAllFans(rpm: 7826.1) }
        #expect(smc.writeLog.count == before, "a refused speed writes nothing")
    }

    @Test("setMax drives every fan to the maximum the hardware reports")
    func setMaxUsesReportedMaximum() throws {
        let smc = FakeSMC.standard()
        smc.set("F1Mx", float: 6500)
        let fan = FanControl(smc: smc)
        fan.logSink = { _ in }
        try fan.setMax()
        #expect(smc.stored("F0Tg") == floatToSMCBytes(7826))
        #expect(smc.stored("F1Tg") == floatToSMCBytes(6500))
    }

    // MARK: - Handing control back

    @Test("resetAuto() returns every fan, and Ftst, to the system")
    func resetAutoHandsBack() throws {
        let smc = FakeSMC.standard()
        smc.set("Ftst", byte: 0)
        let fan = FanControl(smc: smc)
        fan.logSink = { _ in }

        try fan.setAllFans(rpm: 4000)
        let engaged = try fan.manualControlEngaged()
        #expect(engaged)

        try fan.resetAuto()
        #expect(smc.stored("F0Md") == [0])
        #expect(smc.stored("F1Md") == [0])
        #expect(smc.stored("Ftst") == [0])
        #expect(smc.stored("F0Tg") == floatToSMCBytes(0))
        let stillEngaged = try fan.manualControlEngaged()
        #expect(!stillEngaged)
    }

    @Test("After a reset, the next command does the full unlock again")
    func unlockAfterReset() throws {
        let smc = FakeSMC.standard()
        smc.set("Ftst", byte: 0)
        let fan = FanControl(smc: smc)
        fan.logSink = { _ in }
        try fan.setAllFans(rpm: 3000)
        try fan.resetAuto()

        smc.resetCounts()
        try fan.setAllFans(rpm: 3000)
        #expect(smc.writeLog.map { $0.key }.contains("Ftst"))
        #expect(smc.stored("F0Md") == [1])
    }
}
