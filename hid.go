package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const (
	hidiocgrdescsize = 0x80044801
	hidiocgrdesc     = 0x90044802
)

func hidrawDesc(node string) ([]byte, error) {
	f, err := os.OpenFile(node, os.O_RDWR, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var size int32
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), hidiocgrdescsize, uintptr(unsafe.Pointer(&size))); e != 0 {
		return nil, e
	}
	buf := make([]byte, 4+4096)
	binary.LittleEndian.PutUint32(buf, uint32(size))
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), hidiocgrdesc, uintptr(unsafe.Pointer(&buf[0]))); e != 0 {
		return nil, e
	}
	return buf[4 : 4+size], nil
}

// findHidraw returns the hidraw node of the first device in ids (vendor:product
// in hex, "046D:C548") whose report descriptor starts with prefix (it picks
// the vendor collection), and the rank of the id it matched.
func findHidraw(ids []string, prefix []byte) (string, int) {
	uevents, _ := filepath.Glob("/sys/class/hidraw/hidraw*/device/uevent")
	sort.Strings(uevents)
	for rank, id := range ids {
		vendor, product, _ := strings.Cut(strings.ToUpper(id), ":")
		want := fmt.Sprintf(":%08s:%08s\n", vendor, product)
		for _, u := range uevents {
			raw, err := os.ReadFile(u)
			if err != nil || !strings.Contains(strings.ToUpper(string(raw)), want) {
				continue
			}
			node := "/dev/" + strings.Split(u, "/")[4]
			if desc, err := hidrawDesc(node); err == nil && bytes.HasPrefix(desc, prefix) {
				return node, rank
			}
		}
	}
	return "", -1
}

// hidDev is an open hidraw node with reads that time out.
type hidDev struct{ fd int }

func openHid(node string) (*hidDev, error) {
	fd, err := syscall.Open(node, syscall.O_RDWR|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	return &hidDev{fd}, nil
}

func (d *hidDev) close() { syscall.Close(d.fd) }

func (d *hidDev) drain() {
	buf := make([]byte, 64)
	for {
		if n, err := syscall.Read(d.fd, buf); n <= 0 || err != nil {
			return
		}
	}
}

func (d *hidDev) write(b []byte) error {
	_, err := syscall.Write(d.fd, b)
	return err
}

// read waits until the deadline for one report.
func (d *hidDev) read(deadline time.Time) []byte {
	buf := make([]byte, 64)
	for {
		left := time.Until(deadline)
		if left <= 0 {
			return nil
		}
		fds := []pollFd{{fd: int32(d.fd), events: 1}} // POLLIN
		n, _, _ := syscall.Syscall(syscall.SYS_POLL, uintptr(unsafe.Pointer(&fds[0])), 1, uintptr(left.Milliseconds()+1))
		if int(n) <= 0 {
			continue
		}
		if r, err := syscall.Read(d.fd, buf); err == nil && r > 0 {
			return append([]byte(nil), buf[:r]...)
		}
	}
}

type pollFd struct {
	fd      int32
	events  int16
	revents int16
}
