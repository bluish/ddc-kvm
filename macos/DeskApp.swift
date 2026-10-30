// Desk — the Mac's menu bar panels for a shared desk: the monitor switch
// (input, brightness, contrast; the followers go along) and the followers'
// batteries. One icon each, Liquid Glass (macOS 26+).

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
            Image(systemName: "rectangle.2.swap")
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra {
            BatteriesPanel().panel("batteries")
        } label: {
            BatteryLabel()
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
        for (name, view) in [("switcher", AnyView(SwitcherPanel())), ("batteries", AnyView(BatteriesPanel()))] {
            let content = view.padding(.horizontal, 16).padding(.vertical, 14).frame(width: 320)
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
    /// Every panel: the system's own menu bar window material (Liquid Glass on
    /// macOS 26), fixed width, a refresh on open. Glass goes on the controls
    /// only, the same structure as the Agent Relay panel; panels built from
    /// glass cards in a GlassEffectContainer didn't open.
    func panel(_ name: String) -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(width: 320)
            .onAppear {
                log("panel shown: \(name)")
                DeskModel.shared.refresh()
            }
    }
}

/// A section: content, then a divider before the next one.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
        Divider()
    }
}

struct Hero: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

struct Footer: View {
    var body: some View {
        HStack {
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

func configMonitorName() -> String? {
    guard let data = try? Data(contentsOf: configURL),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return obj["monitor"] as? String
}

// MARK: - Monitor switch

struct SwitcherPanel: View {
    @ObservedObject private var model = DeskModel.shared

    var body: some View {
        VStack(spacing: 10) {
            Hero(icon: "display", title: configMonitorName() ?? "Monitor",
                 subtitle: model.monitorOK ? "Showing \(machine(thisMachine)?.label ?? thisMachine)"
                                           : "Monitor did not answer DDC/CI")

            Card {
                HStack(spacing: 6) {
                    ForEach(machines, id: \.id) { m in MachineButton(m: m) }
                }
                Toggle("Followers go along", isOn: $model.follow).toggleStyle(.switch).font(.callout)
                if !model.note.isEmpty {
                    Text(model.note).font(.caption).foregroundStyle(.secondary)
                }
                if !model.inputMonitoring {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Allow Input Monitoring so the followers can go along.").font(.caption)
                            Button("Open Privacy settings") { model.openInputMonitoringSettings() }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
            }

            Card {
                Level(title: "Brightness", value: $model.brightness) { model.setVCP(0x10, $0) }
                Level(title: "Contrast", value: $model.contrast) { model.setVCP(0x12, $0) }
                Button { model.resetColor() } label: {
                    Label("Restore factory colours", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .disabled(!model.monitorOK)

            Footer()
        }
    }
}

struct MachineButton: View {
    let m: Machine
    @ObservedObject private var model = DeskModel.shared

    var body: some View {
        let here = m.id == thisMachine
        let button = Button { model.switchTo(m.id) } label: {
            VStack(spacing: 3) {
                Image(systemName: m.icon).font(.title3)
                Text(m.label).font(.caption).lineLimit(1)
                Text("⌃⌥⌘\(m.hotkey)").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
        }
        .disabled(model.busy || here)
        if here { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.glass) }
    }
}

struct Level: View {
    let title: String
    @Binding var value: Double
    let commit: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...100, step: 5) { editing in
                if !editing { commit(value) }
            }
        }
    }
}

// MARK: - Batteries

struct BatteryLabel: View {
    @ObservedObject private var model = DeskModel.shared

    var body: some View {
        if let low = model.lowestBattery {
            HStack(spacing: 3) {
                Image(systemName: batterySymbol(low.percent, charging: low.charging))
                Text("\(low.percent)%").monospacedDigit()
            }
        } else {
            Image(systemName: "battery.0percent")
        }
    }
}

struct BatteriesPanel: View {
    @ObservedObject private var model = DeskModel.shared

    var body: some View {
        VStack(spacing: 10) {
            Hero(icon: "battery.75percent", title: "Peripherals",
                 subtitle: model.batteries.isEmpty ? "No battery readings yet"
                    : model.batteries.count == 1 ? "1 device" : "\(model.batteries.count) devices")
            if !model.batteries.isEmpty {
                Card {
                    ForEach(model.batteries) { s in BatteryRow(s: s) }
                }
            }
            Footer()
        }
    }
}

struct BatteryRow: View {
    let s: FollowerStatus
    var b: Battery { s.battery! }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: followerIcon(s.kind)).frame(width: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.name).font(.callout)
                    Text(b.charging ? "Charging" : (s.stale ? "Last reading" : "On battery"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(b.percent)%").font(.title3.weight(.semibold)).monospacedDigit()
            }
            ProgressView(value: Double(b.percent), total: 100)
                .tint(b.percent <= 20 && !b.charging ? .red : .accentColor)
        }
        .opacity(s.stale ? 0.6 : 1)
    }
}
