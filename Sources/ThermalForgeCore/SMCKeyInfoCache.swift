//
//  SMCKeyInfoCache.swift
//  ThermalForge
//
//  Remembers each SMC key's data size, so a repeat read costs one kernel call
//  instead of two (`readKeyInfo`, then `readBytes`).
//
//  Pure bookkeeping, no IOKit: SMCConnection owns the calls and decides what to do
//  with a miss, and the clock is passed in so this tests without waiting.
//
//  Why a cache is safe to add here: every read used to re-confirm the key and its
//  size. That guarantee is kept in a bounded form:
//    - an entry is dropped the moment any read through it fails or looks wrong,
//      and the very next read goes the full, validated way;
//    - an entry expires after `revalidateAfter`, so a size that changed is picked
//      up at the next read past that age, not never;
//    - only a key that was read successfully is ever stored. Absence is never
//      cached, so a sensor that failed once is always asked about again.
//

import Foundation

public struct SMCKeyInfoCache {
    /// How long a remembered size is trusted before the next read re-asks the SMC.
    public let revalidateAfter: TimeInterval

    private struct Entry {
        var size: UInt32
        var validatedAt: TimeInterval
    }

    private var entries: [UInt32: Entry] = [:]

    public init(revalidateAfter: TimeInterval = 600) {
        self.revalidateAfter = revalidateAfter
    }

    /// The remembered size for `key`, or nil when it's unknown or due for
    /// revalidation (the caller then takes the full path and stores the result).
    public func size(for key: UInt32, now: TimeInterval) -> UInt32? {
        guard let entry = entries[key] else { return nil }
        guard now - entry.validatedAt < revalidateAfter else { return nil }
        return entry.size
    }

    /// Remember a size that was just confirmed by a successful full-path read.
    /// A size of 0 is never stored: it isn't a readable key.
    public mutating func store(_ size: UInt32, for key: UInt32, now: TimeInterval) {
        guard size > 0 else { return }
        entries[key] = Entry(size: size, validatedAt: now)
    }

    /// Forget one key (a read through its cached size failed or looked wrong).
    public mutating func invalidate(_ key: UInt32) {
        entries[key] = nil
    }

    /// Forget everything (after wake, or when the live sensor set is re-probed).
    public mutating func invalidateAll() {
        entries.removeAll(keepingCapacity: true)
    }

    public var count: Int { entries.count }
}
