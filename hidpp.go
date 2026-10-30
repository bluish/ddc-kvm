package main

// hidpp: HID++ 2.0 CHANGE_HOST (0x1814), the protocol behind Easy-Switch
// buttons. Linux reaches the device through its USB receiver. Hosts are the
// 1-based channel the device uses for each machine.

import (
	"strings"
	"time"
)

const (
	hidppChangeHost = 0x1814
	hidppDeviceName = 0x0005
	hidppSW         = 0x0B
)

var hidppReceivers = []string{"046D:C548", "046D:C52B"} // Bolt, Unifying

type hidpp struct{ *hidDev }

// request sends a HID++ 2.0 long report and returns the reply's parameters.
func (h hidpp) request(dev, feat, fn byte, params []byte, reply bool) []byte {
	h.drain()
	pkt := make([]byte, 20)
	copy(pkt, []byte{0x11, dev, feat, fn<<4 | hidppSW})
	copy(pkt[4:], params)
	if h.write(pkt) != nil || !reply {
		return nil
	}
	deadline := time.Now().Add(800 * time.Millisecond)
	for {
		r := h.read(deadline)
		if r == nil {
			return nil
		}
		if len(r) < 4 || r[1] != dev {
			continue
		}
		if r[2] == 0x8F || r[2] == 0xFF { // HID++ 1.0 / 2.0 error
			return nil
		}
		if r[2] == feat && r[3] == fn<<4|hidppSW {
			return r[4:]
		}
	}
}

func (h hidpp) featureIndex(dev byte, id uint16) (byte, bool) {
	r := h.request(dev, 0, 0, []byte{byte(id >> 8), byte(id)}, true)
	if len(r) == 0 || r[0] == 0 {
		return 0, false
	}
	return r[0], true
}

func (h hidpp) name(dev byte) string {
	idx, ok := h.featureIndex(dev, hidppDeviceName)
	if !ok {
		return ""
	}
	r := h.request(dev, idx, 0, nil, true)
	if len(r) == 0 {
		return ""
	}
	length := int(r[0])
	var name []byte
	for len(name) < length {
		chunk := h.request(dev, idx, 1, []byte{byte(len(name))}, true)
		if len(chunk) == 0 {
			break
		}
		name = append(name, chunk[:min(len(chunk), length-len(name))]...)
	}
	return string(name)
}

// hidppMove is false when the device has no channel for the target or isn't
// connected to this computer.
func hidppMove(d Driver, f Follower, target string) bool {
	var channel int
	if !d.host(target, &channel) || channel < 1 {
		return false
	}
	receivers := d.Receivers
	if len(receivers) == 0 {
		receivers = hidppReceivers
	}
	node, _ := findHidraw(receivers, []byte{0x06, 0x00, 0xff})
	if node == "" {
		return false
	}
	dev, err := openHid(node)
	if err != nil {
		return false
	}
	defer dev.close()
	h := hidpp{dev}
	for slot := byte(1); slot <= 6; slot++ {
		idx, ok := h.featureIndex(slot, hidppChangeHost)
		if !ok {
			continue // empty, asleep, or connected to another host
		}
		if !strings.Contains(h.name(slot), d.Device) {
			continue // other devices on the same receiver can change host too
		}
		// The device drops off right away, so there is no reply to wait for.
		h.request(slot, idx, 1, []byte{byte(channel - 1)}, false)
		return true
	}
	return false
}
