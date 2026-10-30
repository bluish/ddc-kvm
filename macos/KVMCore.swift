// kvmctl — monitor input (DDC/CI on Apple Silicon) and the followers that go
// along with it.
//
//   kvmctl status                      JSON: machines, brightness, contrast, followers
//   kvmctl switch <machine>            move the followers there, then the monitor
//   kvmctl input <machine>             monitor only
//   kvmctl follow <machine>            followers only
//   kvmctl followers                   JSON: each follower's battery
//   kvmctl brightness|contrast <0-100>
//   kvmctl hid                         list HID interfaces (to write a follower's config)
//
// DDC uses the private IOAVService calls (as m1ddc does). Machines and
// followers come from ~/.config/kvm/config.json, the same file the Linux kvm
// reads; the drivers mirror its own (hidpp, rawhid, leds, command, relay).

import Foundation
import IOKit
import IOKit.hid

// MARK: - Config

struct Machine {
    let id: String
    let label: String
    let icon: String
    let input: UInt16  // VCP 0x60 value
    let hotkey: Int    // Ctrl+Option+Cmd+N
}

struct Driver {
    let type: String
    let raw: [String: Any]
    func host(_ machine: String) -> Any? { (raw["hosts"] as? [String: Any])?[machine] }
    var ids: [(vendor: Int, product: Int?)] {
        ((raw["ids"] as? [String]) ?? []).compactMap { id in
            let parts = id.split(separator: ":").map { Int($0, radix: 16) }
            guard let v = parts.first ?? nil else { return nil }
            return (v, parts.count > 1 ? parts[1] : nil)
        }
    }
    func int(_ key: String) -> Int? { raw[key] as? Int }
    func string(_ key: String) -> String? { raw[key] as? String }
}

struct Follower {
    let name: String
    let kind: String
    let drivers: [Driver]
}

let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/kvm/config.json")

let config: [String: Any] = (try? Data(contentsOf: configURL))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

let thisMachine = config["this"] as? String ?? ""

let machines: [Machine] = ((config["machines"] as? [[String: Any]]) ?? []).enumerated().compactMap { i, m in
    guard let id = m["id"] as? String, let inp = m["input"] else { return nil }
    let raw = "\(inp)"
    guard let input = raw.hasPrefix("0x") ? UInt16(raw.dropFirst(2), radix: 16) : UInt16(raw) else { return nil }
    return Machine(id: id, label: m["label"] as? String ?? id, icon: m["icon"] as? String ?? "display",
                   input: input, hotkey: m["hotkey"] as? Int ?? i + 1)
}

let followers: [Follower] = ((config["followers"] as? [[String: Any]]) ?? []).compactMap { f in
    guard let name = f["name"] as? String else { return nil }
    let drivers = ((f["drivers"] as? [[String: Any]]) ?? []).compactMap { d in
        (d["type"] as? String).map { Driver(type: $0, raw: d) }
    }
    return Follower(name: name, kind: f["kind"] as? String ?? "", drivers: drivers)
}

func machine(_ id: String) -> Machine? { machines.first { $0.id == id } }

// MARK: - DDC/CI (IOAVService)

typealias IOAVService = CFTypeRef
@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<IOAVService>?
@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: IOAVService, _ chip: UInt32, _ offset: UInt32,
                        _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: IOAVService, _ chip: UInt32, _ address: UInt32,
                         _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

func externalAVService() -> IOAVService? {
    var iter = io_iterator_t()
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iter) }
    while case let svc = IOIteratorNext(iter), svc != 0 {
        defer { IOObjectRelease(svc) }
        let loc = IORegistryEntryCreateCFProperty(svc, "Location" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        if loc == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, svc) {
            return av.takeRetainedValue()
        }
    }
    return nil
}

struct DDC {
    let av: IOAVService

    func write(_ payload: [UInt8]) -> Bool {
        var data = [UInt8(0x80 | payload.count)] + payload
        data.append(data.reduce(0x6E ^ 0x51) { $0 ^ $1 })
        for _ in 0..<2 {
            let r = data.withUnsafeMutableBytes { IOAVServiceWriteI2C(av, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
            if r == kIOReturnSuccess { return true }
            usleep(10_000)
        }
        return false
    }

    func get(_ vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        for _ in 0..<3 {
            guard write([0x01, vcp]) else { continue }
            usleep(40_000)
            var buf = [UInt8](repeating: 0, count: 12)
            let r = buf.withUnsafeMutableBytes { IOAVServiceReadI2C(av, 0x37, 0x51, $0.baseAddress!, 12) }
            guard r == kIOReturnSuccess else { continue }
            // Find the VCP reply: 0x02 <result 0> <vcp> <type> <maxH> <maxL> <curH> <curL>
            for i in 0..<(buf.count - 7) where buf[i] == 0x02 && buf[i + 1] == 0x00 && buf[i + 2] == vcp {
                let mx = UInt16(buf[i + 4]) << 8 | UInt16(buf[i + 5])
                let cur = UInt16(buf[i + 6]) << 8 | UInt16(buf[i + 7])
                return (cur, mx)
            }
        }
        return nil
    }

    func set(_ vcp: UInt8, _ value: UInt16) -> Bool {
        write([0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)])
    }
}

// MARK: - HID

final class HIDDev {
    let dev: IOHIDDevice
    var inbox: [[UInt8]] = []
    private var buffer = [UInt8](repeating: 0, count: 64)

    init?(vendor: Int, usagePage: Int, product: Int? = nil, name: String? = nil) {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        var match: [String: Any] = [kIOHIDVendorIDKey: vendor, kIOHIDDeviceUsagePageKey: usagePage]
        if let product { match[kIOHIDProductIDKey] = product }
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        let all = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
        guard let d = all.first(where: { name == nil
            || (IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String)?.contains(name!) == true }) else { return nil }
        dev = d
        let opened = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            // kIOReturnNotPermitted: the app needs Input Monitoring permission.
            FileHandle.standardError.write(String(format: "HID open failed: 0x%08x\n", opened).data(using: .utf8)!)
            return nil
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, &buffer, buffer.count, { ctx, _, _, _, rid, report, len in
            let me = Unmanaged<HIDDev>.fromOpaque(ctx!).takeUnretainedValue()
            // For numbered reports the buffer already starts with the report ID.
            let bytes = Array(UnsafeBufferPointer(start: report, count: len))
            me.inbox.append(bytes.first == UInt8(truncatingIfNeeded: rid) ? bytes : [UInt8(truncatingIfNeeded: rid)] + bytes)
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit { IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone)) }

    func send(_ reportID: UInt8, _ bytes: [UInt8]) -> Bool {
        var b = bytes
        return IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(reportID), &b, b.count) == kIOReturnSuccess
    }

    /// Wait for a report matching `pred`, pumping the run loop.
    func wait(_ timeout: Double, _ pred: ([UInt8]) -> Bool) -> [UInt8]? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let i = inbox.firstIndex(where: pred) { return inbox.remove(at: i) }
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
        }
        return nil
    }
}

/// Appends to ~/Library/Logs/Desk.log, so a failed switch can be explained later.
func log(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Desk.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct Battery: Equatable {
    let percent: Int
    let charging: Bool
    var stale = false  // a last reading passed on by the relay
}

// MARK: - hidpp (HID++ 2.0 over Bluetooth, device index 0xFF)

func hidppDevice(_ d: Driver) -> HIDDev? { HIDDev(vendor: 0x046D, usagePage: 0xFF43, name: d.string("device")) }

func hidpp(_ d: HIDDev, feature: UInt8, fn: UInt8, _ params: [UInt8] = [], reply: Bool = true) -> [UInt8]? {
    let sw: UInt8 = 0x0B
    var pkt = [UInt8](repeating: 0, count: 20)
    pkt[0] = 0x11; pkt[1] = 0xFF; pkt[2] = feature; pkt[3] = fn << 4 | sw
    for (i, p) in params.enumerated() { pkt[4 + i] = p }
    d.inbox.removeAll()
    guard d.send(0x11, pkt) else { return nil }
    guard reply else { return [] }
    let r = d.wait(1.0) { $0.count >= 4 && ($0[0] == 0x11 || $0[0] == 0x10) && $0[1] == 0xFF
        && (($0[2] == feature && $0[3] == pkt[3]) || $0[2] == 0xFF || $0[2] == 0x8F) }
    guard let r, r[2] == feature else { return nil }
    return Array(r[4...])
}

func hidppFeatureIndex(_ d: HIDDev, _ id: UInt16) -> UInt8? {
    guard let r = hidpp(d, feature: 0, fn: 0, [UInt8(id >> 8), UInt8(id & 0xFF)]), r[0] != 0 else { return nil }
    return r[0]
}

func hidppMove(_ drv: Driver, _ f: Follower, _ target: String) -> Bool {
    guard let channel = drv.host(target) as? Int, channel >= 1 else { log("\(f.name): no hidpp channel for \(target)"); return false }
    guard let d = hidppDevice(drv) else { log("\(f.name): HID++ device not found or not openable"); return false }
    guard let idx = hidppFeatureIndex(d, 0x1814) else { log("\(f.name): no CHANGE_HOST reply"); return false }
    log("\(f.name): CHANGE_HOST to channel \(channel)")
    return hidpp(d, feature: idx, fn: 1, [UInt8(channel - 1)], reply: false) != nil
}

/// UNIFIED_BATTERY (0x1004), or BATTERY_STATUS (0x1000) on older devices.
/// Nil unless the device is on this Mac.
func hidppStatus(_ drv: Driver, _ f: Follower) -> Battery? {
    guard let d = hidppDevice(drv) else { return nil }
    if let idx = hidppFeatureIndex(d, 0x1004), let r = hidpp(d, feature: idx, fn: 1) {
        return Battery(percent: Int(r[0]), charging: r[2] == 1 || r[2] == 2)
    }
    if let idx = hidppFeatureIndex(d, 0x1000), let r = hidpp(d, feature: idx, fn: 0) {
        return Battery(percent: Int(r[0]), charging: r[2] == 1 || r[2] == 2)
    }
    return nil
}

// MARK: - rawhid (QMK raw HID, usage page 0xFF60)

func hexBytes(_ s: String) -> [UInt8] {
    let h = s.replacingOccurrences(of: " ", with: "")
    return stride(from: 0, to: h.count - 1, by: 2).compactMap {
        UInt8(h.dropFirst($0).prefix(2), radix: 16)
    }
}

func rawhidCommand(_ drv: Driver, _ cmd: [UInt8]) -> [UInt8]? {
    for id in drv.ids {
        guard let d = HIDDev(vendor: id.vendor, usagePage: 0xFF60, product: id.product) else { continue }
        var pkt = [UInt8](repeating: 0, count: 32)
        for (i, b) in cmd.enumerated() { pkt[i] = b }
        d.inbox.removeAll()
        guard d.send(0, pkt) else { continue }
        if let r = d.wait(1.0, { r in r.count > cmd.count && r.dropFirst().starts(with: cmd.prefix(2)) }) {
            return Array(r.dropFirst())
        }
    }
    return nil
}

func rawhidMove(_ drv: Driver, _ f: Follower, _ target: String) -> Bool {
    guard let cmd = drv.host(target) as? String, let r = rawhidCommand(drv, hexBytes(cmd)) else { return false }
    guard let ok = drv.int("ok") else { return true }
    return r.count > ok && r[ok] == 1
}

func rawhidStatus(_ drv: Driver, _ f: Follower) -> Battery? {
    guard let q = drv.string("query"), let b = drv.int("battery"),
          let r = rawhidCommand(drv, hexBytes(q)), r.count > b else { return nil }
    let c = drv.int("charging")
    return Battery(percent: Int(r[b]), charging: c.map { r.count > $0 && r[$0] == 1 } ?? false)
}

// MARK: - leds (a command spelled in lock-key LEDs)

/// For firmware that listens to its LED report: some wireless links forward
/// nothing else. "arm" lights a set of LEDs, then the host's set picks the
/// target, then the LEDs used go dark again. LED names: num, caps, scroll.
func ledsMove(_ drv: Driver, _ f: Follower, _ target: String) -> Bool {
    guard let vendor = drv.ids.first?.vendor else { return false }
    guard let want = drv.host(target) as? [String] else { log("\(f.name): no LED set for \(target)"); return false }
    let arm = (drv.raw["arm"] as? [String]) ?? []
    let usages = ["num": 1, "caps": 2, "scroll": 3]
    let used = Set(arm + ((drv.raw["hosts"] as? [String: [String]]) ?? [:]).values.flatMap { $0 })
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: vendor, kIOHIDPrimaryUsagePageKey: 0x01,
                                        kIOHIDPrimaryUsageKey: 0x06] as CFDictionary)
    let devs = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
    guard let dev = devs.first(where: { (IOHIDDeviceGetProperty($0, kIOHIDTransportKey as CFString) as? String)?
              .contains("Bluetooth") == true }) else {
        log("\(f.name): not on this Mac over Bluetooth")
        return false
    }
    let opened = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
    guard opened == kIOReturnSuccess else {
        log(String(format: "\(f.name): open failed 0x%08x (Input Monitoring?)", opened))
        return false
    }
    defer { IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone)) }
    let leds = (IOHIDDeviceCopyMatchingElements(dev, [kIOHIDElementUsagePageKey: 0x08] as CFDictionary,
                                                IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]) ?? []
    var elements: [String: IOHIDElement] = [:]
    for name in used {
        guard let u = usages[name], let e = leds.first(where: { IOHIDElementGetUsage($0) == u }) else {
            log("\(f.name): no \(name) LED"); return false
        }
        elements[name] = e
    }
    func set(_ lit: [String]) -> Bool {
        var batch: [IOHIDElement: IOHIDValue] = [:]
        for (name, e) in elements {
            batch[e] = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, e, 0, lit.contains(name) ? 1 : 0)
        }
        return IOHIDDeviceSetValueMultiple(dev, batch as CFDictionary) == kIOReturnSuccess
    }
    guard set(arm) else { log("\(f.name): LED arm failed"); return false }
    usleep(150_000)
    guard set(want) else { log("\(f.name): LED target failed"); return false }
    usleep(300_000)
    _ = set([])  // nothing stale for the next time it connects here
    log("\(f.name): LED switch to \(target) sent")
    return true
}

// MARK: - command

func shell(_ cmd: String) -> (ok: Bool, out: Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    let pipe = Pipe()
    p.standardOutput = pipe
    guard (try? p.run()) != nil else { return (false, Data()) }
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus == 0, out)
}

func commandMove(_ drv: Driver, _ f: Follower, _ target: String) -> Bool {
    guard let sw = drv.string("switch"), let host = drv.host(target) as? String else { return false }
    return shell(sw.replacingOccurrences(of: "{host}", with: host).replacingOccurrences(of: "{machine}", with: target)).ok
}

func commandStatus(_ drv: Driver, _ f: Follower) -> Battery? {
    guard let cmd = drv.string("status") else { return nil }
    let r = shell(cmd)
    guard r.ok, let obj = try? JSONSerialization.jsonObject(with: r.out) as? [String: Any],
          let p = obj["battery"] as? Int else { return nil }
    return Battery(percent: p, charging: obj["charging"] as? Bool ?? false)
}

// MARK: - relay (the computer running `kvm serve`)

struct Relay {
    let url: URL
    let token: String

    static func load() -> Relay? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/kvm/relay.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let u = obj["url"].flatMap(URL.init(string:)), let t = obj["token"] else { return nil }
        return Relay(url: u, token: t)
    }

    func call(_ method: String, _ path: String, timeout: Double = 3) -> Any? {
        // Relative resolution keeps a query ("switch?target=x") intact.
        var req = URLRequest(url: URL(string: path, relativeTo: url) ?? url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let done = DispatchSemaphore(value: 0)
        var out: Any?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            out = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        return out
    }
}

func relayMove(_ drv: Driver, _ f: Follower, _ target: String) -> Bool {
    var q = URLComponents()
    q.queryItems = [URLQueryItem(name: "follower", value: f.name), URLQueryItem(name: "target", value: target)]
    log("\(f.name): asking the relay")
    return (Relay.load()?.call("POST", "switch" + (q.string ?? "")) as? [String: Any])?["moved"] as? Bool ?? false
}

func relayStatus(_ drv: Driver, _ f: Follower) -> Battery? {
    let list = Relay.load()?.call("GET", "followers") as? [[String: Any]] ?? []
    guard let s = list.first(where: { $0["name"] as? String == f.name }), let p = s["battery"] as? Int else { return nil }
    return Battery(percent: p, charging: s["charging"] as? Bool ?? false, stale: s["stale"] as? Bool ?? false)
}

// MARK: - Followers

let moves: [String: (Driver, Follower, String) -> Bool] = [
    "hidpp": hidppMove, "rawhid": rawhidMove, "leds": ledsMove, "command": commandMove, "relay": relayMove,
]
let statuses: [String: (Driver, Follower) -> Battery?] = [
    "hidpp": hidppStatus, "rawhid": rawhidStatus, "command": commandStatus, "relay": relayStatus,
]

func moveFollowers(to target: String) -> [String: Bool] {
    var moved: [String: Bool] = [:]
    for f in followers {
        moved[f.name] = f.drivers.contains { d in moves[d.type]?(d, f, target) ?? false }
    }
    return moved
}

struct FollowerStatus: Equatable, Identifiable {
    let name: String
    let kind: String
    let battery: Battery?
    let stale: Bool
    var id: String { name }
}

let followerCache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/kvm/followers")

/// Each follower's battery from the first driver that answers, or its last
/// reading (stale) while it is away.
func followerStatuses() -> [FollowerStatus] {
    followers.map { f in
        let file = followerCache.appendingPathComponent(slug(f.name) + ".json")
        if let b = f.drivers.lazy.compactMap({ d in statuses[d.type]?(d, f) }).first {
            if b.stale { return FollowerStatus(name: f.name, kind: f.kind, battery: b, stale: true) }
            try? FileManager.default.createDirectory(at: followerCache, withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: ["battery": b.percent, "charging": b.charging]).write(to: file)
            return FollowerStatus(name: f.name, kind: f.kind, battery: b, stale: false)
        }
        if let data = try? Data(contentsOf: file), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let p = obj["battery"] as? Int {
            return FollowerStatus(name: f.name, kind: f.kind, battery: Battery(percent: p, charging: obj["charging"] as? Bool ?? false), stale: true)
        }
        return FollowerStatus(name: f.name, kind: f.kind, battery: nil, stale: false)
    }
}

func slug(_ s: String) -> String {
    s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
}

// MARK: - Commands

func json(_ obj: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

func statusJSON(_ s: FollowerStatus) -> [String: Any] {
    var o: [String: Any] = ["name": s.name, "kind": s.kind]
    if let b = s.battery { o["battery"] = b.percent; o["charging"] = b.charging; o["stale"] = s.stale }
    return o
}

func status() -> [String: Any] {
    var out: [String: Any] = ["this": thisMachine, "machines": machines.map { ["id": $0.id, "label": $0.label] }]
    if let av = externalAVService() {
        let ddc = DDC(av: av)
        out["input"] = thisMachine
        if let b = ddc.get(0x10) { out["brightness"] = Int(b.current) }
        if let c = ddc.get(0x12) { out["contrast"] = Int(c.current) }
    }
    out["followers"] = followerStatuses().map(statusJSON)
    return out
}

func listHID() {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, nil)
    for d in (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? [] {
        func p(_ k: String) -> Any { IOHIDDeviceGetProperty(d, k as CFString) ?? "-" }
        print(p(kIOHIDProductKey), String(format: "id=%04X:%04X page=%04x usage=%04x transport=%@",
              p(kIOHIDVendorIDKey) as? Int ?? 0, p(kIOHIDProductIDKey) as? Int ?? 0,
              p(kIOHIDPrimaryUsagePageKey) as? Int ?? 0, p(kIOHIDPrimaryUsageKey) as? Int ?? 0,
              "\(p(kIOHIDTransportKey))"))
    }
}
