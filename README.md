# ddc-kvm

A software KVM for one monitor shared by several computers. `kvm` switches
the monitor's input over **DDC/CI** and sends **followers** (a mouse, a
keyboard, a headset, anything that can change host on request) to the same
computer. Linux (`kvm`, Go, no dependencies besides `ddcutil`) and macOS
(**Desk**, a menu bar app, plus `kvmctl`, in Swift), reading the same config.

```sh
kvm status                 # machines, brightness, contrast, mode, followers
kvm switch <machine>       # followers, then the monitor
kvm input <machine>        # monitor only
kvm follow <machine>       # followers only
kvm followers              # each follower's battery, when a driver can read it
kvm hotkey <n>             # switch to the machine with that number
kvm brightness 70; kvm contrast 75; kvm mode <name>
kvm reset-color            # factory colour settings (VCP 08), input and OSD untouched
```

The monitor switch works with any monitor that takes DDC/CI. Followers are
optional.

## Followers

A follower is a device with one or more **drivers**, tried in order until
one reaches it. Each driver has `hosts`, mapping every machine id to what
that driver sends for it.

| Driver | Reaches | `hosts` values | Battery |
|---|---|---|---|
| `hidpp` | HID++ 2.0 devices with host switching (Easy-Switch), through a USB receiver on Linux, over Bluetooth on macOS | the device's channel, 1-based | macOS (on Linux the kernel reports it to UPower) |
| `rawhid` | firmware with a raw HID command for switching hosts (QMK's raw HID, usage page 0xFF60) | the command, in hex | with `query`, `battery` and `charging` byte offsets in the reply |
| `leds` | firmware that takes a command through lock-key LEDs, for wireless links that forward nothing else; macOS only | the LEDs (`num`, `caps`, `scroll`) lit after `arm` | — |
| `command` | anything a program can switch | text for `{host}` in `switch` | `status` prints `{"battery": 0-100, "charging": bool}` |
| `relay` | a follower only another computer reaches, through its `kvm serve` | — | from that computer |

A device can only be sent away from the computer it is connected to, so
each computer runs kvm or Desk, and `switch` moves the followers before the
monitor.

```json
"followers": [
  {
    "name": "Mouse",
    "kind": "mouse",
    "drivers": [{ "type": "hidpp", "device": "MX", "hosts": { "desktop": 1, "laptop": 2 } }]
  },
  {
    "name": "Keyboard",
    "kind": "keyboard",
    "drivers": [{ "type": "command", "switch": "my-keyboard-tool host {host}", "hosts": { "desktop": "usb", "laptop": "bt1" } }]
  }
]
```

| Field | Meaning |
|---|---|
| `name` | shown in `status`, Desk and widgets; also picks the follower in the relay |
| `kind` | free text for front ends (`mouse`, `keyboard`, `headset`, ...) |
| `hidpp.device` | substring of the device name, to pick it among others on the receiver |
| `hidpp.receivers` | receiver ids (`vendor:product`, hex); defaults to the common Bolt and Unifying ones |
| `rawhid.ids` | `vendor:product` ids to try in order (cable, then dongle) |
| `rawhid.ok` | reply byte that is 1 on success; any reply counts without it |
| `leds.ids` | the keyboard's vendor id (first entry) |
| `leds.arm` | LEDs lit first, so the firmware knows a command follows |

To find ids: `ls /sys/class/hidraw` and
`cat /sys/class/hidraw/hidraw*/device/uevent` on Linux, `kvmctl hid` on
macOS.

## Config

`~/.config/kvm/config.json` (`KVM_CONFIG` overrides it), the same file on
every computer except for `"this"`. Start from [`examples/`](examples).

| Field | Meaning |
|---|---|
| `this` | which machine this computer is |
| `monitor` | model name as `ddcutil detect` shows it |
| `modes` | optional picture modes for `kvm mode`, as VCP 0xDC values (`ddcutil capabilities` lists them) |
| `followers` | above |
| `relay` | `{"listen": "tailscale" or an address, "port": 8765}` for `kvm serve` |
| `machines[].input` | VCP 0x60 value of that machine's port (`ddcutil capabilities` lists them) |
| `machines[].hotkey` | hotkey number; defaults to its position in the list |
| `machines[].icon` | SF Symbol for Desk |

**Many monitors read back the same input over DDC/CI** whatever is shown,
so `kvm status` reports "this machine" as the current input: whoever is
looking at it is looking at this computer. Writes work, but some monitors
drop one now and then, so `kvm` writes the input twice, 300 ms apart.

## Hotkeys

`kvm hotkey <n>` switches to the machine with that number; bind it in your
desktop's keyboard shortcuts. Desk registers Ctrl+Option+Cmd+N on macOS:
on a keyboard with a Windows layout, those are the same keys as
Super+Ctrl+Alt+N. Numbering the machines like a mouse's channel buttons
makes both agree.

## Relay

Some followers are reachable from one computer only (a keyboard whose raw
HID works through its dongle, not over Bluetooth). `kvm serve` (the
`kvm-serve` user service) exposes `GET /followers` and
`POST /switch?follower=<name>&target=<machine>` on one address (the tailnet
one by default) with a bearer token from `~/.config/kvm/token`, created on
first start. The other computers put `{"type": "relay"}` last in that
follower's drivers and get a `~/.config/kvm/relay.json`
([example](examples/relay.json)).

## Install

```sh
sh install.sh                                  # Linux: builds with Go; then write the config
systemctl --user enable --now kvm-serve        # optional relay
sh macos/build.sh                              # macOS: kvmctl + ~/Applications/Desk.app
```

`kvm status` and `kvm followers` print JSON for bars and widgets.

## Examples

- [`monitor-only.json`](examples/monitor-only.json): just the input switch.
- [`three-computers-hidpp-mouse-qmk-keyboard.json`](examples/three-computers-hidpp-mouse-qmk-keyboard.json):
  a Linux PC and two Macs; a HID++ mouse, and a QMK keyboard with a custom
  raw HID command and an LED channel for Bluetooth, relayed by the PC.

## License

MIT
