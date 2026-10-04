// SPDX-License-Identifier: MIT
package filetransfer

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

const MaxSize int64 = 512 << 20

// RelayRegistration contains only opaque, independently scoped capabilities. File bodies
// live in an io.Pipe, never on the relay's disk. Authentication of registration is external.
type RelayRegistration struct {
	ID    string `json:"id"`
	Read  string `json:"read"`
	Write string `json:"write"`
	Size  int64  `json:"size"`
	Room  string `json:"room"`
}
type pipeTransfer struct {
	room                 string
	size                 int64
	read, write          [32]byte
	reader               *io.PipeReader
	writer               *io.PipeWriter
	ready                chan struct{}
	expiry               time.Time
	consuming, producing bool
}
type Hub struct {
	mu        sync.Mutex
	transfers map[string]*pipeTransfer
}

func ValidToken(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
func (h *Hub) Register(r RelayRegistration) error {
	if !ValidToken(r.ID) || !ValidToken(r.Read) || !ValidToken(r.Write) || r.Read == r.Write || r.Size <= 0 || r.Size > MaxSize {
		return errors.New("invalid transfer")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.transfers == nil {
		h.transfers = map[string]*pipeTransfer{}
	}
	now := time.Now()
	roomCount := 0
	for id, t := range h.transfers {
		if now.After(t.expiry) {
			h.remove(id, t)
		} else if t.room == r.Room {
			roomCount++
		}
	}
	if _, exists := h.transfers[r.ID]; exists || len(h.transfers) >= 32 || roomCount >= 4 {
		return errors.New("transfer capacity")
	}
	pr, pw := io.Pipe()
	t := &pipeTransfer{room: r.Room, size: r.Size, read: sha256.Sum256([]byte(r.Read)), write: sha256.Sum256([]byte(r.Write)), reader: pr, writer: pw, ready: make(chan struct{}), expiry: now.Add(10 * time.Minute)}
	h.transfers[r.ID] = t
	time.AfterFunc(10*time.Minute, func() {
		h.mu.Lock()
		defer h.mu.Unlock()
		if h.transfers[r.ID] == t {
			h.remove(r.ID, t)
		}
	})
	return nil
}
func (h *Hub) remove(id string, t *pipeTransfer) {
	delete(h.transfers, id)
	_ = t.reader.CloseWithError(context.Canceled)
	_ = t.writer.CloseWithError(context.Canceled)
}
func (h *Hub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]
	given := sha256.Sum256([]byte(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")))
	h.mu.Lock()
	t := h.transfers[id]
	if t == nil || time.Now().After(t.expiry) {
		h.mu.Unlock()
		http.Error(w, "unavailable", 404)
		return
	}
	read := subtle.ConstantTimeCompare(given[:], t.read[:]) == 1
	write := subtle.ConstantTimeCompare(given[:], t.write[:]) == 1
	if !read && !write {
		h.mu.Unlock()
		http.Error(w, "unauthorized", 403)
		return
	}
	// Extend deadlines only after an opaque capability has authenticated this body.
	controller := http.NewResponseController(w)
	_ = controller.SetReadDeadline(time.Now().Add(10 * time.Minute))
	_ = controller.SetWriteDeadline(time.Now().Add(10 * time.Minute))
	if r.Method == http.MethodHead {
		h.mu.Unlock()
		w.WriteHeader(204)
		return
	}
	if r.Method == http.MethodDelete {
		h.remove(id, t)
		h.mu.Unlock()
		w.WriteHeader(204)
		return
	}
	if r.Method == http.MethodPut && write && !t.producing && r.ContentLength == t.size {
		t.producing = true
		close(t.ready)
		h.mu.Unlock()
		defer func() { _ = t.writer.Close() }()
		stop := context.AfterFunc(r.Context(), func() { _ = t.writer.CloseWithError(context.Canceled) })
		defer stop()
		// Pipe writes backpressure the HTTP producer; memory stays bounded regardless of file size.
		n, err := io.CopyBuffer(t.writer, io.LimitReader(r.Body, t.size), make([]byte, 256<<10))
		if err != nil || n != t.size {
			_ = t.writer.CloseWithError(io.ErrUnexpectedEOF)
			http.Error(w, "interrupted", 409)
			return
		}
		w.WriteHeader(204)
		return
	}
	if r.Method == http.MethodGet && read && !t.consuming && r.Header.Get("Range") == "" {
		t.consuming = true
		h.mu.Unlock()
		defer func() {
			h.mu.Lock()
			if h.transfers[id] == t {
				h.remove(id, t)
			}
			h.mu.Unlock()
		}()
		select {
		case <-t.ready:
		case <-r.Context().Done():
			return
		case <-time.After(20 * time.Second):
			http.Error(w, "producer unavailable", 504)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Length", itoa(t.size))
		w.WriteHeader(200)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		stop := context.AfterFunc(r.Context(), func() { _ = t.reader.CloseWithError(context.Canceled) })
		defer stop()
		_, _ = io.CopyBuffer(w, t.reader, make([]byte, 256<<10))
		return
	}
	h.mu.Unlock()
	http.Error(w, "invalid state", 409)
}
