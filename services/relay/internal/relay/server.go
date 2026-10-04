// SPDX-License-Identifier: MIT

package relay

import (
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"github.com/JunWeiUp/vibepier/services/relay/internal/filetransfer"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"time"
)

func acceptKey(key string) string {
	sum := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	return base64.StdEncoding.EncodeToString(sum[:])
}

func (r *relay) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	if strings.Contains(req.URL.Path, "/files/") {
		if strings.HasSuffix(req.URL.Path, "/files/register") {
			if req.Method != http.MethodPost {
				http.Error(w, "method", 405)
				return
			}
			_, role, room, err := r.verify(req.Header.Get("X-VibePier-Authorization"))
			if err != nil || role != "host" {
				http.Error(w, "unauthorized", 403)
				return
			}
			var registration filetransfer.RelayRegistration
			decoder := json.NewDecoder(http.MaxBytesReader(w, req.Body, 4096))
			decoder.DisallowUnknownFields()
			if decoder.Decode(&registration) != nil || registration.Room != room {
				http.Error(w, "invalid", 400)
				return
			}
			if err = r.files.Register(registration); err != nil {
				http.Error(w, "capacity or invalid", 409)
				return
			}
			w.WriteHeader(201)
			return
		}
		r.files.ServeHTTP(w, req)
		return
	}

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
	c := &conn{raw: raw, reader: buffered.Reader, budget: &r.buffers}
	c.onClose = func(reason closeReason) {
		count := r.closed[reason].Add(1)
		log.Printf("relay closed reason=%s count=%d active=%d output_bytes=%d", reason, count, r.connections.Load(), r.buffers.bytes.Load())
	}
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
		if err == nil {
			c.closeWith(closeTimeout)
		} else {
			c.closeWith(readCloseReason(err))
		}
		return
	}
	prefix := "vibepier-relay1"
	if strings.HasPrefix(hello, "vibepier-relay2 ") {
		prefix = "vibepier-relay2"
	}
	protocol, role, roomName, err := r.verify(hello)
	if err != nil {
		log.Printf("relay rejected reason=authentication")
		time.Sleep(time.Second)
		_ = c.text(prefix + " error " + err.Error())
		c.closeWith(closeAuthentication)
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
		c.closeWith(closeCapacity)
		return
	}
	defer r.leave(c)
	for _, replaced := range old {
		replaced.closeWith(closeReplaced)
	}
	ok := "vibepier-relay1 ok"
	if protocol == 2 {
		ok = "vibepier-relay2 ok"
	}
	if c.text(ok) != nil {
		return
	}
	r.activate(c)
	log.Printf("relay joined role=%s protocol=%d active=%d", role, protocol, r.connections.Load())

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
					c.closeWith(closeWrite)
					return
				}
			}
		}
	}()

	for {
		message, err := c.next()
		if err != nil {
			c.closeWith(readCloseReason(err))
			break
		}
		r.forward(c, message)
	}
}

func readCloseReason(err error) closeReason {
	var network net.Error
	if errors.As(err, &network) && network.Timeout() {
		return closeTimeout
	}
	if err == nil || errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) || errors.As(err, &network) {
		return closeNormal
	}
	return closeProtocol
}
