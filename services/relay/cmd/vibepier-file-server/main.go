// SPDX-License-Identifier: MIT
// Private child process of VibePier: stdin is the capability issuance boundary.
package main

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"github.com/JunWeiUp/vibepier/services/relay/internal/filetransfer"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type command struct {
	Request string `json:"request"`
	Op      string `json:"op"`
	Kind    string `json:"kind"`
	Device  string `json:"device"`
	Scope   string `json:"scope"`
	File    string `json:"file"`
	Size    int64  `json:"size"`
	Offset  int64  `json:"offset"`
	ID      string `json:"id"`
	URL     string `json:"url"`
	Secret  string `json:"secret"`
	Room    string `json:"room"`
}
type relayConfig struct{ url, room, secret string }

func main() {
	if len(os.Args) != 2 {
		return
	}
	root := filepath.Clean(os.Args[1])
	if !filepath.IsAbs(root) {
		return
	}
	// This tree contains only abandoned private upload staging, never caller files.
	_ = os.RemoveAll(root)
	defer os.RemoveAll(root)
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	template := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "VibePier private file channel"}, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(365 * 24 * time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true}
	cert, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return
	}
	pin := sha256.Sum256(cert)
	store := &filetransfer.Store{Root: root}
	raw, err := net.Listen("tcp", ":0")
	if err != nil {
		return
	}
	listener := tls.NewListener(&boundedListener{Listener: raw, slots: make(chan struct{}, 32)}, &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{cert}, PrivateKey: key}}, MinVersion: tls.VersionTLS13})
	port := listener.Addr().(*net.TCPAddr).Port
	// Bound TLS/socket work separately from control traffic.
	slots := make(chan struct{}, 24)
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case slots <- struct{}{}:
			defer func() { <-slots }()
			store.ServeHTTP(w, r)
		default:
			http.Error(w, "busy", 503)
		}
	})
	server := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Minute, WriteTimeout: 10 * time.Minute, IdleTimeout: 15 * time.Second, MaxHeaderBytes: 8192, ErrorLog: log.New(io.Discard, "", 0)}
	go server.Serve(listener)
	defer server.Close()
	defer store.Cancel("", "")
	var outputMu sync.Mutex
	emit := func(v map[string]any) {
		outputMu.Lock()
		defer outputMu.Unlock()
		_ = json.NewEncoder(os.Stdout).Encode(v)
	}
	emit(map[string]any{"ready": true, "port": port, "pin": hex.EncodeToString(pin[:])})
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = fileHTTPProxy
	client := &http.Client{Transport: transport, Timeout: 10 * time.Minute, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
	var config relayConfig
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 32768)
	for scanner.Scan() {
		var c command
		if json.Unmarshal(scanner.Bytes(), &c) != nil {
			continue
		}
		result := map[string]any{"request": c.Request, "ok": true}
		switch c.Op {
		case "configure":
			u, e := url.Parse(c.URL)
			if e == nil && u.Scheme == "https" && u.Host != "" && u.User == nil && u.RawQuery == "" && u.Fragment == "" && len(c.Secret) >= 32 && len(c.Room) <= 64 {
				config = relayConfig{strings.TrimRight(c.URL, "/"), c.Room, c.Secret}
			} else {
				config = relayConfig{}
			}
		case "cancel":
			store.Cancel(c.ID, c.Device)
		case "status":
			status, e := store.Status(c.ID)
			if e != nil {
				result["ok"] = false
			} else {
				result["received"] = status.Received
				result["complete"] = status.Complete
				result["failed"] = status.Error
				result["file"] = status.File
				result["device"] = status.Device
				result["scope"] = status.Scope
				result["size"] = status.Size
			}
		case "offer":
			t, e := store.Create(c.Kind, c.Device, c.Scope, c.File, c.Size, c.Offset)
			if e != nil {
				result["ok"] = false
				break
			}
			profile := map[string]any{"version": 1, "encoding": "raw", "id": t.ID, "kind": t.Kind, "size": t.Size, "offset": t.Offset, "port": port, "pin": hex.EncodeToString(pin[:]), "readToken": t.Read, "writeToken": t.Write, "directHosts": directHosts()}
			if config.url != "" {
				profile["relayURL"] = config.url + "/" + t.ID
				cfg := config
				go relayFile(client, cfg, store, t)
			}
			result["profile"] = profile
		default:
			result["ok"] = false
		}
		emit(result)
	}
}
func relayFile(client *http.Client, cfg relayConfig, store *filetransfer.Store, t *filetransfer.Offer) {
	length := filetransfer.WireSize(t)
	body, _ := json.Marshal(filetransfer.RelayRegistration{ID: t.ID, Read: t.Read, Write: t.Write, Size: length, Room: cfg.room})
	// Fresh relay host proof uses the same nonce/replay checks as WebSocket admission.
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	nonce := filetransfer.Token()
	mac := hmac.New(sha256.New, []byte(cfg.secret))
	_, _ = io.WriteString(mac, "vibepier-relay2|host|"+cfg.room+"|"+ts+"|"+nonce)
	auth := "vibepier-relay2 hello host " + cfg.room + " " + ts + " " + nonce + " " + hex.EncodeToString(mac.Sum(nil))
	req, _ := http.NewRequest(http.MethodPost, cfg.url+"/register", strings.NewReader(string(body)))
	req.Header.Set("X-VibePier-Authorization", auth)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	resp, err := client.Do(req.WithContext(ctx))
	if err != nil {
		return
	}
	_ = resp.Body.Close()
	if resp.StatusCode != 201 {
		return
	}
	defer func() {
		cleanup, _ := http.NewRequest(http.MethodDelete, cfg.url+"/"+t.ID, nil)
		cleanup.Header.Set("Authorization", "Bearer "+t.Read)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		response, err := client.Do(cleanup.WithContext(ctx))
		if err == nil {
			_ = response.Body.Close()
		}
	}()

	// Local and cloud are alternate routes; only the first successful body can own a ticket.
	status, _ := store.Status(t.ID)
	if status.Error {
		return
	}
	if t.Kind == "upload" {
		req, _ = http.NewRequest(http.MethodGet, cfg.url+"/"+t.ID, nil)
		req.Header.Set("Authorization", "Bearer "+t.Read)
		resp, err = client.Do(req.WithContext(filetransfer.Context(t)))
		if err != nil {
			return
		}
		defer resp.Body.Close()
		if resp.StatusCode == 200 && resp.ContentLength == length {
			_ = store.Upload(t, resp.Body)
		}
	} else {
		f, e := os.Open(t.File)
		if e != nil {
			return
		}
		defer f.Close()
		req, _ = http.NewRequest(http.MethodPut, cfg.url+"/"+t.ID, io.NewSectionReader(f, t.Offset, length))
		req.ContentLength = length
		req.Header.Set("Authorization", "Bearer "+t.Write)
		resp, err = client.Do(req.WithContext(filetransfer.Context(t)))
		if err == nil {
			_ = resp.Body.Close()
		}
	}
}

// IPv4 LAN and public IPv6 candidates are authenticated in the offer; reachability
// and the exact certificate pin are verified before the phone chooses a body route.
func directHosts() []string {
	addresses, err := net.InterfaceAddrs()
	if err != nil {
		return nil
	}
	var ipv4, ipv6 []string
	for _, address := range addresses {
		ip, _, err := net.ParseCIDR(address.String())
		if err != nil || !ip.IsGlobalUnicast() || ip.IsLoopback() {
			continue
		}
		if ip.To4() != nil {
			ipv4 = append(ipv4, ip.String())
		} else if len(ip) == 16 && ip[0]&0xe0 == 0x20 {
			ipv6 = append(ipv6, ip.String())
		}
	}
	var result []string
	for i := 0; i < 4; i++ {
		if i < len(ipv6) {
			result = append(result, ipv6[i])
		}
		if i < len(ipv4) {
			result = append(result, ipv4[i])
		}
		if len(result) >= 4 {
			return result[:4]
		}
	}
	return result
}
