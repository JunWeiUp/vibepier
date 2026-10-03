package relay

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// All frame tests use memory buffers. No production relay or device is contacted.
type frameTestConn struct {
	net.Conn
	readDeadlines []time.Time
}

func (c *frameTestConn) Write(p []byte) (int, error)      { return len(p), nil }
func (c *frameTestConn) Close() error                     { return nil }
func (c *frameTestConn) SetWriteDeadline(time.Time) error { return nil }
func (c *frameTestConn) SetReadDeadline(t time.Time) error {
	c.readDeadlines = append(c.readDeadlines, t)
	return nil
}

func maskedFrame(header byte, payload []byte) []byte {
	frame := []byte{header}
	switch n := len(payload); {
	case n < 126:
		frame = append(frame, 0x80|byte(n))
	case n <= 65535:
		frame = append(frame, 0x80|126, byte(n>>8), byte(n))
	default:
		frame = append(frame, 0x80|127)
		frame = binary.BigEndian.AppendUint64(frame, uint64(n))
	}
	mask := [4]byte{1, 2, 3, 4}
	frame = append(frame, mask[:]...)
	for i, b := range payload {
		frame = append(frame, b^mask[i%4])
	}
	return frame
}

func frameReader(wire []byte, role string) (*conn, *frameTestConn) {
	raw := &frameTestConn{}
	return &conn{raw: raw, role: role, reader: bufio.NewReader(bytes.NewReader(wire))}, raw
}

func TestInvalidFramesRejectedBeforeApplicationDelivery(t *testing.T) {
	cases := map[string][]byte{
		"unmasked":                {0x81, 0},
		"reserved":                maskedFrame(0xC1, nil),
		"binary":                  maskedFrame(0x82, nil),
		"unknown-opcode":          maskedFrame(0x83, nil),
		"fragmented-ping":         maskedFrame(0x09, nil),
		"large-ping":              maskedFrame(0x89, bytes.Repeat([]byte{'a'}, 126)),
		"short-close":             maskedFrame(0x88, []byte{0}),
		"unexpected-continuation": maskedFrame(0x80, nil),
		"interleaved-message":     append(maskedFrame(0x01, []byte("first")), maskedFrame(0x81, []byte("other"))...),
		"bad-utf8":                maskedFrame(0x81, []byte{0xFF}),
		"negative-length":         {0x81, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 0},
		"nonminimal-short":        {0x81, 0xFE, 0, 125},
		"nonminimal-long":         {0x81, 0xFF, 0, 0, 0, 0, 0, 0, 0, 126},
	}
	for name, wire := range cases {
		t.Run(name, func(t *testing.T) {
			c, _ := frameReader(wire, "client")
			defer c.close()
			if value, err := c.next(); err == nil || value != "" {
				t.Fatalf("invalid frame delivered: %q, %v", value, err)
			}
		})
	}
}

func TestFragmentedUnicodeWithInterleavedPingAndNextMessage(t *testing.T) {
	wire := maskedFrame(0x01, []byte{0xE2})
	wire = append(wire, maskedFrame(0x89, []byte("ping"))...)
	wire = append(wire, maskedFrame(0x80, []byte{0x82, 0xAC})...)
	wire = append(wire, maskedFrame(0x81, []byte("next"))...)
	c, _ := frameReader(wire, "client")
	defer c.close()
	for _, expected := range []string{"€", "next"} {
		if value, err := c.next(); err != nil || value != expected {
			t.Fatalf("got %q, %v; expected %q", value, err, expected)
		}
	}
}

func TestUnauthenticatedFramesCannotRenewAdmissionDeadline(t *testing.T) {
	for _, role := range []string{"", "client"} {
		wire := append(maskedFrame(0x89, nil), maskedFrame(0x81, []byte("hello"))...)
		c, raw := frameReader(wire, role)
		defer c.close()
		if _, err := c.next(); err != nil {
			t.Fatal(err)
		}
		if role == "" && len(raw.readDeadlines) != 0 {
			t.Fatal("unauthenticated traffic extended the hello deadline")
		}
		if role != "" && len(raw.readDeadlines) != 2 {
			t.Fatal("authenticated traffic must renew idle deadline")
		}
	}
	c, _ := frameReader(maskedFrame(0x81, bytes.Repeat([]byte{'a'}, maxHello+1)), "")
	defer c.close()
	if _, err := c.next(); err == nil {
		t.Fatal("oversized hello accepted")
	}
}

func validUpgrade() *http.Request {
	req := httptest.NewRequest(http.MethodGet, "http://example.test/relay", nil)
	req.Header.Set("Connection", "keep-alive, Upgrade")
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set("Sec-WebSocket-Version", "13")
	// RFC 6455's public example nonce, encoded here so it is never mistaken for a stored credential.
	req.Header.Set("Sec-WebSocket-Key", base64.StdEncoding.EncodeToString([]byte("the sample nonce")))
	return req
}

func TestHTTPUpgradeValidationAndCapacityBeforeHijacking(t *testing.T) {
	for _, change := range []func(*http.Request){
		func(r *http.Request) { r.Method = http.MethodPost },
		func(r *http.Request) { r.Header.Del("Connection") },
		func(r *http.Request) { r.Header.Set("Sec-WebSocket-Version", "12") },
		func(r *http.Request) { r.Header.Set("Sec-WebSocket-Key", "eA==") },
		func(r *http.Request) { r.Header.Set("Upgrade", "not-websocket") },
	} {
		r := &relay{}
		req := validUpgrade()
		change(req)
		response := httptest.NewRecorder()
		r.ServeHTTP(response, req)
		if response.Code != http.StatusUpgradeRequired || r.connections.Load() != 0 {
			t.Fatal(response.Code)
		}
	}
	r := &relay{}
	r.connections.Store(maxConnections)
	response := httptest.NewRecorder()
	r.ServeHTTP(response, validUpgrade())
	if response.Code != http.StatusServiceUnavailable || r.connections.Load() != maxConnections {
		t.Fatal("connection cap not enforced")
	}
	r.connections.Store(0)
	response = httptest.NewRecorder()
	r.ServeHTTP(response, validUpgrade())
	if response.Code != http.StatusInternalServerError || r.connections.Load() != 0 {
		t.Fatal("failed hijack leaked a connection slot")
	}
}

func TestUpgradedConnectionReleasesCapacityOnDisconnect(t *testing.T) {
	r := &relay{}
	server := httptest.NewServer(r)
	defer server.Close()
	raw, err := net.DialTimeout("tcp", strings.TrimPrefix(server.URL, "http://"), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	_ = raw.SetDeadline(time.Now().Add(2 * time.Second))
	if err := validUpgrade().Write(raw); err != nil {
		t.Fatal(err)
	}
	response, err := http.ReadResponse(bufio.NewReader(raw), nil)
	if err != nil || response.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("upgrade: %v", err)
	}
	if r.connections.Load() != 1 {
		t.Fatal("missing live connection slot")
	}
	_ = raw.Close()
	until := time.Now().Add(time.Second)
	for r.connections.Load() != 0 && time.Now().Before(until) {
		time.Sleep(time.Millisecond)
	}
	if r.connections.Load() != 0 {
		t.Fatal("connection slot leaked")
	}
}
