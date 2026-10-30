package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var busCache = filepath.Join(home, ".cache/kvm/bus")

func ddcBus(refresh bool) string {
	if !refresh {
		if raw, err := os.ReadFile(busCache); err == nil {
			return strings.TrimSpace(string(raw))
		}
	}
	out, _ := exec.Command("ddcutil", "detect", "--brief").Output()
	bus := ""
	for _, block := range strings.Split(string(out), "\n\n") {
		if !strings.Contains(block, cfg.Monitor) {
			continue
		}
		for _, line := range strings.Split(block, "\n") {
			if _, after, ok := strings.Cut(line, "/dev/i2c-"); ok {
				bus = strings.Fields(after)[0]
			}
		}
	}
	if bus == "" {
		fail("%s not found over DDC/CI", cfg.Monitor)
	}
	os.MkdirAll(filepath.Dir(busCache), 0o755)
	os.WriteFile(busCache, []byte(bus), 0o644)
	return bus
}

// ddcutil runs ddcutil on the monitor's bus, detecting the bus again once if
// the cached one fails (it changes when cables or GPUs move).
func ddcutil(args ...string) string {
	var stderr string
	for _, refresh := range []bool{false, true} {
		cmd := exec.Command("ddcutil", append([]string{"--bus", ddcBus(refresh), "--noverify"}, args...)...)
		var errBuf strings.Builder
		cmd.Stderr = &errBuf
		out, err := cmd.Output()
		if err == nil {
			return string(out)
		}
		stderr = strings.TrimSpace(errBuf.String())
	}
	if stderr == "" {
		stderr = "ddcutil failed"
	}
	fail("%s", stderr)
	return ""
}

// getVCP reads current values ("VCP 10 C 25 100" in --brief output).
func getVCP(codes ...string) map[string]*int {
	vals := map[string]*int{}
	out := ddcutil(append(append([]string{"getvcp"}, codes...), "--brief")...)
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) < 4 || f[0] != "VCP" {
			continue
		}
		var v int64
		var err error
		if strings.HasPrefix(f[3], "x") {
			v, err = strconv.ParseInt(f[3][1:], 16, 32)
		} else {
			v, err = strconv.ParseInt(f[3], 10, 32)
		}
		if err == nil {
			n := int(v)
			vals[strings.ToUpper(f[1])] = &n
		}
	}
	return vals
}

func setInput(target string) {
	n, err := hexOrInt(machine(target).Input)
	if err != nil {
		fail("machine %s: bad input %q", target, machine(target).Input)
	}
	// The monitor sometimes drops an input write that went out fine; writing
	// the same input again is harmless.
	ddcutil("setvcp", "60", fmt.Sprintf("x%02x", n))
	time.Sleep(300 * time.Millisecond)
	ddcutil("setvcp", "60", fmt.Sprintf("x%02x", n))
}
