// SPDX-License-Identifier: MIT

package relay

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"github.com/JunWeiUp/vibepier/services/relay/internal/filetransfer"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type room struct {
	host    *conn
	clients map[string]*conn
}

type relay struct {
	connections atomic.Int32 // all upgraded connections, including unauthenticated peers
	buffers     bufferBudget
	files       filetransfer.Hub
	closed      [9]atomic.Uint64
	secret      []byte
	mu          sync.Mutex
	rooms       map[string]*room
	nonces      map[string]time.Time
}

type notice struct {
	target *conn
	line   string
}

func notify(notices []notice) {
	for _, n := range notices {
		n.target.relayText(n.line)
	}
}

// The HMAC binds the negotiated protocol as well as the role and room.
func randomPeerID() (string, error) {
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes[:]), nil
}

// Only the current relay2 host has a replaceable slot. Every relay1 client
// retains its own routing identity, including while the host is offline.
func (r *relay) join(c *conn) (old []*conn, notices []notice, err error) {
	if !currentRole(c.protocol, c.role) {
		return nil, nil, errors.New("bad-role")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	rm := r.rooms[c.room]
	if rm == nil {
		rm = &room{clients: map[string]*conn{}}
		r.rooms[c.room] = rm
	}
	if c.role == "host" {
		if rm.host != nil {
			old = append(old, rm.host)
			if rm.host.ready {
				for _, phone := range rm.clients {
					if phone.ready {
						notices = append(notices, notice{phone, "vibepier-relay1 peer down"})
					}
				}
			}
		}
		rm.host = c
	} else {
		if len(rm.clients) >= maxClients {
			return nil, nil, errors.New("too-many-clients")
		}
		rm.clients[c.peerID] = c
	}
	// Queue topology notices while holding the room lock. Writes themselves run
	// separately, so a fast reconnect cannot enqueue "down" after the new "up".
	notify(notices)
	return
}

func (r *relay) current(rm *room, c *conn) bool {
	return rm != nil && ((c.role == "host" && rm.host == c) || (c.role == "client" && rm.clients[c.peerID] == c))
}

func (r *relay) activate(c *conn) []notice {
	r.mu.Lock()
	defer r.mu.Unlock()
	rm := r.rooms[c.room]
	if !r.current(rm, c) {
		return nil
	}
	c.ready = true
	var notices []notice
	if c.role == "host" {
		for _, phone := range rm.clients {
			if !phone.ready {
				continue
			}
			notices = append(notices, notice{phone, "vibepier-relay1 peer up"})
			notices = append(notices, notice{c, "vibepier-relay2 peer up " + phone.peerID})
		}
	} else if rm.host != nil && rm.host.ready {
		notices = append(notices, notice{c, "vibepier-relay1 peer up"})
		notices = append(notices, notice{rm.host, "vibepier-relay2 peer up " + c.peerID})
	}
	notify(notices)
	return notices
}

func (r *relay) leave(c *conn) []notice {
	r.mu.Lock()
	defer r.mu.Unlock()
	rm := r.rooms[c.room]
	if !r.current(rm, c) {
		return nil
	} // a replaced connection cannot remove its successor
	var notices []notice
	if c.role == "host" {
		rm.host = nil
		if c.ready {
			for _, phone := range rm.clients {
				if phone.ready {
					notices = append(notices, notice{phone, "vibepier-relay1 peer down"})
				}
			}
		}
	} else {
		delete(rm.clients, c.peerID)
		if c.ready && rm.host != nil && rm.host.ready {
			notices = append(notices, notice{rm.host, "vibepier-relay2 peer down " + c.peerID})
		}
	}
	c.ready = false
	if rm.host == nil && len(rm.clients) == 0 {
		delete(r.rooms, c.room)
	}
	notify(notices)
	return notices
}

func reserved(message string) bool {
	return strings.HasPrefix(message, "vibepier-relay1 ") || strings.HasPrefix(message, "vibepier-relay2 ")
}

func (r *relay) forward(c *conn, message string) {
	if c.role == "client" {
		if reserved(message) {
			return
		}
		r.mu.Lock()
		rm := r.rooms[c.room]
		var host *conn
		if r.current(rm, c) && c.ready && rm.host != nil && rm.host.ready {
			host = rm.host
		}
		r.mu.Unlock()
		if host != nil {
			message = "vibepier-relay2 from " + c.peerID + " " + base64.StdEncoding.EncodeToString([]byte(message))
			r.mu.Lock()
			rm = r.rooms[c.room]
			if r.current(rm, c) && c.ready && rm.host == host && host.ready {
				host.relayText(message)
			}
			r.mu.Unlock()
		}
		return
	}
	parts := strings.SplitN(message, " ", 4)
	if len(parts) != 4 || parts[0] != "vibepier-relay2" || parts[1] != "to" || !peerPattern.MatchString(parts[2]) || len(parts[3]) > base64.StdEncoding.EncodedLen(maxFrame) {
		return
	}
	body, err := base64.StdEncoding.Strict().DecodeString(parts[3])
	if err != nil || len(body) > maxFrame {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	rm := r.rooms[c.room]
	if r.current(rm, c) && c.ready {
		if target := rm.clients[parts[2]]; target != nil && target.ready {
			target.relayText(string(body))
		}
	}
}
