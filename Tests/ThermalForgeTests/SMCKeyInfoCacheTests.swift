//
//  SMCKeyInfoCacheTests.swift
//  ThermalForge
//

import Testing

@testable import ThermalForgeCore

@Suite("SMC key info cache")
struct SMCKeyInfoCacheTests {

    @Test("An unknown key has no remembered size")
    func unknownKey() {
        let cache = SMCKeyInfoCache()
        #expect(cache.size(for: 1, now: 0) == nil)
    }

    @Test("A stored size is returned until it is due for revalidation")
    func expiry() {
        var cache = SMCKeyInfoCache(revalidateAfter: 600)
        cache.store(4, for: 7, now: 100)
        #expect(cache.size(for: 7, now: 100) == 4)
        #expect(cache.size(for: 7, now: 699.9) == 4)
        // At exactly the limit it is due: the caller takes the full, validated path.
        #expect(cache.size(for: 7, now: 700) == nil)
        #expect(cache.size(for: 7, now: 5000) == nil)
    }

    @Test("Storing again replaces the size and restarts the clock")
    func restore() {
        var cache = SMCKeyInfoCache(revalidateAfter: 600)
        cache.store(4, for: 7, now: 0)
        cache.store(8, for: 7, now: 500)
        #expect(cache.size(for: 7, now: 1000) == 8)
        #expect(cache.size(for: 7, now: 1100) == nil)
    }

    @Test("A size of zero is never stored: it isn't a readable key")
    func zeroNotStored() {
        var cache = SMCKeyInfoCache()
        cache.store(0, for: 7, now: 0)
        #expect(cache.size(for: 7, now: 0) == nil)
        #expect(cache.count == 0)
    }

    @Test("Invalidating one key leaves the others")
    func invalidateOne() {
        var cache = SMCKeyInfoCache()
        cache.store(4, for: 1, now: 0)
        cache.store(4, for: 2, now: 0)
        cache.invalidate(1)
        #expect(cache.size(for: 1, now: 1) == nil)
        #expect(cache.size(for: 2, now: 1) == 4)
    }

    @Test("Invalidating all forgets everything")
    func invalidateAll() {
        var cache = SMCKeyInfoCache()
        cache.store(4, for: 1, now: 0)
        cache.store(8, for: 2, now: 0)
        cache.invalidateAll()
        #expect(cache.count == 0)
        #expect(cache.size(for: 1, now: 1) == nil)
    }
}
