// Desk — the Mac's menu bar panel for a shared desk: the monitor switch
// (input, brightness, contrast; the followers go along) and the followers'
// batteries, under one monitor icon.

import Carbon.HIToolbox
import SwiftUI

@main
struct DeskApp: App {
    init() {
        // `Desk --snapshot <dir>` renders the panels to PNGs and exits (layout
        // checks; ImageRenderer draws no glass and no native controls).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.render(to: args[i + 1])
        }
        // Ctrl+Option+Cmd+N: on a Windows-layout keyboard, the same keys as Super+Ctrl+Alt+N.
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5]
        for m in machines {
            let n = m.hotkey
            guard (1...digits.count).contains(n) else { continue }
            let id = m.id
            HotKeys.register(id: UInt32(n), keyCode: digits[n - 1], modifiers: controlKey | optionKey | cmdKey) {
                DeskModel.shared.switchTo(id)
            }
        }
    }

    // No published state is read here (see DeskModel.shared): only the label
    // and panel views observe the model.
    var body: some Scene {
        MenuBarExtra {
            SwitcherPanel().panel("switcher")
        } label: {
            Image(systemName: "display")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Global hotkeys through Carbon's RegisterEventHotKey (no extra permission).
enum HotKeys {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var installed = false

    static func register(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                HotKeys.actions[hk.id]?()
                return noErr
            }, 1, &spec, nil, nil)
        }
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: 0x4B564D42, id: id),
                            GetApplicationEventTarget(), 0, &ref)
        actions[id] = action
    }
}

@MainActor
enum Snapshot {
    static func render(to dir: String) {
        DeskModel.shared.refresh()
        RunLoop.main.run(until: .now.addingTimeInterval(5))
        for (name, view) in [("switcher", AnyView(SwitcherPanel()))] {
            let content = view.panelFrame()
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: content)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }
        exit(0)
    }
}

// MARK: - Shared pieces

extension View {
    func panelFrame() -> some View {
        padding(12).frame(width: Theme.width)
    }

    /// Every panel: fixed width on the system's menu bar material, a refresh
    /// on open.
    func panel(_ name: String) -> some View {
        panelFrame().onAppear {
            log("panel shown: \(name)")
            DeskModel.shared.refresh()
        }
    }
}

struct Footer<Leading: View>: View {
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 14) {
            leading
            Spacer()
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(FooterButtonStyle())
                .help("Quit Desk")
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

func configMonitorName() -> String? {
    guard let data = try? Data(contentsOf: configURL),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return obj["monitor"] as? String
}

/// A capsule slider that commits when the drag ends (each value is a DDC write).
struct LevelSlider: View {
    let title: String
    @Binding var value: Double
    let commit: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value))%").font(.system(size: 11, weight: .medium).monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    CapsuleMeter(fraction: value / 100, height: 6)
                    Circle().fill(.white).frame(width: 14, height: 14).shadow(radius: 1, y: 0.5)
                        .offset(x: max(0, min(geo.size.width - 14, geo.size.width * value / 100 - 7)))
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = Double(max(0, min(1, g.location.x / geo.size.width)))
                        value = (f * 20).rounded() * 5
                    }
                    .onEnded { _ in commit(value) })
            }
            .frame(height: 16)
        }
    }
}

/// A small on/off capsule (native toggles don't show in snapshots).
struct Switch: View {
    @Binding var isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Theme.accent : Color.primary.opacity(0.15))
            .frame(width: 32, height: 18)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white).padding(2)
            }
            .animation(.easeOut(duration: 0.15), value: isOn)
            .onTapGesture { isOn.toggle() }
    }
}

// MARK: - Monitor switch

struct SwitcherPanel: View {
    @ObservedObject private var model = DeskModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader(icon: "display", title: configMonitorName() ?? "Monitor") {
                Text(model.monitorOK ? "DDC/CI" : "not answering").font(.system(size: 11))
                    .foregroundStyle(model.monitorOK ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.bad))
            }

            SectionLabel("Computers")
            Card {
                HStack(spacing: 6) {
                    ForEach(machines, id: \.id) { m in MachineTile(m: m) }
                }
                if !followers.isEmpty {
                    HStack {
                        Text("Devices go along").font(.system(size: 12))
                        Spacer()
                        Switch(isOn: $model.follow)
                    }
                    .padding(.top, 2)
                }
                if !model.note.isEmpty {
                    Label(model.note, systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !model.inputMonitoring {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Allow Input Monitoring so devices can go along.").font(.system(size: 11))
                            Button("Open Privacy settings") { model.openInputMonitoringSettings() }
                                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                        }
                    }
                }
            }

            SectionLabel("Picture")
            Card {
                LevelSlider(title: "Brightness", value: $model.brightness) { model.setVCP(0x10, $0) }
                LevelSlider(title: "Contrast", value: $model.contrast) { model.setVCP(0x12, $0) }
                Button { model.resetColor() } label: {
                    Label("Restore factory colours", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(QuietButtonStyle())
            }
            .disabled(!model.monitorOK)
            .opacity(model.monitorOK ? 1 : 0.5)

            if !model.followerList.isEmpty {
                SectionLabel("Devices")
                Card {
                    ForEach(model.followerList) { s in FollowerRow(s: s) }
                }
            }

            Footer {
                Text("⌃⌥⌘ + number switches").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }
}

struct MachineTile: View {
    let m: Machine
    @ObservedObject private var model = DeskModel.shared

    var body: some View {
        let here = m.id == thisMachine
        Button { model.switchTo(m.id) } label: {
            VStack(spacing: 4) {
                Image(systemName: m.icon).font(.system(size: 17))
                Text(m.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text("⌃⌥⌘\(m.hotkey)").font(.system(size: 9).monospacedDigit()).opacity(0.7)
            }
            .foregroundStyle(here ? .white : .primary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(here ? Theme.accent : Color.primary.opacity(0.07), in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!model.busy && !here)
        .help(here ? "Showing now" : "Switch to \(m.label)")
        .opacity(model.busy && !here ? 0.5 : 1)
    }
}

// MARK: - Devices


func batteryColor(_ b: Battery) -> Color {
    b.charging ? Theme.good : b.percent <= 20 ? Theme.bad : Theme.accent
}

func statusText(_ s: FollowerStatus) -> String {
    guard let b = s.battery else { return "No reading yet" }
    if b.charging { return "Charging" }
    return s.stale ? "Last reading, while away" : "On battery"
}

struct FollowerRow: View {
    let s: FollowerStatus

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: followerIcon(s.kind)).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(s.name).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(s.battery.map { "\($0.percent)%" } ?? "—")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(s.battery.map(batteryColor) ?? .secondary)
                }
                if let b = s.battery {
                    CapsuleMeter(fraction: Double(b.percent) / 100, color: batteryColor(b), height: 4)
                }
                Text(statusText(s)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .opacity(s.stale ? 0.7 : 1)
    }
}
