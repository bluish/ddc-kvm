package main

// rawhid: commands on a vendor raw HID interface (QMK's raw HID, usage page
// 0xFF60, 32-byte reports), for firmware that can switch hosts on request.
// Hosts are the command bytes for each machine, in hex ("C0 02 01").

import (
	"bytes"
	"encoding/hex"
	"strings"
	"time"
)

var rawhidUsage = []byte{0x06, 0x60, 0xff, 0x09, 0x61} // usage page 0xFF60, usage 0x61

func parseHex(s string) []byte {
	b, err := hex.DecodeString(strings.ReplaceAll(s, " ", ""))
	if err != nil {
		fail("bad hex %q", s)
	}
	return b
}

// rawhidCommand sends cmd to the first reachable id and returns the reply
// (which echoes the command's first two bytes).
func rawhidCommand(d Driver, cmd []byte) []byte {
	for i := range d.IDs {
		node, _ := findHidraw(d.IDs[i:i+1], rawhidUsage)
		if node == "" {
			continue
		}
		dev, err := openHid(node)
		if err != nil {
			continue
		}
		dev.drain()
		pkt := make([]byte, 33)
		copy(pkt[1:], cmd)
		if dev.write(pkt) == nil {
			deadline := time.Now().Add(time.Second)
			for r := dev.read(deadline); r != nil; r = dev.read(deadline) {
				if len(r) >= 2 && bytes.Equal(r[:2], cmd[:2]) {
					dev.close()
					return r
				}
			}
		}
		dev.close()
	}
	return nil
}

// rawhidMove succeeds on any reply, or, with "ok" set, when that reply byte is 1.
func rawhidMove(d Driver, f Follower, target string) bool {
	var cmd string
	if !d.host(target, &cmd) {
		return false
	}
	r := rawhidCommand(d, parseHex(cmd))
	if r == nil {
		return false
	}
	return d.OK == nil || (len(r) > *d.OK && r[*d.OK] == 1)
}

// rawhidStatus sends "query" and reads the battery and charging bytes at
// their offsets in the reply.
func rawhidStatus(d Driver, f Follower) *Battery {
	if d.Query == "" || d.Battery == nil {
		return nil
	}
	r := rawhidCommand(d, parseHex(d.Query))
	if r == nil || len(r) <= *d.Battery {
		return nil
	}
	b := &Battery{Percent: int(r[*d.Battery])}
	if d.Charging != nil && len(r) > *d.Charging {
		b.Charging = r[*d.Charging] == 1
	}
	return b
}
