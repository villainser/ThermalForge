//
//  DaemonLoopTimingTests.swift
//  ThermalForge
//
//  The daemon's idle behaviour: how long its background loops sleep with and without a
//  hold, and the wake gate that cuts the long sleep short the moment a hold appears. The
//  safety point is that going quiet at idle never delays protection for a new hold.
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Daemon idle timing")
struct DaemonLoopTimingTests {

    @Test("With nothing held the loops sleep long; with a hold or an override they run at their active rate")
    func intervals() {
        #expect(DaemonLoopTiming.floorInterval(holding: false, suspended: false) == 10)
        #expect(DaemonLoopTiming.floorInterval(holding: true, suspended: false) == 1)
        #expect(DaemonLoopTiming.floorInterval(holding: false, suspended: true) == 1)
        #expect(DaemonLoopTiming.floorInterval(holding: true, suspended: true) == 1)
        #expect(DaemonLoopTiming.watchdogInterval(holding: false) == 30)
        #expect(DaemonLoopTiming.watchdogInterval(holding: true) == 5)
    }

    @Test("The active rates are unchanged from before: floor 1 s, watchdog 5 s, well inside its 15 s timeout")
    func activeRatesUnchanged() {
        #expect(DaemonLoopTiming.floorActive == 1.0)
        #expect(DaemonLoopTiming.watchdogActive == 5.0)
        #expect(DaemonLoopTiming.watchdogActive * 2 < HeartbeatWatchdog.timeout)
    }

    @Test("Even the longest idle sleep ends long before it could matter for a new hold: a poke wakes it at once")
    func pokeWakesAWaiter() {
        let gate = WakeGate()
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { gate.poke() }
        gate.wait(timeout: 30)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("A poke that arrives just before the wait begins is not lost")
    func earlyPokeIsKept() {
        let gate = WakeGate()
        gate.poke()
        let started = Date()
        gate.wait(timeout: 30)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test("A poke is consumed: the next wait sleeps for its timeout again")
    func pokeIsConsumed() {
        let gate = WakeGate()
        gate.poke()
        gate.wait(timeout: 30)       // returns at once
        let started = Date()
        gate.wait(timeout: 0.2)      // nothing poked: runs to its timeout
        #expect(Date().timeIntervalSince(started) >= 0.15)
    }

    @Test("Without a poke the wait ends at its timeout")
    func timeoutEnds() {
        let gate = WakeGate()
        let started = Date()
        gate.wait(timeout: 0.2)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 0.15)
        #expect(elapsed < 5)
    }
}
