// SPDX-License-Identifier: MIT
package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"github.com/JunWeiUp/vibepier/services/relay/internal/filetransfer"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCloudBinaryProducerConsumerAndCancel(t *testing.T) {
	for _, kind := range []string{"apk", "upload", "cancel"} {
		t.Run(kind, func(t *testing.T) {
			hub := &filetransfer.Hub{}
			secret := "synthetic-secret-for-isolated-file-tests"
			registered := make(chan struct{})
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if strings.HasSuffix(r.URL.Path, "/register") {
					fields := strings.Fields(r.Header.Get("X-VibePier-Authorization"))
					if len(fields) != 7 {
						http.Error(w, "auth", 403)
						return
					}
					mac := hmac.New(sha256.New, []byte(secret))
					fmt.Fprintf(mac, "%s|%s|%s|%s|%s", fields[0], fields[2], fields[3], fields[4], fields[5])
					given, _ := hex.DecodeString(fields[6])
					if !hmac.Equal(given, mac.Sum(nil)) {
						http.Error(w, "auth", 403)
						return
					}
					var registration filetransfer.RelayRegistration
					if json.NewDecoder(r.Body).Decode(&registration) != nil || hub.Register(registration) != nil {
						http.Error(w, "invalid", 400)
						return
					}
					close(registered)
					w.WriteHeader(201)
					return
				}
				hub.ServeHTTP(w, r)
			}))
			defer server.Close()
			root := t.TempDir()
			store := &filetransfer.Store{Root: filepath.Join(root, "uploads")}
			data := bytes.Repeat([]byte{83}, 4<<20)
			path := filepath.Join(root, "snapshot.apk")
			_ = os.WriteFile(path, data, 0600)
			offerKind := kind
			if kind == "cancel" {
				offerKind = "upload"
			}
			offset := int64(0)
			if kind == "apk" {
				offset = 1 << 20
			}
			offer, err := store.Create(offerKind, "phone", "scope", path, int64(len(data)), offset)
			if err != nil {
				t.Fatal(err)
			}
			done := make(chan struct{})
			go func() {
				defer close(done)
				relayFile(server.Client(), relayConfig{url: server.URL + "/files", room: "fixture", secret: secret}, store, offer)
			}()
			select {
			case <-registered:
			case <-time.After(3 * time.Second):
				t.Fatal("registration timed out")
			}
			if kind == "cancel" {
				store.Cancel(offer.ID, "")
			} else if kind == "apk" {
				req, _ := http.NewRequest("GET", server.URL+"/files/"+offer.ID, nil)
				req.Header.Set("Authorization", "Bearer "+offer.Read)
				resp, err := server.Client().Do(req)
				if err != nil {
					t.Fatal(err)
				}
				body, e := io.ReadAll(resp.Body)
				_ = resp.Body.Close()
				if e != nil || !bytes.Equal(body, data[offset:]) {
					t.Fatal("cloud resumed APK mismatch")
				}
			} else {
				req, _ := http.NewRequest("PUT", server.URL+"/files/"+offer.ID, bytes.NewReader(data))
				req.Header.Set("Authorization", "Bearer "+offer.Write)
				resp, err := server.Client().Do(req)
				if err != nil {
					t.Fatal(err)
				}
				_ = resp.Body.Close()
				if resp.StatusCode != 204 {
					t.Fatal("cloud upload status", resp.StatusCode)
				}
			}
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				t.Fatal("cloud worker did not stop")
			}
			if kind == "upload" {
				status, err := store.Status(offer.ID)
				if err != nil || !status.Complete {
					t.Fatal("cloud upload not complete")
				}
				plain, _ := os.ReadFile(status.File)
				if !bytes.Equal(plain, data) {
					t.Fatal("cloud decrypted mismatch")
				}
			}
			req, _ := http.NewRequest("HEAD", server.URL+"/files/"+offer.ID, nil)
			req.Header.Set("Authorization", "Bearer "+offer.Read)
			resp, _ := server.Client().Do(req)
			_ = resp.Body.Close()
			if resp.StatusCode != 404 {
				t.Fatal("cloud capability retained after completion/cancel")
			}
		})
	}
}
