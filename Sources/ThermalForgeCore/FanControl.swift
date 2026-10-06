//
//  FanControl.swift
//  ThermalForge
//
//  Core fan control operations: unlock, set speed, reset, status, discover.
//

import Foundation

// MARK: - Types

public enum ThermalForgeError: Error, CustomStringConvertible {
    case smcConnectionFailed
    case unlockFailed(String)
    case readFailed(String)
    case writeFailed(String)
    case rpmOutOfRange(requested: Float, min: Float, max: Float)

    public var description: String {
        switch self {
        case .smcConnectionFailed:
            return "Failed to connect to AppleSMC. Is this a Mac with SMC?"
        case .unlockFailed(let detail):
            return "Fan unlock failed: \(detail)"
        case .readFailed(let key):
            return "Failed to read SMC key: \(key)"
        case .writeFailed(let key):
            return "Failed to write SMC key: \(key). Run with sudo."
        case .rpmOutOfRange(let req, let min, let max):
            return "RPM \(Int(req)) is out of range [\(Int(min))–\(Int(max))]"
        }
    }
}

public struct FanInfo {
    public let index: Int
    public let actualRPM: Float
    public let targetRPM: Float
    public let minRPM: Float
    public let maxRPM: Float
    public let mode: String
}

public struct ThermalStatus: Encodable, Equatable {
    public let fans: [FanStatus]
    public let temperatures: [String: Float]

    public struct FanStatus: Encodable, Equatable {
        public let index: Int
        public let actualRPM: Int
        public let targetRPM: Int
        public let minRPM: Int
        public let maxRPM: Int
        public let mode: String
    }
}

extension ThermalStatus {
    /// Peak of the CPU (`TC`/`Tp`) and GPU (`TG`/`Tg`) sensors — the temperature the
    /// thermal safety floor watches. Single source of truth so the client
    /// `ThermalMonitor` and the daemon's floor read the identical value; mirroring
    /// can't drift because it's the same code.
    public var safetyPeakTemp: Float {
        func peak(_ prefixes: [String]) -> Float {
            temperatures.filter { key, _ in prefixes.contains { key.hasPrefix($0) } }
                .values.max() ?? 0
        }
        return max(peak(["TC", "Tp"]), peak(["TG", "Tg"]))
    }
}

public struct DiscoveredKey {
    public let key: String
    public let size: UInt32
    public let type: String
    public let bytes: [UInt8]
}

// MARK: - Fan Control

public final class FanControl {
    private let smc: SMCReading
    /// Which mode key works on this hardware (detected at init)
    private let modeKeyTemplate: String
    /// Whether Ftst unlock is available (M1-M4) or not (M5+)
    private let hasFtst: Bool
    /// Where operational messages go. nil means TFLogger (a daily file for the app
    /// and the CLI as the user; the unified log when running as root). The daemon
    /// sets this so its lines carry the daemon's own prefix.
    var logSink: ((String) -> Void)?

    // Hardware facts that don't change while the machine is up, read once and kept.
    // Guarded by `cacheLock`: the daemon reaches one FanControl from several threads,
    // the app from the monitor queue.
    private let cacheLock = NSLock()
    private var cachedFanCount: Int?
    private var cachedLimits: [Int: (min: Float, max: Float)] = [:]
    private var sensorProbe: SensorProbe?

    /// Which of `thermalKeys` answer on this machine, from the last probe.
    private struct SensorProbe {
        var live: [String]
        var absent: [String]
        var probedAt: TimeInterval
    }

    /// How often the keys that were absent at the last probe are asked about again.
    /// A sensor that failed once (at startup, or around a wake) must come back; it is
    /// never dropped for the life of the process.
    static let sensorReprobeInterval: TimeInterval = 300
    /// Nothing answered at all: look again sooner.
    static let sensorReprobeIntervalWhenEmpty: TimeInterval = 5

    /// The clock the sensor re-probe schedule runs on (monotonic seconds). Tests
    /// substitute their own so the five-minute interval doesn't have to be waited out.
    var sensorClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// A FanControl backed by the real SMC. Throws if there is none.
    public convenience init() throws {
        guard let connection = SMCConnection() else {
            throw ThermalForgeError.smcConnectionFailed
        }
        self.init(smc: connection)
    }

    /// Any SMC backend: the real one, or a fake key table in tests.
    public init(smc: SMCReading) {
        self.smc = smc

        // Detect hardware: which mode key exists?
        // M5 Max uses F%dmd (lowercase), M1-M4 use F%dMd (uppercase)
        let lowerResult = smc.readKey(SMCFanKey.key(SMCFanKey.modeLower, fan: 0))
        if lowerResult.success {
            self.modeKeyTemplate = SMCFanKey.modeLower
        } else {
            self.modeKeyTemplate = SMCFanKey.modeUpper
        }

        // Check if Ftst exists (M1-M4 unlock mechanism)
        if let info = smc.getKeyInfo(SMCFanKey.forceTest), info.size > 0 {
            self.hasFtst = true
        } else {
            self.hasFtst = false
        }
    }

    // MARK: - Fan Count

    /// The number of fans. A hardware constant, read once; a failed read isn't kept.
    public func fanCount() throws -> Int {
        cacheLock.lock()
        let cached = cachedFanCount
        cacheLock.unlock()
        if let cached { return cached }

        let result = smc.readKey(SMCFanKey.count)
        guard result.success, !result.bytes.isEmpty else {
            throw ThermalForgeError.readFailed(SMCFanKey.count)
        }
        let count = Int(result.bytes[0])
        cacheLock.lock()
        cachedFanCount = count
        cacheLock.unlock()
        return count
    }

    // MARK: - Read Fan Info

    public func fanInfo(_ index: Int) throws -> FanInfo {
        let actual = readFanFloat(index, template: SMCFanKey.actual)
        let target = readFanFloat(index, template: SMCFanKey.target)
        let limits = fanLimits(index)

        return FanInfo(
            index: index,
            actualRPM: actual,
            targetRPM: target,
            minRPM: limits.min,
            maxRPM: limits.max,
            mode: readMode(index)
        )
    }

    /// A fan's [min, max] RPM are firmware constants: read once, then kept. Only kept
    /// once a valid maximum (> 0) was seen, so a zero from a failed read at startup is
    /// never latched. These bound every speed we ever set, so they are the one thing
    /// here we'd rather re-read than trust a bad value.
    private func fanLimits(_ index: Int) -> (min: Float, max: Float) {
        cacheLock.lock()
        let cached = cachedLimits[index]
        cacheLock.unlock()
        if let cached { return cached }

        let minimum = readFanFloat(index, template: SMCFanKey.minimum)
        let maximum = readFanFloat(index, template: SMCFanKey.maximum)
        if maximum > 0 {
            cacheLock.lock()
            cachedLimits[index] = (minimum, maximum)
            cacheLock.unlock()
        }
        return (minimum, maximum)
    }

    /// Min/max RPM of the primary fan (fan 0), kept after the first read. Falls back to
    /// the typical Apple Silicon range when there is no fan or the limits read as zero.
    public func primaryFanLimits() -> (minRPM: Float, maxRPM: Float) {
        guard let count = try? fanCount(), count > 0 else { return (2317, 7826) }
        let limits = fanLimits(0)
        return (limits.min > 0 ? limits.min : 2317, limits.max > 0 ? limits.max : 7826)
    }

    private func readMode(_ index: Int) -> String {
        let modeResult = smc.readKey(SMCFanKey.key(modeKeyTemplate, fan: index))
        let modeValue = modeResult.success && !modeResult.bytes.isEmpty ? modeResult.bytes[0] : 0
        switch modeValue {
        case 0: return "auto"
        case 1: return "manual"
        case 3: return "system"
        default: return "unknown(\(modeValue))"
        }
    }

    // MARK: - Unlock

    /// Unlock fans for manual control.
    /// On M1-M4: writes Ftst=1, then polls until mode write succeeds.
    /// On M5+: Ftst doesn't exist, attempts direct mode write.
    private func unlockFans(count: Int) throws {
        // Already unlocked by an earlier command: every fan is in manual mode and, where
        // it exists, Ftst is still set. Re-running the unlock would write Ftst again and
        // sleep half a second on EVERY speed change. Both are read from the SMC here, so
        // if the system took the fans back (mode no longer manual, or Ftst cleared) this
        // is false and the full unlock below runs.
        if allFansUnlocked(count: count) { return }

        if hasFtst {
            // M1-M4 path: Ftst unlock suppresses thermalmonitord
            guard smc.writeKey(SMCFanKey.forceTest, bytes: [1]) else {
                throw ThermalForgeError.unlockFailed(
                    "Failed to write Ftst=1. Run with sudo."
                )
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Set each fan to manual mode
        for i in 0..<count {
            let modeKey = SMCFanKey.key(modeKeyTemplate, fan: i)
            let deadline = Date().addingTimeInterval(10.0)
            var success = false

            while Date() < deadline {
                if smc.writeKey(modeKey, bytes: [1]) {
                    success = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }

            if !success {
                throw ThermalForgeError.unlockFailed(
                    "Timed out setting fan \(i) to manual mode. Run with sudo."
                )
            }
        }
    }

    /// True when manual control is already fully in place (see `unlockFans`).
    private func allFansUnlocked(count: Int) -> Bool {
        guard count > 0 else { return false }
        for i in 0..<count where readMode(i) != "manual" { return false }
        if hasFtst {
            let ftst = smc.readKey(SMCFanKey.forceTest)
            guard ftst.success, let value = ftst.bytes.first, value != 0 else { return false }
        }
        return true
    }

    /// Unlock a single fan for manual control
    private func unlockSingleFan(_ index: Int) throws {
        if hasFtst {
            guard smc.writeKey(SMCFanKey.forceTest, bytes: [1]) else {
                throw ThermalForgeError.unlockFailed(
                    "Failed to write Ftst=1. Run with sudo."
                )
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        let modeKey = SMCFanKey.key(modeKeyTemplate, fan: index)
        let deadline = Date().addingTimeInterval(10.0)

        while Date() < deadline {
            if smc.writeKey(modeKey, bytes: [1]) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        throw ThermalForgeError.unlockFailed(
            "Timed out setting fan \(index) to manual mode. Run with sudo."
        )
    }

    // MARK: - Set Speed

    /// Set all fans to maximum RPM
    public func setMax() throws {
        let count = try fanCount()
        try unlockFans(count: count)

        for i in 0..<count {
            let info = try fanInfo(i)
            let maxRPM = info.maxRPM > 0 ? info.maxRPM : 7826

            let targetKey = SMCFanKey.key(SMCFanKey.target, fan: i)
            guard smc.writeKey(targetKey, bytes: floatToSMCBytes(maxRPM)) else {
                throw ThermalForgeError.writeFailed(targetKey)
            }
            log("Set fan \(i) to max (\(Int(maxRPM)) RPM)")
        }
    }

    /// Set a single fan to a specific RPM
    public func setSpeed(fan index: Int, rpm: Float) throws {
        let info = try fanInfo(index)

        // Safety: never below minimum
        if info.minRPM > 0 && rpm < info.minRPM {
            throw ThermalForgeError.rpmOutOfRange(
                requested: rpm, min: info.minRPM, max: info.maxRPM
            )
        }

        // Safety: never above maximum
        if info.maxRPM > 0 && rpm > info.maxRPM {
            throw ThermalForgeError.rpmOutOfRange(
                requested: rpm, min: info.minRPM, max: info.maxRPM
            )
        }

        if info.mode != "manual" {
            try unlockSingleFan(index)
        }

        let targetKey = SMCFanKey.key(SMCFanKey.target, fan: index)
        guard smc.writeKey(targetKey, bytes: floatToSMCBytes(rpm)) else {
            throw ThermalForgeError.writeFailed(targetKey)
        }
        log("Set fan \(index) to \(Int(rpm)) RPM")
    }

    /// Set all fans to a specific RPM
    public func setAllFans(rpm: Float) throws {
        let count = try fanCount()

        // Validate against first fan's limits
        let info = try fanInfo(0)
        if info.minRPM > 0 && rpm < info.minRPM {
            throw ThermalForgeError.rpmOutOfRange(
                requested: rpm, min: info.minRPM, max: info.maxRPM
            )
        }
        if info.maxRPM > 0 && rpm > info.maxRPM {
            throw ThermalForgeError.rpmOutOfRange(
                requested: rpm, min: info.minRPM, max: info.maxRPM
            )
        }

        try unlockFans(count: count)

        for i in 0..<count {
            let targetKey = SMCFanKey.key(SMCFanKey.target, fan: i)
            guard smc.writeKey(targetKey, bytes: floatToSMCBytes(rpm)) else {
                throw ThermalForgeError.writeFailed(targetKey)
            }
            log("Set fan \(i) to \(Int(rpm)) RPM")
        }
    }

    // MARK: - Manual-Control Check

    /// Whether a manual-control session is engaged at the SMC: any fan in manual
    /// mode, or (M1-M4) Ftst still set, which keeps thermalmonitord off the fans
    /// even with every mode back on auto. Throws when a key can't be read, so the
    /// caller picks its own safe default rather than this guessing "auto".
    public func manualControlEngaged() throws -> Bool {
        let count = try fanCount()
        for i in 0..<count {
            let modeKey = SMCFanKey.key(modeKeyTemplate, fan: i)
            let result = smc.readKey(modeKey)
            guard result.success, let mode = result.bytes.first else {
                throw ThermalForgeError.readFailed(modeKey)
            }
            if mode == 1 { return true }   // 1 = manual (see fanInfo)
        }
        if hasFtst {
            let result = smc.readKey(SMCFanKey.forceTest)
            guard result.success, let ftst = result.bytes.first else {
                throw ThermalForgeError.readFailed(SMCFanKey.forceTest)
            }
            if ftst != 0 { return true }
        }
        return false
    }

    // MARK: - Reset

    /// Reset all fans to Apple defaults (auto mode, thermalmonitord resumes)
    public func resetAuto() throws {
        let count = try fanCount()

        for i in 0..<count {
            let modeKey = SMCFanKey.key(modeKeyTemplate, fan: i)
            _ = smc.writeKey(modeKey, bytes: [0])

            let targetKey = SMCFanKey.key(SMCFanKey.target, fan: i)
            _ = smc.writeKey(targetKey, bytes: floatToSMCBytes(0))
        }

        // Reset Ftst if it exists — thermalmonitord reclaims control
        if hasFtst {
            _ = smc.writeKey(SMCFanKey.forceTest, bytes: [0])
        }
        log("Reset to Apple defaults")
    }

    // MARK: - Thermal Sensor Keys

    /// All thermal sensor keys probed for `status()`. Keys absent on a given machine
    /// return nil from `readTemp` and are skipped. Single source of truth so the
    /// daemon's safety floor reads exactly the CPU/GPU subset `status()` would.
    public static let thermalKeys: [String] = [
        // CPU — aggregate (M5 Max verified)
        "TCDX", "TCHP", "TCMb",
        // CPU — per-core (Tp prefix, present across M1-M5 with varying mappings)
        "Tp01", "Tp02", "Tp03", "Tp04", "Tp05", "Tp06", "Tp07", "Tp08",
        "Tp09", "Tp0A", "Tp0B", "Tp0C", "Tp0D", "Tp0F", "Tp0G", "Tp0H",
        "Tp0J", "Tp0L", "Tp0P", "Tp0S", "Tp0T", "Tp0W", "Tp0X", "Tp0b",
        // GPU (flt — M1-M4, and ioft 8-byte — M5 Max)
        "Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j",
        "TG0B", "TG0H", "TG0V",
        // Memory
        "Tm02", "Tm06", "Tm08", "Tm09", "TRDX", "TMVR",
        // Power delivery
        "TPDX",
        // SSD
        "TH0x", "TH0A", "TH0B",
        // Ambient
        "TAOL", "TA0P",
        // Proximity
        "TS0P",
        // Battery
        "TB0T",
    ]

    /// The CPU (TC/Tp) and GPU (TG/Tg) subset the thermal safety floor watches —
    /// derived from `thermalKeys` so it can't drift from what `status()` reports.
    public static let safetyTempKeys: [String] =
        thermalKeys.filter { key in ["TC", "Tp", "TG", "Tg"].contains { key.hasPrefix($0) } }

    /// Read one temperature key, decoding by returned size (flt 4-byte or ioft 8-byte).
    /// nil if absent, wrong size, or out of the sane 0–150°C range. Does NOT lock — the
    /// caller serializes SMC access (the daemon takes smcLock per key so a full sweep
    /// never blocks a client write for more than a single read).
    public func readTemp(_ key: String) -> Float? {
        let result = smc.readKey(key)
        guard result.success else { return nil }
        let temp: Float
        if result.size == 4 {
            temp = smcBytesToFloat(result.bytes, size: result.size)
        } else if result.size == 8 {
            temp = ioftBytesToFloat(result.bytes)
        } else {
            return nil
        }
        guard temp > 0, temp < 150 else { return nil }
        return (temp * 10).rounded() / 10
    }

    // MARK: - Status

    /// Read current fan speeds and temperatures
    public func status() throws -> ThermalStatus {
        let count = try fanCount()
        var fans: [ThermalStatus.FanStatus] = []

        for i in 0..<count {
            let info = try fanInfo(i)
            fans.append(ThermalStatus.FanStatus(
                index: i,
                actualRPM: Int(info.actualRPM),
                targetRPM: Int(info.targetRPM),
                minRPM: Int(info.minRPM),
                maxRPM: Int(info.maxRPM),
                mode: info.mode
            ))
        }

        // Read the temperature keys known across all Apple Silicon generations. Keys
        // that don't exist on this machine are found once (and re-checked every few
        // minutes, see `liveTemperatureKeys`) and not asked about on every read.
        // Labels use the raw SMC key name — no assumptions about what a key
        // means on hardware we haven't verified. flt/ioft is decoded by size in readTemp.
        var temps: [String: Float] = [:]
        for key in liveTemperatureKeys() {
            if let t = readTemp(key) { temps[key] = t }
        }

        return ThermalStatus(fans: fans, temperatures: temps)
    }

    // MARK: - Control read and sensor probe

    private static let safetyKeySet: Set<String> = Set(safetyTempKeys)

    /// The cheap read for the control loop: the peak CPU and the peak GPU temperature,
    /// and nothing else. Skips the display-only sensors (memory, SSD, ambient, …) and
    /// every fan read. nil when no CPU or GPU sensor could be read, which the caller
    /// treats as a failed tick; the sensor probe is then re-run at its next chance.
    public func controlTemps() -> (cpu: Float, gpu: Float)? {
        var cpu: Float = 0
        var gpu: Float = 0
        var read = false
        for key in liveTemperatureKeys() where Self.safetyKeySet.contains(key) {
            guard let t = readTemp(key) else { continue }
            read = true
            if key.hasPrefix("TC") || key.hasPrefix("Tp") {
                cpu = max(cpu, t)
            } else {
                gpu = max(gpu, t)
            }
        }
        if !read { markSensorProbeStale() }
        return read ? (cpu, gpu) : nil
    }

    /// The thermal keys that answer on this machine. Probed once on first use; after
    /// that, only the keys that did NOT answer are asked about again, every
    /// `sensorReprobeInterval`, so a sensor that failed at startup or around a wake
    /// comes back instead of being dropped until the process restarts. Keys that
    /// answered stay in the set; one that misreads on a given tick is simply skipped
    /// that tick and tried again on the next.
    private func liveTemperatureKeys() -> [String] {
        let now = sensorClock()
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if var probe = sensorProbe {
            let wait = probe.live.isEmpty ? Self.sensorReprobeIntervalWhenEmpty : Self.sensorReprobeInterval
            let due = now - probe.probedAt >= wait && (probe.live.isEmpty || !probe.absent.isEmpty)
            guard due else { return probe.live }

            let pool = probe.live.isEmpty ? Self.thermalKeys : probe.absent
            var answered = Set(probe.live)
            var stillAbsent: [String] = []
            for key in pool {
                if readTemp(key) != nil { answered.insert(key) } else { stillAbsent.append(key) }
            }
            probe.live = Self.thermalKeys.filter { answered.contains($0) }
            probe.absent = stillAbsent
            probe.probedAt = now
            sensorProbe = probe
            return probe.live
        }

        var live: [String] = []
        var absent: [String] = []
        for key in Self.thermalKeys {
            if readTemp(key) != nil { live.append(key) } else { absent.append(key) }
        }
        sensorProbe = SensorProbe(live: live, absent: absent, probedAt: now)
        return live
    }

    /// Make the next `liveTemperatureKeys()` re-check the absent keys now.
    private func markSensorProbeStale() {
        cacheLock.lock()
        if var probe = sensorProbe {
            probe.probedAt = -.infinity
            sensorProbe = probe
        }
        cacheLock.unlock()
    }

    /// Drop what was learned about this machine's sensors and remembered key sizes, so
    /// the next reads start from scratch (the daemon calls this on wake). Fan count and
    /// limits are hardware constants and are kept.
    public func refreshHardwareCache() {
        cacheLock.lock()
        sensorProbe = nil
        cacheLock.unlock()
        smc.invalidateKeyCache()
    }

    // MARK: - Discover

    /// Enumerate SMC keys. Optional prefix filter skips reads for non-matching keys.
    public func discover(prefix: String? = nil) -> [DiscoveredKey] {
        let count = smc.getKeyCount()
        var keys: [DiscoveredKey] = []

        for i: UInt32 in 0..<count {
            guard let keyName = smc.getKeyAtIndex(i) else { continue }

            // Skip non-matching keys early
            if let prefix = prefix, !keyName.hasPrefix(prefix) { continue }

            let info = smc.getKeyInfo(keyName)
            let result = smc.readKey(keyName)

            keys.append(DiscoveredKey(
                key: keyName,
                size: info?.size ?? 0,
                type: info?.type ?? "????",
                bytes: result.success ? result.bytes : []
            ))
        }

        return keys
    }

    // MARK: - Hardware Info

    /// Returns detected hardware capabilities
    public var hardwareInfo: String {
        let ftst = hasFtst ? "yes (M1-M4 path)" : "no (M5+ direct mode)"
        let modeKey = modeKeyTemplate == SMCFanKey.modeLower ? "F%dmd (lowercase)" : "F%dMd (uppercase)"
        return "Ftst unlock: \(ftst), Mode key: \(modeKey)"
    }

    // MARK: - Private Helpers

    private func readFanFloat(_ fan: Int, template: String) -> Float {
        let key = SMCFanKey.key(template, fan: fan)
        let result = smc.readKey(key)
        guard result.success else { return 0 }
        return smcBytesToFloat(result.bytes, size: result.size)
    }

    private func log(_ message: String) {
        Self.deliver(message, to: logSink) { TFLogger.shared.fan($0) }
    }

    /// Send to `sink` when set, otherwise to `fallback`. The fallback runs only
    /// then, so a routed FanControl never initializes TFLogger.
    static func deliver(_ message: String, to sink: ((String) -> Void)?,
                        fallback: (String) -> Void) {
        if let sink { sink(message) } else { fallback(message) }
    }
}
