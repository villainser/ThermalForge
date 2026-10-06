//
//  CustomCurveStore.swift
//  ThermalForge
//
//  Where custom fan curves live on disk: one JSON file per curve under
//  ~/Library/Application Support/ThermalForge/curves/<id>.json. Saving goes through
//  UserFiles (write beside, then rename; nothing is followed through a symlink), the
//  same path calibration data takes, so a curve saved under sudo still belongs to the
//  user whose menu bar app reads it.
//
//  Nothing loaded from disk is trusted: every file is decoded, normalized (sorted,
//  clamped, speed forced not to decrease with temperature) and validated, and the
//  file's name has to match the curve's id. A file that fails any of that is skipped
//  and reported, never half-applied.
//

import Foundation

public enum CustomCurveStoreError: Error, CustomStringConvertible, Equatable {
    case invalid([CurveValidationError])

    public var description: String {
        switch self {
        case .invalid(let errors):
            return errors.map { $0.description }.joined(separator: " ")
        }
    }
}

public struct CustomCurveStore {
    private let base: URL
    private let components: [String]
    private let files: UserFiles

    /// Tests pass a temporary `base`; production uses the user's Application Support.
    public init(base: URL = UserDataLocation.current.home,
                components: [String] = UserDataLocation.appSupportComponents + ["curves"],
                files: UserFiles = UserDataLocation.current.files) {
        self.base = base
        self.components = components
        self.files = files
    }

    public var directory: URL {
        components.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// Every curve on disk that decodes and validates, sorted by name. `onSkip` is told
    /// about each file left out, with the reason.
    public func loadAll(onSkip: (String) -> Void = { _ in }) -> [CustomFanCurve] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else {
            return []
        }

        var curves: [CustomFanCurve] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension == "json" {
            let fileName = url.lastPathComponent
            guard let data = try? files.readFile(base: base, components, name: fileName) else {
                onSkip("\(fileName): couldn't be read")
                continue
            }
            guard let decoded = try? JSONDecoder().decode(CustomFanCurve.self, from: data) else {
                onSkip("\(fileName): not a valid curve file")
                continue
            }
            let curve = decoded.normalized()
            let errors = curve.validate()
            guard errors.isEmpty else {
                onSkip("\(fileName): \(errors.map { $0.description }.joined(separator: " "))")
                continue
            }
            guard url.deletingPathExtension().lastPathComponent == curve.id else {
                onSkip("\(fileName): file name doesn't match the curve id")
                continue
            }
            curves.append(curve)
        }
        curves.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return curves
    }

    /// Save (create or replace) a curve. The curve is normalized first and refused if
    /// it still has problems; nothing invalid reaches the disk.
    @discardableResult
    public func save(_ curve: CustomFanCurve) throws -> CustomFanCurve {
        let clean = curve.normalized()
        let errors = clean.validate()
        guard errors.isEmpty else { throw CustomCurveStoreError.invalid(errors) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(clean)
        try files.writeFile(base: base, components, name: "\(clean.id).json", data: data)
        return clean
    }

    /// Delete a curve by id. Only a well-formed custom id is accepted, so this can never
    /// be pointed at another file.
    public func delete(id: String) throws {
        guard CustomFanCurve.isValidID(id) else { throw CustomCurveStoreError.invalid([.invalidID]) }
        try files.removeFile(base: base, components, name: "\(id).json")
    }
}
