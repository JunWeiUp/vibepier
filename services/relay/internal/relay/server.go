// SPDX-License-Identifier: MIT

package relay

import (
	"crypto/sha1"
	"encoding/base64"
	"log"
	"net/http"
	"strings"
	"time"
)

func acceptKey(key string) string {
	sum := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	return base64.StdEncoding.EncodeToString(sum[:])
}

func (r *relay) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	key := req.Header.Get("Sec-WebSocket-Key")
	decoded, err := base64.StdEncoding.DecodeString(key)
	if req.Method != http.MethodGet || !req.ProtoAtLeast(1, 1) ||
		!strings.EqualFold(req.Header.Get("Upgrade"), "websocket") ||
		!headerToken(req.Header, "Connection", "upgrade") || req.Header.Get("Sec-WebSocket-Version") != "13" ||
		err != nil || len(decoded) != 16 {
		w.Header().Set("Sec-WebSocket-Version", "13")
		http.Error(w, "vibepier relay: websocket required", http.StatusUpgradeRequired)
		return
	}
	if r.connections.Add(1) > maxConnections {
		r.connections.Add(-1)
		http.Error(w, "vibepier relay: connection limit", http.StatusServiceUnavailable)
		return
	}
	handedOff := false
	defer func() {
		if !handedOff {
			r.connections.Add(-1)
		}
	}()
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "unsupported", http.StatusInternalServerError)
		return
	}
	raw, buffered, err := hijacker.Hijack()
	if err != nil {
		return
	}
	_, _ = buffered.WriteString("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + acceptKey(key) + "\r\n\r\n")
	if buffered.Flush() != nil {
		_ = raw.Close()
		return
	}
	c := &conn{raw: raw, reader: buffered.Reader}
	handedOff = true
	go func() {
		defer r.connections.Add(-1)
		r.serve(c, req.Header.Get("X-Real-IP"))
	}()
}

func headerToken(header http.Header, name, token string) bool {
	for _, value := range header.Values(name) {
		for _, part := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(part), token) {
				return true
			}
		}
	}
	return false
}

func (r *relay) serve(c *conn, ip string) {
	defer c.close()
	admissionDeadline := time.Now().Add(helloTimeout)
	_ = c.raw.SetReadDeadline(admissionDeadline)
	hello, err := c.next()
	if err != nil || time.Now().After(admissionDeadline) {
		return
	}
	prefix := "vibepier-relay1"
	if strings.HasPrefix(hello, "vibepier-relay2 ") {
		prefix = "vibepier-relay2"
	}
	protocol, role, roomName, err := r.verify(hello)
	if err != nil {
		log.Printf("reject %q: %v", ip, err)
		time.Sleep(time.Second)
		_ = c.text(prefix + " error " + err.Error())
		return
	}
	c.role, c.room, c.protocol = role, roomName, protocol
	if role == "client" {
		c.peerID, err = randomPeerID()
		if err != nil {
			return
		}
	}
	_ = c.raw.SetReadDeadline(time.Now().Add(idleTimeout))
	old, _, err := r.join(c)
	if err != nil {
		_ = c.text(prefix + " error " + err.Error())
		return
	}
	defer r.leave(c)
	for _, replaced := range old {
		replaced.close()
	}
	ok := "vibepier-relay1 ok"
	if protocol == 2 {
		ok = "vibepier-relay2 ok"
	}
	if c.text(ok) != nil {
		return
	}
	r.activate(c)
	log.Printf("%s relay%d joined room %s from %q", role, protocol, roomName, ip)

	stop := make(chan struct{})
	defer close(stop)
	go func() {
		ticker := time.NewTicker(pingEvery)
		defer ticker.Stop()
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				if c.send(0x9, nil) != nil {
					c.close()
					return
				}
			}
		}
	}()

	for {
		message, err := c.next()
		if err != nil {
			break
		}
		r.forward(c, message)
	}
	log.Printf("%s left room %s", role, roomName)
}
