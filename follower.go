package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Follower is a device that goes to the target machine with the monitor.
// Its drivers are tried in order until one reaches it.
type Follower struct {
	Name    string   `json:"name"`
	Kind    string   `json:"kind"` // free text for front ends: mouse, keyboard, ...
	Drivers []Driver `json:"drivers"`
}

// Driver is one way to reach a follower. Hosts maps each machine id to what
// the driver sends for it; its shape depends on the driver.
type Driver struct {
	Type  string                     `json:"type"`
	Hosts map[string]json.RawMessage `json:"hosts"`

	// hidpp
	Device    string   `json:"device"`
	Receivers []string `json:"receivers"`

	// rawhid; ids are also the vendor for leds
	IDs      []string `json:"ids"`
	OK       *int     `json:"ok"`
	Query    string   `json:"query"`
	Battery  *int     `json:"battery"`
	Charging *int     `json:"charging"`

	// leds (macOS only)
	Arm []string `json:"arm"`

	// command
	Switch string `json:"switch"`
	Status string `json:"status"`
}

// Battery is a follower's last known charge.
type Battery struct {
	Percent  int  `json:"battery"`
	Charging bool `json:"charging"`
	Stale    bool `json:"-"` // a last reading passed on by the relay
}

type driverImpl struct {
	move   func(d Driver, f Follower, target string) bool
	status func(d Driver, f Follower) *Battery
}

var drivers = map[string]driverImpl{
	"hidpp":   {move: hidppMove},
	"rawhid":  {move: rawhidMove, status: rawhidStatus},
	"leds":    {}, // the LED channel needs macOS (Desk); Linux skips it
	"command": {move: commandMove, status: commandStatus},
	"relay":   {move: relayMove, status: relayStatus},
}

// host decodes the driver's value for a machine; false when it has none.
func (d Driver) host(target string, v any) bool {
	raw, ok := d.Hosts[target]
	return ok && json.Unmarshal(raw, v) == nil
}

// moveFollowers sends every follower to the target and reports which moved.
func moveFollowers(target string) map[string]bool {
	moved := map[string]bool{}
	for _, f := range cfg.Followers {
		moved[f.Name] = moveFollower(f, target, false)
	}
	return moved
}

// moveFollower skips the relay driver when local (the relay server itself).
func moveFollower(f Follower, target string, local bool) bool {
	for _, d := range f.Drivers {
		impl := drivers[d.Type]
		if impl.move == nil || (d.Type == "relay" && local) {
			continue
		}
		if impl.move(d, f, target) {
			return true
		}
	}
	return false
}

var cacheDir = filepath.Join(home, ".cache/kvm/followers")

// followerStatuses reads each follower's battery from the first driver that
// answers, or its last reading (marked stale) while it is away.
func followerStatuses(local bool) []map[string]any {
	out := []map[string]any{}
	for _, f := range cfg.Followers {
		st := map[string]any{"name": f.Name, "kind": f.Kind}
		cache := filepath.Join(cacheDir, slug(f.Name)+".json")
		var b *Battery
		for _, d := range f.Drivers {
			impl := drivers[d.Type]
			if impl.status == nil || (d.Type == "relay" && local) {
				continue
			}
			if b = impl.status(d, f); b != nil {
				break
			}
		}
		if b != nil && !b.Stale {
			if raw, err := json.Marshal(map[string]any{"battery": b.Percent, "charging": b.Charging, "time": time.Now().Unix()}); err == nil {
				os.MkdirAll(cacheDir, 0o755)
				os.WriteFile(cache, raw, 0o644)
			}
			st["battery"], st["charging"], st["stale"] = b.Percent, b.Charging, false
		} else if b != nil {
			st["battery"], st["charging"], st["stale"] = b.Percent, b.Charging, true
		} else if raw, err := os.ReadFile(cache); err == nil {
			var last map[string]any
			if json.Unmarshal(raw, &last) == nil {
				st["battery"], st["charging"], st["stale"] = last["battery"], last["charging"], true
			}
		}
		out = append(out, st)
	}
	return out
}

var nonWord = regexp.MustCompile(`[^a-z0-9]+`)

func slug(s string) string { return strings.Trim(nonWord.ReplaceAllString(strings.ToLower(s), "-"), "-") }
