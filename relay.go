package main

import (
	"bytes"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var (
	tokenFile       = filepath.Join(home, ".config/kvm/token")
	relayClientFile = filepath.Join(home, ".config/kvm/relay.json")
)

func relayToken() string {
	if raw, err := os.ReadFile(tokenFile); err == nil {
		return strings.TrimSpace(string(raw))
	}
	b := make([]byte, 32)
	rand.Read(b)
	token := base64.RawURLEncoding.EncodeToString(b)
	os.MkdirAll(filepath.Dir(tokenFile), 0o700)
	if err := os.WriteFile(tokenFile, []byte(token), 0o600); err != nil {
		fail("%v", err)
	}
	return token
}

// serve lets other computers reach followers only this one can (a device
// whose wired or dongle link is plugged in here). It listens on one address
// (the tailnet one by default) and requires the token.
func serve() {
	if len(cfg.Followers) == 0 {
		fail("no followers in the config: nothing to relay")
	}
	token := relayToken()
	host := cfg.Relay.Listen
	if host == "tailscale" {
		out, _ := exec.Command("tailscale", "ip", "-4").Output()
		if f := strings.Fields(string(out)); len(f) > 0 {
			host = f[0]
		} else {
			fail("no tailnet address")
		}
	}
	reply := func(w http.ResponseWriter, code int, v any) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		json.NewEncoder(w).Encode(v)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /followers", func(w http.ResponseWriter, r *http.Request) {
		reply(w, 200, followerStatuses(true))
	})
	mux.HandleFunc("POST /switch", func(w http.ResponseWriter, r *http.Request) {
		target, name := r.URL.Query().Get("target"), r.URL.Query().Get("follower")
		for _, f := range cfg.Followers {
			if f.Name == name && machine(target) != nil {
				reply(w, 200, map[string]bool{"moved": moveFollower(f, target, true)})
				return
			}
		}
		reply(w, 400, map[string]string{"error": "bad request"})
	})
	auth := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s %s", r.RemoteAddr, r.Method, r.URL.Path)
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+token)) != 1 {
			reply(w, 401, map[string]string{"error": "unauthorized"})
			return
		}
		mux.ServeHTTP(w, r)
	})
	addr := net.JoinHostPort(host, strconv.Itoa(cfg.Relay.Port))
	fmt.Fprintln(os.Stderr, "kvm relay on", addr)
	fail("%v", http.ListenAndServe(addr, auth))
}

// relayCall asks the computer running `kvm serve`, as set in relay.json
// ({"url": ..., "token": ...}).
func relayCall(method, path string, out any) bool {
	raw, err := os.ReadFile(relayClientFile)
	var rc struct{ URL, Token string }
	if err != nil || json.Unmarshal(raw, &rc) != nil || rc.URL == "" {
		return false
	}
	base, err := url.Parse(rc.URL)
	if err != nil {
		return false
	}
	ref, _ := url.Parse(path)
	req, _ := http.NewRequest(method, base.ResolveReference(ref).String(), bytes.NewReader(nil))
	req.Header.Set("Authorization", "Bearer "+rc.Token)
	resp, err := (&http.Client{Timeout: 4 * time.Second}).Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == 200 && json.NewDecoder(resp.Body).Decode(out) == nil
}

func relayMove(d Driver, f Follower, target string) bool {
	var r struct{ Moved bool }
	q := url.Values{"follower": {f.Name}, "target": {target}}
	return relayCall("POST", "switch?"+q.Encode(), &r) && r.Moved
}

func relayStatus(d Driver, f Follower) *Battery {
	var list []struct {
		Name     string
		Battery  *int
		Charging bool
		Stale    bool
	}
	if !relayCall("GET", "followers", &list) {
		return nil
	}
	for _, s := range list {
		if s.Name == f.Name && s.Battery != nil {
			return &Battery{Percent: *s.Battery, Charging: s.Charging, Stale: s.Stale}
		}
	}
	return nil
}
