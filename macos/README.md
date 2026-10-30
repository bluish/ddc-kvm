# Desk (macOS)

The Mac side of [ddc-kvm](../README.md), in the menu bar (macOS 26+), one
monitor icon. The panels use the system's menu bar window
material with glass controls; panels built from glass cards in a
`GlassEffectContainer` didn't open. Apple Silicon only.

| Panel | What it does |
|---|---|
| Computers | DDC/CI through `IOAVService` (input, brightness, contrast, factory colour reset); the followers go along. Ctrl+Option+Cmd+N hotkeys. |
| Picture | brightness, contrast, factory colour reset |
| Devices | every follower with its battery (last reading while it's away) |

- **Input Monitoring** is required for HID followers. The grant is tied to
  the app's designated requirement; an ad-hoc signature defaults to the
  binary's cdhash, which every rebuild changes (voiding the grant while
  System Settings still shows it on), so `build.sh` pins it to the bundle
  id. Changing the id means granting Input Monitoring again.
- It reads `~/.config/kvm/config.json` (with `"this"` set to the Mac) and,
  for the `relay` driver, `~/.config/kvm/relay.json`.
- Builds with the Command Line Tools alone, hence no `@State` (a macro whose
  plugin ships only with Xcode).
- Two SwiftUI traps it avoids: the `App` body reads no published state (scenes
  rebuilt on every change re-open their panels, whose refresh changes state
  again), and nothing writes `UserDefaults` periodically (each write notifies
  every `@AppStorage` and rebuilds the scenes). Either one spins the main thread.

```sh
sh build.sh                          # kvmctl + ~/Applications/Desk.app, opens at login
./kvmctl status
~/Applications/Desk.app/Contents/MacOS/Desk --snapshot /tmp/shots   # PNG per panel, layout only
```
