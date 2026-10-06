//
//  CurveEditorView.swift
//  ThermalForge
//
//  Create, edit and delete custom fan curves. The list on the left is every saved
//  curve; the editor on the right works on a draft that only reaches disk on Save.
//  Nothing here decides what a valid curve is: CustomFanCurve does, and Save is
//  disabled until it has no problems, so an invalid curve can't be stored or applied.
//

import SwiftUI
import ThermalForgeCore

struct CurveEditorView: View {
    @EnvironmentObject var appState: AppState

    @State private var selectedID: String?
    @State private var draft = CustomFanCurve.example(name: "Custom curve 1")
    @State private var selectedPoint: Int?
    @State private var message: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 190)
            Divider()
            editor
        }
        .onAppear {
            if let first = appState.customCurves.first {
                load(first)
            } else {
                startNew()
            }
        }
        .onChange(of: selectedID) { _, id in
            if let id, let curve = appState.customCurves.first(where: { $0.id == id }) {
                load(curve)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selectedID) {
                ForEach(appState.customCurves) { curve in
                    HStack {
                        Text(curve.name)
                        Spacer()
                        if appState.activeProfile.id == curve.id {
                            Image(systemName: "fan.fill").foregroundStyle(.orange)
                        }
                    }
                    .tag(curve.id)
                }
            }
            Divider()
            HStack {
                Button(action: startNew) {
                    Label("New curve", systemImage: "plus")
                }
                Spacer()
            }
            .padding(8)
        }
    }

    // MARK: - Editor

    private var currentErrors: [CurveValidationError] { draft.validate() }

    private var isSaved: Bool {
        appState.customCurves.contains { $0.id == draft.id }
    }

    private var minFraction: Float {
        let limits = appState.fanLimits
        return limits.maxRPM > 0 ? limits.minRPM / limits.maxRPM : 0.3
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                if appState.activeProfile.id == draft.id {
                    Label("Active", systemImage: "fan.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            CurveGraphView(curve: $draft, selected: $selectedPoint, minFraction: minFraction)
                .frame(minHeight: 200)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))

            Text("Drag a point to move it. Click an empty spot to add one. 0% means the fan's minimum RPM. The red line is the 95° safety limit: it overrides every curve.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            pointEditor

            Divider()

            parameters

            if !currentErrors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(currentErrors.enumerated()), id: \.offset) { _, error in
                        Text(error.description)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } else if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if isSaved {
                    Button(role: .destructive, action: deleteDraft) {
                        Label("Delete", systemImage: "trash")
                    }
                }
                Spacer()
                Button("Save", action: { save(apply: false) })
                    .disabled(!currentErrors.isEmpty)
                Button("Save & use") { save(apply: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!currentErrors.isEmpty)
            }
        }
        .padding(14)
    }

    // MARK: - Selected point

    @ViewBuilder
    private var pointEditor: some View {
        if let i = selectedPoint, draft.points.indices.contains(i) {
            let rpm = draft.rpm(at: draft.points[i].temp,
                                minRPM: appState.fanLimits.minRPM,
                                maxRPM: appState.fanLimits.maxRPM)
            HStack(spacing: 16) {
                Stepper(value: tempBinding(i), in: CustomFanCurve.minTemp...CustomFanCurve.maxTemp, step: 1) {
                    Text("Temperature  \(Int(draft.points[i].temp)) °C")
                        .monospacedDigit()
                }
                Stepper(value: percentBinding(i), in: 0...100, step: 5) {
                    Text("Speed  \(Int(draft.points[i].percent))%  (≈ \(Int(rpm)) RPM)")
                        .monospacedDigit()
                }
                Button("Remove point") {
                    if draft.removePoint(at: i) { selectedPoint = nil }
                }
                .disabled(draft.points.count <= CustomFanCurve.minPoints)
            }
        } else {
            Text("Select a point to edit it precisely.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func tempBinding(_ i: Int) -> Binding<Float> {
        Binding(
            get: { draft.points.indices.contains(i) ? draft.points[i].temp : 0 },
            set: { value in
                guard draft.points.indices.contains(i) else { return }
                draft.movePoint(at: i, toTemp: value, toPercent: draft.points[i].percent)
            }
        )
    }

    private func percentBinding(_ i: Int) -> Binding<Float> {
        Binding(
            get: { draft.points.indices.contains(i) ? draft.points[i].percent : 0 },
            set: { value in
                guard draft.points.indices.contains(i) else { return }
                draft.movePoint(at: i, toTemp: draft.points[i].temp, toPercent: value)
            }
        )
    }

    // MARK: - Smoothing parameters

    private var parameters: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SMOOTHING")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ParameterSlider(
                title: "Hysteresis",
                value: $draft.hysteresisC,
                range: CustomFanCurve.hysteresisRange, step: 0.5,
                label: { String(format: "%.1f °C", $0) },
                help: "A cooling reading within this band doesn't lower the fans."
            )
            ParameterSlider(
                title: "Cool-down delay",
                value: $draft.coolDownDelaySec,
                range: CustomFanCurve.coolDownDelayRange, step: 1,
                label: { "\(Int($0)) s" },
                help: "How long it must stay cooler before the fans follow it down."
            )
            ParameterSlider(
                title: "Speed-up limit",
                value: percentPerSecond($draft.rampUpPerSec),
                range: (CustomFanCurve.rampUpRange.lowerBound * 100)...(CustomFanCurve.rampUpRange.upperBound * 100),
                step: 1,
                label: { "\(Int($0))%/s" },
                help: "Fastest the fans may speed up (lifted at 85 °C and above)."
            )
            ParameterSlider(
                title: "Slow-down limit",
                value: percentPerSecond($draft.rampDownPerSec),
                range: (CustomFanCurve.rampDownRange.lowerBound * 100)...(CustomFanCurve.rampDownRange.upperBound * 100),
                step: 0.5,
                label: { String(format: "%.1f%%/s", $0) },
                help: "Fastest the fans may slow down."
            )
        }
    }

    /// A fraction-per-second binding shown as percent-per-second.
    private func percentPerSecond(_ fraction: Binding<Float>) -> Binding<Float> {
        Binding(
            get: { fraction.wrappedValue * 100 },
            set: { fraction.wrappedValue = $0 / 100 }
        )
    }

    // MARK: - Actions

    private func load(_ curve: CustomFanCurve) {
        draft = curve
        selectedID = curve.id
        selectedPoint = nil
        message = nil
    }

    private func startNew() {
        draft = CustomFanCurve.example(name: "Custom curve \(appState.customCurves.count + 1)")
        selectedID = nil
        selectedPoint = nil
        message = nil
    }

    private func save(apply: Bool) {
        do {
            let saved = try appState.saveCurve(draft)
            draft = saved
            selectedID = saved.id
            message = apply ? "Saved and in use." : "Saved."
            if apply { appState.selectCustom(saved) }
        } catch {
            message = "Couldn't save: \(error)"
        }
    }

    private func deleteDraft() {
        let id = draft.id
        appState.deleteCurve(id: id)
        if let first = appState.customCurves.first {
            load(first)
        } else {
            startNew()
        }
    }
}

// MARK: - Slider row

private struct ParameterSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let step: Float
    let label: (Float) -> String
    let help: String

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 120, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text(label(value))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
        .help(help)
    }
}
