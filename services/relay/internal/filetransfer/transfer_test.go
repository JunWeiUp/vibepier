// SPDX-License-Identifier: MIT
package filetransfer

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestRawUploadSizeAndCancellation(t *testing.T) {
	for _, scenario := range []string{"valid", "truncated", "extra", "cancelled"} {
		t.Run(scenario, func(t *testing.T) {
			s := Store{Root: t.TempDir()}
			offer, err := s.Create("upload", "device", "draft|attachment", "", 180000, 0)
			if err != nil {
				t.Fatal(err)
			}
			data := bytes.Repeat([]byte{42}, 180000)
			wire := append([]byte(nil), data...)
			switch scenario {
			case "truncated":
				wire = wire[:len(wire)-1]
			case "extra":
				wire = append(wire, 0)
			case "cancelled":
				s.Cancel(offer.ID, "")
			}
			err = s.Upload(offer, bytes.NewReader(wire))
			if scenario == "valid" {
				if err != nil {
					t.Fatal(err)
				}
				state, _ := s.Status(offer.ID)
				got, _ := os.ReadFile(state.File)
				if !state.Complete || !bytes.Equal(got, data) {
					t.Fatal("incomplete or incorrect bytes")
				}
				if s.Upload(offer, bytes.NewReader(wire)) == nil {
					t.Fatal("replayed capability")
				}
			} else if err == nil {
				t.Fatal("invalid stream accepted")
			}
		})
	}
}
func TestAPKRangeAndCapabilities(t *testing.T) {
	s := Store{Root: t.TempDir()}
	data := bytes.Repeat([]byte{9}, 300000)
	file := filepath.Join(t.TempDir(), "snapshot.apk")
	_ = os.WriteFile(file, data, 0600)
	offer, err := s.Create("apk", "phone-a", "apk:transfer", file, int64(len(data)), 100000)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(&s)
	defer server.Close()
	for _, test := range []struct {
		token, span string
		want        int
	}{{Token(), "bytes=100000-", 403}, {offer.Read, "bytes=0-", 409}, {offer.Read, "bytes=100000-", 206}, {offer.Read, "bytes=100000-", 409}} {
		req, _ := http.NewRequest("GET", server.URL+"/files/"+offer.ID, nil)
		req.Header.Set("Authorization", "Bearer "+test.token)
		req.Header.Set("Range", test.span)
		resp, err := server.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if resp.StatusCode != test.want {
			t.Fatalf("status %d wanted %d", resp.StatusCode, test.want)
		}
		if test.want == 206 && !bytes.Equal(body, data[100000:]) {
			t.Fatal("incorrect resumed bytes")
		}
	}
	s.Cancel("", "phone-b")
	if _, err = s.Status(offer.ID); err != nil {
		t.Fatal("another phone cancelled transfer")
	}
	s.Cancel("", "phone-a")
	if _, err = s.Status(offer.ID); err == nil {
		t.Fatal("cancelled transfer retained")
	}
}
func TestRelayStreamingAndIsolation(t *testing.T) {
	h := &Hub{}
	r := RelayRegistration{ID: Token(), Read: Token(), Write: Token(), Room: "a", Size: 4 << 20}
	if h.Register(r) != nil {
		t.Fatal("register")
	}
	if h.Register(r) == nil {
		t.Fatal("duplicate registration")
	}
	server := httptest.NewServer(h)
	defer server.Close()
	req, _ := http.NewRequest("HEAD", server.URL+"/files/"+r.ID, nil)
	req.Header.Set("Authorization", "Bearer "+Token())
	resp, _ := server.Client().Do(req)
	_ = resp.Body.Close()
	if resp.StatusCode != 403 {
		t.Fatal("invalid capability")
	}
	data := bytes.Repeat([]byte{37}, int(r.Size))
	var wg sync.WaitGroup
	wg.Add(1)
	var produced error
	go func() {
		defer wg.Done()
		req, _ := http.NewRequest("PUT", server.URL+"/files/"+r.ID, bytes.NewReader(data))
		req.Header.Set("Authorization", "Bearer "+r.Write)
		resp, err := server.Client().Do(req)
		produced = err
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode != 204 {
				produced = fmt.Errorf("producer %d", resp.StatusCode)
			}
		}
	}()
	req, _ = http.NewRequest("GET", server.URL+"/files/"+r.ID, nil)
	req.Header.Set("Authorization", "Bearer "+r.Read)
	resp, err := server.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	wg.Wait()
	if err != nil || produced != nil || resp.StatusCode != 200 || !bytes.Equal(body, data) {
		t.Fatal("streaming failed", err, produced)
	}
	req, _ = http.NewRequest("GET", server.URL+"/files/"+r.ID, nil)
	req.Header.Set("Authorization", "Bearer "+r.Read)
	resp, _ = server.Client().Do(req)
	_ = resp.Body.Close()
	if resp.StatusCode != 404 {
		t.Fatal("completed capability reused")
	}
}
