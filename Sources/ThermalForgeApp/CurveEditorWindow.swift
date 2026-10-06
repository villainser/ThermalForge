//
//  CurveEditorWindow.swift
//  ThermalForge
//
//  Opens the fan-curve editor in its own window.
//
//  A plain NSWindow rather than a SwiftUI `Window` scene: in a menu-bar-only app a
//  `Window` scene can open by itself at launch on macOS 14, and this one should appear
//  only when asked for. One window at a time; asking again brings it to the front.
//

import AppKit
import SwiftUI

@MainActor
final class CurveEditorWindow {
    static let shared = CurveEditorWindow()

    private var window: NSWindow?

    private init() {}

    func show(appState: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let hosting = NSHostingController(rootView: CurveEditorView().environmentObject(appState))
        let window = NSWindow(contentViewController: hosting)
        window.title = "ThermalForge — Fan Curves"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 540))
        window.minSize = NSSize(width: 640, height: 480)
        // Keep the window object (and the editor's state) when it's closed, so reopening
        // is instant and an unsaved draft isn't silently dropped by a stray click.
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        // A menu-bar-only app isn't frontmost by default; without this the window can
        // open behind whatever the user was working in.
        NSApp.activate()
    }
}
