// Desk — state for the Mac's menu bar panels: the shared monitor (DDC/CI)
// and the followers' batteries.

import AppKit
import Foundation
import IOKit.hid
import SwiftUI

final class DeskModel: ObservableObject {
    /// One instance for every scene. The App body must not read published
    /// state: scenes rebuilt on each change re-open their panels, and opening
    /// a panel refreshes, which spins SwiftUI's graph forever.
    static let shared = DeskModel()

    // Monitor
    @Published var brightness: Double = 50
    @Published var contrast: Double = 50
    @Published var monitorOK = false
    @Published var busy = false
    @Published var note = ""

    // Followers. Their last readings live in files (followerStatuses), not
    // UserDefaults: every UserDefaults write notifies all @AppStorage, which
    // invalidates the App and rebuilds every scene.
    @Published var followerList: [FollowerStatus] = []
    @Published var inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted

    @AppStorage("peripheralsFollow") var follow = true

    private let queue = DispatchQueue(label: "desk")
    private var timer: Timer?
    private var lastRefresh = Date.distantPast

    private init() {
        if !inputMonitoring { inputMonitoring = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        // Batteries for the menu bar icon; panels refresh on open.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    /// At most one refresh every 2 s, whatever asks for it.
    func refresh() {
        guard Date().timeIntervalSince(lastRefresh) > 2 else { return }
        lastRefresh = Date()
        queue.async {
            let list = followerStatuses()
            var b: (current: UInt16, max: UInt16)?, c: (current: UInt16, max: UInt16)?
            if let av = externalAVService() {
                let ddc = DDC(av: av)
                b = ddc.get(0x10)
                c = ddc.get(0x12)
            }
            let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            DispatchQueue.main.async {
                if self.inputMonitoring != access { self.inputMonitoring = access }
                if self.monitorOK != (b != nil) { self.monitorOK = b != nil }
                if let b, self.brightness != Double(b.current) { self.brightness = Double(b.current) }
                if let c, self.contrast != Double(c.current) { self.contrast = Double(c.current) }
                if self.followerList != list { self.followerList = list }
            }
        }
    }

    // MARK: Monitor

    func switchTo(_ target: String) {
        guard target != thisMachine, !busy, let m = machine(target) else { return }
        busy = true
        note = ""
        let follow = self.follow
        queue.async {
            var parts: [String] = []
            if follow {
                for (name, moved) in moveFollowers(to: target).sorted(by: { $0.key < $1.key }) {
                    parts.append("\(name) \(moved ? "moved" : "unreachable")")
                }
                usleep(100_000)
            }
            // The monitor sometimes drops an input write the Mac reports as
            // sent; writing the same input again is harmless, so send it twice.
            var ok = false
            if let av = externalAVService() {
                let ddc = DDC(av: av)
                let first = ddc.set(0x60, m.input)
                usleep(300_000)
                let second = ddc.set(0x60, m.input)
                ok = first || second
                log("monitor: input \(String(format: "0x%02x", m.input)) for \(target), writes \(first ? "ok" : "failed")/\(second ? "ok" : "failed")")
            } else {
                log("monitor: no external display service")
            }
            DispatchQueue.main.async {
                self.busy = false
                self.note = ok ? parts.joined(separator: " · ") : "monitor did not answer DDC/CI"
            }
        }
    }

    func setVCP(_ vcp: UInt8, _ value: Double) {
        queue.async { _ = externalAVService().map { DDC(av: $0).set(vcp, UInt16(value.rounded())) } }
    }

    func resetColor() { setVCP(0x08, 1) }

    func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    // MARK: Batteries

    var batteries: [FollowerStatus] { followerList.filter { $0.battery != nil } }

}

func followerIcon(_ kind: String) -> String {
    switch kind {
    case "mouse": return "computermouse"
    case "keyboard": return "keyboard"
    case "headset", "headphones": return "headphones"
    case "controller", "gamepad": return "gamecontroller"
    default: return "cable.connector"
    }
}
