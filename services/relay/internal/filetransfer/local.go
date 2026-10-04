// SPDX-License-Identifier: MIT
package filetransfer

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

func itoa(v int64) string { return strconv.FormatInt(v, 10) }
func Token() string {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}

type Offer struct {
	ID       string `json:"id"`
	Device   string `json:"device"`
	Scope    string `json:"scope"`
	Kind     string `json:"kind"`
	File     string `json:"file"`
	Size     int64  `json:"size"`
	Offset   int64  `json:"offset"`
	Read     string `json:"read"`
	Write    string `json:"write"`
	Received int64  `json:"received"`
	Complete bool   `json:"complete"`
	Error    bool   `json:"error"`
	expiry   time.Time
	cancel   context.CancelFunc
	ctx      context.Context
	active   bool
}
type Store struct {
	mu     sync.Mutex
	offers map[string]*Offer
	Root   string
}

func (s *Store) Create(kind, device, scope, file string, size, offset int64) (*Offer, error) {
	if (kind != "upload" && kind != "apk") || device == "" || len(scope) > 512 || size <= 0 || size > MaxSize || offset < 0 || offset >= size || (kind == "upload" && (size > 10<<20 || offset != 0)) {
		return nil, errors.New("invalid offer")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.offers == nil {
		s.offers = map[string]*Offer{}
	}
	count := 0
	now := time.Now()
	for id, t := range s.offers {
		if now.After(t.expiry) {
			s.remove(id, t)
		} else if t.Device == device {
			count++
		}
	}
	if count >= 6 || len(s.offers) >= 24 {
		return nil, errors.New("capacity")
	}
	t := &Offer{ID: Token(), Device: device, Scope: scope, Kind: kind, Size: size, Offset: offset, Read: Token(), Write: Token(), expiry: now.Add(10 * time.Minute)}
	t.ctx, t.cancel = context.WithCancel(context.Background())
	if kind == "upload" {
		var err error
		if err = os.MkdirAll(s.Root, 0700); err != nil {
			return nil, err
		}
		t.File = filepath.Join(s.Root, t.ID)
		f, err := os.OpenFile(t.File, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			return nil, err
		}
		_ = f.Close()
	} else {
		info, err := os.Lstat(file)
		if err != nil || !info.Mode().IsRegular() || info.Size() != size {
			return nil, errors.New("invalid snapshot")
		}
		t.File = file
	}
	s.offers[t.ID] = t
	time.AfterFunc(10*time.Minute, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.offers[t.ID] == t {
			s.remove(t.ID, t)
		}
	})
	return t, nil
}
func Context(t *Offer) context.Context { return t.ctx }
func (s *Store) remove(id string, t *Offer) {
	delete(s.offers, id)
	t.cancel()
	if t.Kind == "upload" {
		_ = os.Remove(t.File)
	}
}
func (s *Store) Cancel(id, device string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for key, t := range s.offers {
		if (id != "" && key == id) || (device != "" && device == t.Device) || (id == "" && device == "") {
			s.remove(key, t)
		}
	}
}
func (s *Store) Status(id string) (Offer, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.offers[id]
	if t == nil {
		return Offer{}, errors.New("unavailable")
	}
	return *t, nil
}
func (s *Store) Begin(t *Offer) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.offers[t.ID] != t || t.active || t.Complete || t.Error || time.Now().After(t.expiry) {
		return false
	}
	t.active = true
	return true
}
func (s *Store) fail(t *Offer) { s.mu.Lock(); defer s.mu.Unlock(); t.Error = true; t.cancel() }
func WireSize(t *Offer) int64  { return t.Size - t.Offset }

func (s *Store) Upload(t *Offer, reader io.Reader) error {
	if !s.Begin(t) {
		return errors.New("already active")
	}
	err := s.receive(t, reader)
	if err != nil {
		s.fail(t)
	}
	return err
}
func (s *Store) receive(t *Offer, r io.Reader) error {
	f, err := os.OpenFile(t.File, os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	buffer := make([]byte, 256<<10)
	var received int64
	for received < t.Size {
		if t.ctx.Err() != nil {
			return context.Canceled
		}
		count := int(min(int64(len(buffer)), t.Size-received))
		n, err := io.ReadFull(r, buffer[:count])
		if err != nil {
			return err
		}
		if _, err = f.Write(buffer[:n]); err != nil {
			return err
		}
		received += int64(n)
		s.mu.Lock()
		t.Received = received
		s.mu.Unlock()
	}
	var extra [1]byte
	if n, err := r.Read(extra[:]); n != 0 || err != io.EOF {
		return errors.New("invalid end")
	}
	if err = f.Sync(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if t.ctx.Err() != nil || s.offers[t.ID] != t {
		return context.Canceled
	}
	t.Complete = true
	return nil
}

func (s *Store) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]
	hash := sha256.Sum256([]byte(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")))
	s.mu.Lock()
	t := s.offers[id]
	if t == nil || time.Now().After(t.expiry) {
		s.mu.Unlock()
		http.Error(w, "unavailable", 404)
		return
	}
	expected := sha256.Sum256([]byte(t.Read))
	if r.Method == http.MethodPut {
		expected = sha256.Sum256([]byte(t.Write))
	}
	valid := subtle.ConstantTimeCompare(hash[:], expected[:]) == 1
	s.mu.Unlock()
	if !valid {
		http.Error(w, "unauthorized", 403)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if r.Method == http.MethodHead {
		w.WriteHeader(204)
		return
	}
	if r.Method == http.MethodPut && t.Kind == "upload" && r.ContentLength == WireSize(t) {
		stop := context.AfterFunc(t.ctx, func() { _ = r.Body.Close() })
		defer stop()
		if err := s.Upload(t, r.Body); err != nil {
			http.Error(w, "interrupted", 409)
			return
		}
		w.WriteHeader(204)
		return
	}
	if r.Method == http.MethodGet && t.Kind == "apk" && r.Header.Get("Range") == fmt.Sprintf("bytes=%d-", t.Offset) {
		if !s.Begin(t) {
			http.Error(w, "already active", 409)
			return
		}
		f, err := os.Open(t.File)
		if err != nil {
			s.fail(t)
			http.Error(w, "unavailable", 404)
			return
		}
		defer f.Close()
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Length", itoa(t.Size-t.Offset))
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", t.Offset, t.Size-1, t.Size))
		w.WriteHeader(206)
		buf := make([]byte, 256<<10)
		reader := io.NewSectionReader(f, t.Offset, t.Size-t.Offset)
		for {
			if t.ctx.Err() != nil {
				return
			}
			n, err := reader.Read(buf)
			if n > 0 {
				if _, e := w.Write(buf[:n]); e != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	}
	http.Error(w, "invalid request", 409)
}
