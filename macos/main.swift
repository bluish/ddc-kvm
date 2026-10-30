// kvmctl command line (see KVMCore.swift for the usage)

import Foundation

let args = CommandLine.arguments.dropFirst()
switch (args.first, args.dropFirst().first) {
case ("status", _):
    print(json(status()))
case ("followers", _):
    print(json(followerStatuses().map(statusJSON)))
case ("hid", _):
    listHID()
case ("switch", let t?) where machine(t) != nil:
    var r: [String: Any] = ["input": t]
    if t != thisMachine {
        r["followers"] = moveFollowers(to: t)
        usleep(100_000)
    }
    if let av = externalAVService() { r["monitor"] = DDC(av: av).set(0x60, machine(t)!.input) }
    print(json(r))
case ("input", let t?) where machine(t) != nil:
    guard let av = externalAVService() else { exit(1) }
    print(json(["input": t, "monitor": DDC(av: av).set(0x60, machine(t)!.input)]))
case ("follow", let t?) where machine(t) != nil:
    print(json(["followers": moveFollowers(to: t)]))
case ("brightness", let v?), ("contrast", let v?):
    guard let n = UInt16(v), let av = externalAVService() else { exit(2) }
    _ = DDC(av: av).set(args.first == "brightness" ? 0x10 : 0x12, min(n, 100))
default:
    FileHandle.standardError.write("usage: kvmctl status|switch|input|follow|followers|brightness|contrast|hid\n".data(using: .utf8)!)
    exit(2)
}
