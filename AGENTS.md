# AGENTS.md

A software KVM in two implementations that read the same
`~/.config/kvm/config.json`: `kvm` (Linux, Go, stdlib only, `ddcutil` for
DDC/CI) and `macos/` (Swift: `kvmctl` CLI and the Desk menu bar app, DDC
through the private `IOAVService` calls). No device names, ids or machine
names belong in the code or the docs; they live in the config
(`KVM_CONFIG` overrides the path for `kvm`) and in `examples/`.

## Layout

- `main.go` (config, status, CLI), `ddc.go` (ddcutil), `hid.go` (hidraw
  lookup and timed reads), `follower.go` (followers, driver table, battery
  cache), one file per driver: `hidpp.go`, `rawhid.go`, `command.go`,
  `relay.go` (also `kvm serve`).
- `macos/KVMCore.swift`: the same pieces for macOS; `main.swift` is
  `kvmctl`; `Model.swift` and `DeskApp.swift` are the app.
- `examples/`: complete configs.

## Drivers

A driver is a `move` (and optionally a `status`) in the driver table of
both implementations, its config fields on `Driver`, and a row in the
README table. Its per-machine value lives in `hosts`. A driver that can't
reach the device returns false or nil, quickly, and never blocks the
monitor switch; the next driver gets its turn. Drivers that only make sense
on one platform are listed on the other with no functions.

## Rules

- In `switch`, followers move first and the monitor last: a device can only
  be sent away from where it is connected.
- `kvm status`, `kvm followers` and the relay endpoints are read by bar
  widgets and by Desk; keep their shape or say so in the release notes.
- Desk's bundle id stays `io.github.bluish.kvmbar`: Input Monitoring is tied
  to it.
- Two SwiftUI traps: the `App` body must not read published state, and
  nothing may write `UserDefaults` periodically; either one spins the main
  thread at 100 %.
- macOS builds with the Command Line Tools alone: no `@State` (it's a macro).

## Testing

- `go vet ./... && go build`, then `KVM_CONFIG=examples/<file>.json ./kvm
  status` and `./kvm followers` read the monitor and the followers without
  switching anything.
- `kvm input <this machine>` is a safe write: it selects the input already
  shown.
- macOS: `swiftc -O -o kvmctl KVMCore.swift main.swift` and
  `swiftc -O -parse-as-library -o Desk KVMCore.swift Model.swift Kit.swift DeskApp.swift`
  in a temp dir check the build without installing; `Desk --snapshot <dir>`
  renders the panels to PNGs.

## Commits

`type(scope): description` in English; body with why, then lowercase
bullets of what changed, then a `Validation:` line with what was actually run.
