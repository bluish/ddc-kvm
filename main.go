// kvm switches a shared monitor's input over DDC/CI and sends any configured
// followers (mice, keyboards, ...) to the same computer.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
)

const usage = `kvm: switch a shared monitor's input over DDC/CI; followers (mouse, keyboard, ...) go along.

Machines and followers are defined in ~/.config/kvm/config.json (see examples/).

Usage: kvm status                 JSON: machines, brightness, contrast, mode, followers
       kvm switch <machine>       move the followers there, then the monitor
       kvm hotkey <n>             switch to the machine with that hotkey number
       kvm input <machine>        monitor only
       kvm follow <machine>       followers only
       kvm followers              JSON: each follower's battery (last reading while away)
       kvm brightness <0-100>
       kvm contrast <0-100>
       kvm mode <name>            picture mode, from "modes" in the config (VCP 0xDC)
       kvm reset-color            restore the monitor's factory colour settings (VCP 08)
       kvm serve                  HTTP relay for computers that can't reach a follower`

type Machine struct {
	ID     string `json:"id"`
	Label  string `json:"label"`
	Input  string `json:"input"`
	Hotkey int    `json:"hotkey"`
}

type Config struct {
	This      string      `json:"this"`
	Monitor   string      `json:"monitor"`
	Modes     []Mode      `json:"modes"`
	Followers []Follower  `json:"followers"`
	Relay     RelayConfig `json:"relay"`
	Machines  []Machine   `json:"machines"`
}

// Mode is a picture mode, a VCP 0xDC value.
type Mode struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

func modeValue(name string) (int, bool) {
	for _, m := range cfg.Modes {
		if m.Name == name {
			n, err := hexOrInt(m.Value)
			return n, err == nil
		}
	}
	return 0, false
}

type RelayConfig struct {
	Listen string `json:"listen"`
	Port   int    `json:"port"`
}

var (
	home       = os.Getenv("HOME")
	configFile = envOr("KVM_CONFIG", filepath.Join(home, ".config/kvm/config.json"))
	cfg        Config
)

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "kvm: "+format+"\n", a...)
	os.Exit(1)
}

func loadConfig() {
	raw, err := os.ReadFile(configFile)
	if err != nil {
		fail("can't read %s: %v", configFile, err)
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		fail("%s: %v", configFile, err)
	}
	if machine(cfg.This) == nil {
		fail(`config needs "this" set to one of its machines`)
	}
	if cfg.Monitor == "" {
		fail(`config needs "monitor", the model as ddcutil detect shows it`)
	}
	for i := range cfg.Machines {
		if cfg.Machines[i].Hotkey == 0 {
			cfg.Machines[i].Hotkey = i + 1
		}
	}
	for _, f := range cfg.Followers {
		if f.Name == "" {
			fail("every follower needs a name")
		}
		for _, d := range f.Drivers {
			if _, ok := drivers[d.Type]; !ok {
				fail("follower %s: unknown driver %q", f.Name, d.Type)
			}
		}
	}
	if cfg.Relay.Listen == "" {
		cfg.Relay.Listen = "tailscale"
	}
	if cfg.Relay.Port == 0 {
		cfg.Relay.Port = 8765
	}
}

func machine(id string) *Machine {
	for i := range cfg.Machines {
		if cfg.Machines[i].ID == id {
			return &cfg.Machines[i]
		}
	}
	return nil
}

func machineForHotkey(n string) *Machine {
	for i, m := range cfg.Machines {
		if strconv.Itoa(m.Hotkey) == n {
			return &cfg.Machines[i]
		}
	}
	return nil
}

// hexOrInt parses "0x11" or "17".
func hexOrInt(s string) (int, error) {
	v, err := strconv.ParseInt(s, 0, 32)
	return int(v), err
}

func printJSON(v any) {
	out, _ := json.Marshal(v)
	fmt.Println(string(out))
}

func status() map[string]any {
	vcps := []string{"10", "12"}
	if len(cfg.Modes) > 0 {
		vcps = append(vcps, "DC")
	}
	vals := getVCP(vcps...)
	machines := []map[string]string{}
	for _, m := range cfg.Machines {
		label := m.Label
		if label == "" {
			label = m.ID
		}
		machines = append(machines, map[string]string{"id": m.ID, "label": label})
	}
	modes := []string{}
	var current any
	for _, m := range cfg.Modes {
		modes = append(modes, m.Name)
		if n, ok := modeValue(m.Name); ok && vals["DC"] != nil && *vals["DC"] == n {
			current = m.Name
		}
	}
	return map[string]any{
		"machines":  machines,
		"modes":     modes,
		"followers": followerStatuses(false),
		// Many monitors don't report the input reliably; whoever is looking
		// at this is looking at this machine.
		"input":      cfg.This,
		"brightness": vals["10"],
		"contrast":   vals["12"],
		"mode":       current,
		"this":       cfg.This,
	}
}

// switchTo moves the followers first: a device can only be sent away from
// the computer it is connected to, and that is this one until the monitor
// changes.
func switchTo(target string) map[string]any {
	moved := moveFollowers(target)
	setInput(target)
	return map[string]any{"input": target, "followers": moved}
}

func main() {
	loadConfig()
	args := os.Args[1:]
	cmd, target := "", ""
	if len(args) > 0 {
		cmd = args[0]
	}
	if len(args) > 1 {
		target = args[1]
	}
	isMachine := machine(target) != nil
	switch {
	case cmd == "status":
		printJSON(status())
	case cmd == "switch" && isMachine:
		printJSON(switchTo(target))
	case cmd == "hotkey" && machineForHotkey(target) != nil:
		printJSON(switchTo(machineForHotkey(target).ID))
	case cmd == "input" && isMachine:
		setInput(target)
		printJSON(map[string]string{"input": target})
	case cmd == "follow" && isMachine:
		printJSON(map[string]any{"followers": moveFollowers(target)})
	case cmd == "followers":
		printJSON(followerStatuses(false))
	case (cmd == "brightness" || cmd == "contrast") && target != "":
		n, err := strconv.Atoi(target)
		if err != nil {
			fail("%s takes 0-100", cmd)
		}
		vcp := map[string]string{"brightness": "10", "contrast": "12"}[cmd]
		ddcutil("setvcp", vcp, strconv.Itoa(max(0, min(100, n))))
	case cmd == "mode" && target != "":
		n, ok := modeValue(target)
		if !ok {
			fail("no mode %q in the config", target)
		}
		ddcutil("setvcp", "DC", fmt.Sprintf("x%02x", n))
	case cmd == "reset-color":
		// Colour only: input, OSD and HDR settings stay (VCP 04 would reset all).
		ddcutil("setvcp", "08", "1")
	case cmd == "serve":
		serve()
	default:
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
}
