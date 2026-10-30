package main

// command: any device a program can switch. "switch" runs with {host} (this
// machine's value from "hosts") and {machine} replaced; exit 0 means it moved.
// "status", optional, prints {"battery": 0-100, "charging": bool}.

import (
	"encoding/json"
	"os/exec"
	"strings"
)

func commandMove(d Driver, f Follower, target string) bool {
	var host string
	if d.Switch == "" || !d.host(target, &host) {
		return false
	}
	cmd := strings.NewReplacer("{host}", host, "{machine}", target).Replace(d.Switch)
	return exec.Command("sh", "-c", cmd).Run() == nil
}

func commandStatus(d Driver, f Follower) *Battery {
	if d.Status == "" {
		return nil
	}
	out, err := exec.Command("sh", "-c", d.Status).Output()
	var b Battery
	if err != nil || json.Unmarshal(out, &b) != nil {
		return nil
	}
	return &b
}
