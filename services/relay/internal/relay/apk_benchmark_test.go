package relay

// Synthetic endpoints exercise the real authenticated relay and WebSocket queues.
// This opt-in experiment measures the transfer policy, not real-device performance.
import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

type apkBenchmarkResult struct {
	RTTMS        int     `json:"rtt_ms"`
	Fragment     int     `json:"fragment_chars"`
	Window       int     `json:"window"`
	Frames       int     `json:"frames"`
	PeakBlocks   int     `json:"peak_blocks"`
	Seconds      float64 `json:"seconds"`
	MiBPerSecond float64 `json:"mib_per_second"`
	SyncMS       float64 `json:"write_sync_ms"`
}

func TestAPKRelayThroughput(t *testing.T) {
	if os.Getenv("VIBEPIER_APK_BENCHMARK") != "1" {
		t.Skip("opt-in synthetic APK relay benchmark")
	}
	var results []apkBenchmarkResult
	for _, rtt := range []int{20, 100, 200} {
		var runs []apkBenchmarkResult
		for _, profile := range [][2]int{{900, 1}, {7200, 4}} {
			t.Run(fmt.Sprintf("%dms-%dchars", rtt, profile[0]), func(t *testing.T) {
				result := benchmarkAPK(t, rtt, profile[0], profile[1])
				encoded, _ := json.Marshal(result)
				t.Log(string(encoded))
				runs = append(runs, result)
				results = append(results, result)
			})
		}
		if rtt == 100 && len(runs) == 2 && runs[0].Seconds/runs[1].Seconds < 2 {
			t.Errorf("100ms speedup below 2x: %+v", runs)
		}
	}
	if path := os.Getenv("VIBEPIER_APK_BENCHMARK_OUTPUT"); path != "" {
		encoded, _ := json.MarshalIndent(results, "", "  ")
		if err := os.WriteFile(path, encoded, 0600); err != nil {
			t.Fatal(err)
		}
	}
}

func benchmarkAPK(t *testing.T, rtt, fragment, window int) apkBenchmarkResult {
	const chunk = 128 * 1024
	const total = 2 * 1024 * 1024
	const device = "00000000-0000-4000-8000-000000000001"
	data := make([]byte, total)
	if _, err := rand.Read(data); err != nil {
		t.Fatal(err)
	}
	block, _ := aes.NewCipher(bytes.Repeat([]byte{31}, 32))
	gcm, _ := cipher.NewGCM(block)
	seal := func(clear []byte, aad string) []byte {
		nonce := make([]byte, gcm.NonceSize())
		if _, err := rand.Read(nonce); err != nil {
			panic(err)
		}
		return gcm.Seal(nonce, nonce, clear, []byte(aad))
	}
	open := func(sealed []byte, aad string) []byte {
		clear, err := gcm.Open(nil, sealed[:12], sealed[12:], []byte(aad))
		if err != nil {
			t.Fatal(err)
		}
		return clear
	}
	s := server()
	host := host2(t, s, "apk-benchmark")
	phone, peer := phone1(t, s, host, "apk-benchmark")
	type request struct {
		offset int
		ready  time.Time
	}
	requests := make(chan request, 4)
	readerDone, writerDone := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(readerDone)
		defer close(requests)
		for i := 0; i < total/chunk; i++ {
			id, body := from(t, host)
			offset, err := strconv.Atoi(body)
			if id != peer || err != nil || offset < 0 || offset+chunk > total {
				t.Error("invalid synthetic request")
				return
			}
			requests <- request{offset, time.Now().Add(time.Duration(rtt) * time.Millisecond)}
		}
	}()
	go func() {
		defer close(writerDone)
		sequence := 0
		for req := range requests {
			if wait := time.Until(req.ready); wait > 0 {
				time.Sleep(wait)
			}
			packet := fmt.Sprintf("00000000-0000-4000-8000-%012d", req.offset/chunk+1)
			clear, _ := json.Marshal(map[string]any{"id": packet, "ok": true, "offset": req.offset, "data": base64.StdEncoding.EncodeToString(data[req.offset : req.offset+chunk])})
			inner := base64.StdEncoding.EncodeToString(seal(clear, "vibepier-session-v1|mac|"+device+"|"+packet))
			count := (len(inner) + fragment - 1) / fragment
			for i := 0; i < count; i++ {
				end := (i + 1) * fragment
				if end > len(inner) {
					end = len(inner)
				}
				frame := map[string]any{"type": "vibepier-session1", "sender": device, "device": device, "packet": packet, "part": i, "parts": count, "data": inner[i*fragment : end]}
				if fragment == 7200 {
					frame["request"] = packet
				}
				plain, _ := json.Marshal(frame)
				if len(plain) > 8192 {
					t.Error("plaintext budget exceeded")
					return
				}
				sequence++
				seq := strconv.Itoa(sequence)
				aad := "vibepier-control-v1|mac|" + device + "|" + device + "|" + seq
				wire := "vibepier-secure1 " + device + " " + device + " " + seq + " " + base64.StdEncoding.EncodeToString(seal(plain, aad))
				if len(wire) > 16384 {
					t.Error("encrypted frame budget exceeded")
					return
				}
				host.send(directed(peer, wire))
			}
		}
	}()
	defer func() { host.raw.Close(); phone.raw.Close(); <-readerDone; <-writerDone }()
	file, err := os.Create(filepath.Join(t.TempDir(), "synthetic.apk"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	result := apkBenchmarkResult{RTTMS: rtt, Fragment: fragment, Window: window}
	next, durable, occupied := 0, 0, 0
	started := time.Now()
	fill := func() {
		for occupied < window && next < total {
			phone.send(strconv.Itoa(next))
			next += chunk
			occupied++
			if occupied > result.PeakBlocks {
				result.PeakBlocks = occupied
			}
		}
	}
	fill()
	var assembled strings.Builder
	for durable < total {
		wire := strings.Fields(phone.read(t))
		if len(wire) != 5 {
			t.Fatal("invalid encrypted frame")
		}
		sealed, err := base64.StdEncoding.DecodeString(wire[4])
		if err != nil {
			t.Fatal(err)
		}
		aad := "vibepier-control-v1|mac|" + device + "|" + device + "|" + wire[3]
		var frame struct {
			Packet      string
			Part, Parts int
			Data        string
		}
		if err := json.Unmarshal(open(sealed, aad), &frame); err != nil {
			t.Fatal(err)
		}
		result.Frames++
		assembled.WriteString(frame.Data)
		if frame.Part != frame.Parts-1 {
			continue
		}
		inner, err := base64.StdEncoding.DecodeString(assembled.String())
		if err != nil {
			t.Fatal(err)
		}
		assembled.Reset()
		var reply struct {
			Offset int
			Data   string
		}
		if err := json.Unmarshal(open(inner, "vibepier-session-v1|mac|"+device+"|"+frame.Packet), &reply); err != nil {
			t.Fatal(err)
		}
		payload, err := base64.StdEncoding.DecodeString(reply.Data)
		if err != nil || reply.Offset != durable || len(payload) != chunk {
			t.Fatal("non-contiguous synthetic reply")
		}
		writeStart := time.Now()
		if _, err := file.Write(payload); err != nil {
			t.Fatal(err)
		}
		if err := file.Sync(); err != nil {
			t.Fatal(err)
		}
		result.SyncMS += float64(time.Since(writeStart)) / float64(time.Millisecond)
		durable += len(payload)
		occupied--
		fill()
	}
	result.Seconds = time.Since(started).Seconds()
	result.MiBPerSecond = float64(total) / (1 << 20) / result.Seconds
	actual, err := os.ReadFile(file.Name())
	if err != nil || sha256.Sum256(actual) != sha256.Sum256(data) {
		t.Fatal("APK hash mismatch")
	}
	return result
}
