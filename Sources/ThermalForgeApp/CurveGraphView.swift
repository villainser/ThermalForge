//
//  CurveGraphView.swift
//  ThermalForge
//
//  The curve plot: temperature across, fan speed up. Drag a point to move it, click an
//  empty spot to add one. All the editing rules (order, spacing, speed never dropping
//  as temperature rises, the point limit) live in CustomFanCurve, which this only calls,
//  so the view can't draw or produce a curve the model wouldn't accept.
//

import SwiftUI
import ThermalForgeCore

struct CurveGraphView: View {
    @Binding var curve: CustomFanCurve
    @Binding var selected: Int?
    /// The fan's hardware minimum over its maximum; the curve never goes below it.
    let minFraction: Float

    @State private var dragIndex: Int?
    @State private var dragStarted = false

    private let tMin: Float = 30
    private let tMax: Float = 100
    private let leftPad: CGFloat = 34
    private let bottomPad: CGFloat = 22
    private let topPad: CGFloat = 8
    private let rightPad: CGFloat = 10
    private let grabRadius: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                draw(context: context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in handleChanged(value, size: geo.size) }
                    .onEnded { value in handleEnded(value, size: geo.size) }
            )
        }
    }

    // MARK: - Coordinates

    private func plot(_ size: CGSize) -> CGRect {
        CGRect(x: leftPad, y: topPad,
               width: max(1, size.width - leftPad - rightPad),
               height: max(1, size.height - topPad - bottomPad))
    }

    private func viewPoint(temp: Float, percent: Float, size: CGSize) -> CGPoint {
        let r = plot(size)
        let x = r.minX + CGFloat((temp - tMin) / (tMax - tMin)) * r.width
        let y = r.maxY - CGFloat(percent / 100) * r.height
        return CGPoint(x: x, y: y)
    }

    private func value(at point: CGPoint, size: CGSize) -> (temp: Float, percent: Float) {
        let r = plot(size)
        let temp = tMin + Float((point.x - r.minX) / r.width) * (tMax - tMin)
        let percent = Float((r.maxY - point.y) / r.height) * 100
        return (temp, min(max(percent, 0), 100))
    }

    private func nearestPoint(to location: CGPoint, size: CGSize) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (i, p) in curve.points.enumerated() {
            let v = viewPoint(temp: p.temp, percent: p.percent, size: size)
            let d = hypot(v.x - location.x, v.y - location.y)
            if d <= grabRadius, d < (best?.distance ?? .infinity) { best = (i, d) }
        }
        return best?.index
    }

    // MARK: - Gestures

    private func handleChanged(_ value: DragGesture.Value, size: CGSize) {
        if !dragStarted {
            dragStarted = true
            dragIndex = nearestPoint(to: value.startLocation, size: size)
            if let i = dragIndex { selected = i }
        }
        guard let i = dragIndex else { return }
        let v = self.value(at: value.location, size: size)
        curve.movePoint(at: i, toTemp: v.temp.rounded(), toPercent: v.percent.rounded())
    }

    private func handleEnded(_ value: DragGesture.Value, size: CGSize) {
        defer {
            dragIndex = nil
            dragStarted = false
        }
        // A click that grabbed no point and barely moved adds one at that spot.
        guard dragIndex == nil, hypot(value.translation.width, value.translation.height) < 4 else { return }
        let v = self.value(at: value.location, size: size)
        let temp = v.temp.rounded()
        if curve.addPoint(temp: temp, percent: v.percent.rounded()) {
            selected = curve.points.firstIndex { abs($0.temp - temp) < 0.5 }
        }
    }

    // MARK: - Drawing

    private func draw(context: GraphicsContext, size: CGSize) {
        let r = plot(size)
        let gridColor = Color.secondary.opacity(0.25)

        // Grid and axis labels
        for t in stride(from: 30, through: 100, by: 10) {
            let x = viewPoint(temp: Float(t), percent: 0, size: size).x
            var line = Path()
            line.move(to: CGPoint(x: x, y: r.minY))
            line.addLine(to: CGPoint(x: x, y: r.maxY))
            context.stroke(line, with: .color(gridColor), lineWidth: 0.5)
            context.draw(Text("\(t)°").font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: x, y: r.maxY + 10), anchor: .center)
        }
        for p in stride(from: 0, through: 100, by: 25) {
            let y = viewPoint(temp: tMin, percent: Float(p), size: size).y
            var line = Path()
            line.move(to: CGPoint(x: r.minX, y: y))
            line.addLine(to: CGPoint(x: r.maxX, y: y))
            context.stroke(line, with: .color(gridColor), lineWidth: 0.5)
            context.draw(Text("\(p)%").font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: r.minX - 17, y: y), anchor: .center)
        }

        // The hardware minimum: the curve can't go below this line.
        let floorY = viewPoint(temp: tMin, percent: minFraction * 100, size: size).y
        var floorLine = Path()
        floorLine.move(to: CGPoint(x: r.minX, y: floorY))
        floorLine.addLine(to: CGPoint(x: r.maxX, y: floorY))
        context.stroke(floorLine, with: .color(.blue.opacity(0.6)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        context.draw(Text("min RPM").font(.caption2).foregroundStyle(.blue),
                     at: CGPoint(x: r.maxX - 26, y: floorY - 7), anchor: .center)

        // The 95 °C safety override: always above any curve, shown so it's never a surprise.
        let safetyX = viewPoint(temp: FanProfile.safetyTempThreshold, percent: 0, size: size).x
        var safety = Path()
        safety.move(to: CGPoint(x: safetyX, y: r.minY))
        safety.addLine(to: CGPoint(x: safetyX, y: r.maxY))
        context.stroke(safety, with: .color(.red.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
        context.draw(Text("95° max").font(.caption2).foregroundStyle(.red),
                     at: CGPoint(x: safetyX - 22, y: r.minY + 8), anchor: .center)

        // The effective curve: what the fans will really do, clamped to the hardware
        // range, sampled across the plot.
        var path = Path()
        let steps = max(2, Int(r.width / 3))
        for i in 0...steps {
            let temp = tMin + (tMax - tMin) * Float(i) / Float(steps)
            let fraction = curve.fraction(at: temp, minFraction: minFraction)
            let p = viewPoint(temp: temp, percent: fraction * 100, size: size)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        context.stroke(path, with: .color(.orange), lineWidth: 2)

        // The points
        for (i, point) in curve.points.enumerated() {
            let v = viewPoint(temp: point.temp, percent: point.percent, size: size)
            let isSelected = selected == i
            let radius: CGFloat = isSelected ? 7 : 5
            let rect = CGRect(x: v.x - radius, y: v.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(isSelected ? .orange : .white))
            context.stroke(Path(ellipseIn: rect), with: .color(.orange), lineWidth: 2)
        }
    }
}
