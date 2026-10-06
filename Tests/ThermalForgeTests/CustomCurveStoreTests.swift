//
//  CustomCurveStoreTests.swift
//  ThermalForge
//
//  Saving, editing, listing and deleting custom curves on disk, and what happens to files
//  that are damaged, hand-edited or not what they claim to be. Every test works in its
//  own temporary folder, never the user's real Application Support.
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Custom curve store")
struct CustomCurveStoreTests {

    /// A store in a fresh temporary base folder. The caller removes `base` when done.
    private func makeStore() throws -> (store: CustomCurveStore, base: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("tf-curves-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = CustomCurveStore(base: base, components: ["curves"], files: UserFiles(owner: nil))
        return (store, base)
    }

    private func curvesFolder(_ base: URL) -> URL {
        base.appendingPathComponent("curves", isDirectory: true)
    }

    // MARK: - Save and load

    @Test("A saved curve loads back identical")
    func saveAndLoad() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let curve = CustomFanCurve.example(name: "Desk")
        try store.save(curve)
        #expect(store.loadAll() == [curve])
    }

    @Test("Several curves can be kept, and they list sorted by name")
    func severalCurves() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        for name in ["Gaming", "audio", "Desk"] {
            try store.save(CustomFanCurve.example(name: name))
        }
        #expect(store.loadAll().map(\.name) == ["audio", "Desk", "Gaming"])
    }

    @Test("Saving the same id again edits that curve instead of adding another")
    func editInPlace() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        var curve = CustomFanCurve.example(name: "Desk")
        try store.save(curve)
        curve.name = "Desk (quiet)"
        curve.points[1].percent = 20
        try store.save(curve)

        let loaded = store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "Desk (quiet)")
        #expect(loaded.first?.points[1].percent == 20)
    }

    @Test("save() returns the normalized curve that was actually written")
    func saveReturnsNormalized() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        var curve = CustomFanCurve.example()
        curve.name = "  Padded  "
        let saved = try store.save(curve)
        #expect(saved.name == "Padded")
        #expect(store.loadAll().first?.name == "Padded")
    }

    @Test("An empty or missing folder loads as no curves")
    func emptyFolder() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(store.loadAll().isEmpty)
    }

    // MARK: - Delete

    @Test("A curve can be deleted; deleting one that isn't there is not an error")
    func delete() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let a = CustomFanCurve.example(name: "A")
        let b = CustomFanCurve.example(name: "B")
        try store.save(a)
        try store.save(b)

        try store.delete(id: a.id)
        #expect(store.loadAll() == [b])
        try store.delete(id: a.id)              // already gone
        #expect(store.loadAll() == [b])
    }

    @Test("delete() accepts only a well-formed custom id, so it can't be aimed at another file")
    func deleteRefusesOtherNames() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        for bad in ["../x", "silent", "balanced", "custom-", "custom-A", ""] {
            #expect(throws: CustomCurveStoreError.self) { try store.delete(id: bad) }
        }
    }

    // MARK: - Refusing and skipping

    @Test("An invalid curve is refused and nothing is written")
    func invalidCurveRefused() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let onePoint = CustomFanCurve(name: "Bad", points: [CurvePoint(temp: 50, percent: 30)])
        #expect(throws: CustomCurveStoreError.self) { try store.save(onePoint) }

        var builtInId = CustomFanCurve.example()
        builtInId.id = "balanced"
        #expect(throws: CustomCurveStoreError.self) { try store.save(builtInId) }

        #expect(store.loadAll().isEmpty)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: curvesFolder(base).path)) ?? []
        #expect(files.isEmpty)
    }

    @Test("Damaged, invalid and misnamed files are skipped and reported; good ones still load")
    func skipsBadFiles() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let good = CustomFanCurve.example(name: "Good")
        try store.save(good)

        let folder = curvesFolder(base)
        // Not JSON at all.
        try Data("not json".utf8).write(to: folder.appendingPathComponent("custom-garbage1.json"))
        // Valid JSON, but only one point.
        let onePoint = #"{"id":"custom-onepoint","name":"One","points":[{"temp":50,"percent":30}]}"#
        try Data(onePoint.utf8).write(to: folder.appendingPathComponent("custom-onepoint.json"))
        // A fine curve under the wrong file name.
        let misnamed = #"{"id":"custom-realname","name":"Misnamed","points":[{"temp":45,"percent":0},{"temp":85,"percent":100}]}"#
        try Data(misnamed.utf8).write(to: folder.appendingPathComponent("custom-other.json"))
        // Not a .json file: ignored without comment.
        try Data("x".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        var skipped: [String] = []
        let loaded = store.loadAll { skipped.append($0) }

        #expect(loaded == [good])
        #expect(skipped.count == 3)
        #expect(skipped.contains { $0.hasPrefix("custom-garbage1.json") })
        #expect(skipped.contains { $0.hasPrefix("custom-onepoint.json") })
        #expect(skipped.contains { $0.hasPrefix("custom-other.json") })
    }

    @Test("A hand-edited file whose speed drops as temperature rises is repaired on load, not trusted")
    func decreasingSpeedIsRepaired() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: curvesFolder(base), withIntermediateDirectories: true)
        let json = #"{"id":"custom-handmade","name":"Hand","points":[{"temp":50,"percent":60},{"temp":70,"percent":20},{"temp":90,"percent":100}]}"#
        try Data(json.utf8).write(to: curvesFolder(base).appendingPathComponent("custom-handmade.json"))

        let loaded = store.loadAll()
        #expect(loaded.count == 1)
        // 70° was lower than 50°: raised, so the fans never slow down as it gets hotter.
        #expect(loaded.first?.points.map(\.percent) == [60, 60, 100])
        #expect(loaded.first?.validate().isEmpty == true)
    }

    @Test("A point above the 95 °C safety limit in a hand-edited file is clamped below it")
    func pointAboveSafetyLimitIsClamped() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: curvesFolder(base), withIntermediateDirectories: true)
        let json = #"{"id":"custom-toohot","name":"Hot","points":[{"temp":50,"percent":30},{"temp":120,"percent":100}]}"#
        try Data(json.utf8).write(to: curvesFolder(base).appendingPathComponent("custom-toohot.json"))

        let last = store.loadAll().first?.points.last
        #expect(last?.temp == CustomFanCurve.maxTemp)
        #expect((last?.temp ?? 200) < FanProfile.safetyTempThreshold)
    }

    @Test("The store's directory is under the base, at the components given")
    func directory() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(store.directory.path == curvesFolder(base).path)
    }
}
