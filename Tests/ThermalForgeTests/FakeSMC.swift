//
//  FakeSMC.swift
//  ThermalForge
//
//  A key table standing in for the SMC, so FanControl and ThermalMonitor test without
//  hardware. It counts every read ATTEMPT (including ones for keys that aren't there)
//  and logs every write, which is what lets the tests assert how many SMC calls a poll
//  costs and that an unlock that was already done isn't done again.
//

import Foundation

@testable import ThermalForgeCore

final class FakeSMC: SMCReading {
    private var table: [String: [UInt8]] = [:]
    private(set) var readCounts: [String: Int] = [:]
    private(set) var writeLog: [(key: String, bytes: [UInt8])] = []
    private(set) var cacheInvalidations = 0
    /// Keys whose reads fail right now, as a flaky or absent sensor's would.
    var failing: Set<String> = []

    // MARK: Building the table

    func set(_ key: String, float value: Float) { table[key] = floatToSMCBytes(value) }
    func set(_ key: String, byte value: UInt8) { table[key] = [value] }

    /// An 8-byte `ioft` key (16.16 fixed point), as the M5 Max reports GPU temperatures.
    func setIoft(_ key: String, _ value: Float) {
        let raw = UInt32(value * 65536)
        var bytes = withUnsafeBytes(of: raw.littleEndian) { Array($0) }
        bytes += [0, 0, 0, 0]
        table[key] = bytes
    }

    func remove(_ key: String) { table[key] = nil }

    /// A machine with `fans` fans (2317-7826 RPM) and a handful of sensors:
    /// CPU Tp01/Tp05, GPU Tg05, and display-only memory/SSD/ambient.
    static func standard(fans: Int = 2, cpu: Float = 45, gpu: Float = 40) -> FakeSMC {
        let smc = FakeSMC()
        smc.set("FNum", byte: UInt8(fans))
        for i in 0..<fans {
            smc.set("F\(i)Ac", float: 0)
            smc.set("F\(i)Tg", float: 0)
            smc.set("F\(i)Mn", float: 2317)
            smc.set("F\(i)Mx", float: 7826)
            smc.set("F\(i)Md", byte: 0)
        }
        smc.set("Tp01", float: cpu)
        smc.set("Tp05", float: cpu - 2)
        smc.set("Tg05", float: gpu)
        smc.set("Tm02", float: 38)
        smc.set("TH0x", float: 35)
        smc.set("TA0P", float: 30)
        return smc
    }

    // MARK: Counters

    func reads(_ key: String) -> Int { readCounts[key] ?? 0 }
    var totalReads: Int { readCounts.values.reduce(0, +) }
    /// Current stored bytes for a key (what a write left behind).
    func stored(_ key: String) -> [UInt8]? { table[key] }
    func resetCounts() {
        readCounts = [:]
        writeLog = []
    }

    // MARK: SMCReading

    func readKey(_ key: String) -> (success: Bool, bytes: [UInt8], size: UInt32) {
        readCounts[key, default: 0] += 1
        guard !failing.contains(key), let bytes = table[key] else { return (false, [], 0) }
        return (true, bytes, UInt32(bytes.count))
    }

    func writeKey(_ key: String, bytes: [UInt8]) -> Bool {
        guard let existing = table[key] else { return false }
        writeLog.append((key: key, bytes: bytes))
        // A write keeps the key's size, as on the real SMC.
        table[key] = Array(bytes.prefix(existing.count))
        return true
    }

    func getKeyInfo(_ key: String) -> (size: UInt32, type: String)? {
        table[key].map { (size: UInt32($0.count), type: "flt ") }
    }

    func getKeyCount() -> UInt32 { UInt32(table.count) }
    func getKeyAtIndex(_ index: UInt32) -> String? { nil }

    func invalidateKeyCache() { cacheInvalidations += 1 }
}
