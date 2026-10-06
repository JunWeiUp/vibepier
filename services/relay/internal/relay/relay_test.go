package relay

import (
	"bufio"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

const testSecret = "0123456789abcdef0123456789abcdef"

type client struct {
	raw    net.Conn
	reader *bufio.Reader
}

func dial(t *testing.T, r *relay) *client {
	t.Helper()
	near, far := net.Pipe()
	go r.serve(&conn{raw: far, reader: bufio.NewReader(far)}, "test")
	t.Cleanup(func() { _ = near.Close() })
	return &client{near, bufio.NewReader(near)}
}

func TestAcceptKey(t *testing.T) {
	if got := acceptKey("dGhlIHNhbXBsZSBub25jZQ=="); got != "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" {
		t.Fatal(got)
	}
}

func (c *client) send(s string) {
	payload := []byte(s)
	header := []byte{0x81}
	if len(payload) < 126 {
		header = append(header, 0x80|byte(len(payload)))
	} else if len(payload) <= 0xffff {
		header = append(header, 0x80|126, byte(len(payload)>>8), byte(len(payload)))
	} else {
		header = append(header, 0x80|127)
		header = binary.BigEndian.AppendUint64(header, uint64(len(payload)))
	}
	mask := []byte{1, 2, 3, 4}
	for i := range payload {
		payload[i] ^= mask[i%4]
	}
	c.raw.Write(append(append(header, mask...), payload...))
}

func (c *client) readTimeout(timeout time.Duration) (string, error) {
	c.raw.SetReadDeadline(time.Now().Add(timeout))
	for {
		var head [2]byte
		if _, err := io.ReadFull(c.reader, head[:]); err != nil {
			if err == io.EOF {
				return "<close>", nil
			}
			return "", err
		}
		length := uint64(head[1] & 0x7f)
		if length == 126 {
			var ext [2]byte
			if _, err := io.ReadFull(c.reader, ext[:]); err != nil {
				return "", err
			}
			length = uint64(binary.BigEndian.Uint16(ext[:]))
		} else if length == 127 {
			var ext [8]byte
			if _, err := io.ReadFull(c.reader, ext[:]); err != nil {
				return "", err
			}
			length = binary.BigEndian.Uint64(ext[:])
		}
		payload := make([]byte, length)
		if _, err := io.ReadFull(c.reader, payload); err != nil {
			return "", err
		}
		if head[0]&0x0f == 1 {
			return string(payload), nil
		}
		if head[0]&0x0f == 8 {
			return "<close>", nil
		}
	}
}

func (c *client) read(t *testing.T) string {
	t.Helper()
	line, err := c.readTimeout(3 * time.Second)
	if err != nil {
		t.Fatal(err)
	}
	return line
}

func (c *client) noMessage(t *testing.T) {
	t.Helper()
	if line, err := c.readTimeout(40 * time.Millisecond); err == nil {
		t.Fatalf("unexpected frame %q", line)
	} else if ne, ok := err.(net.Error); !ok || !ne.Timeout() {
		t.Fatal(err)
	}
}

func hello(role, room, secret string, ts int64) string {
	protocol := "vibepier-relay1"
	if role == "host" {
		protocol = "vibepier-relay2"
	}
	return helloVersion(protocol, role, room, secret, ts)
}

func helloVersion(protocol, role, room, secret string, ts int64) string {
	b := make([]byte, 12)
	rand.Read(b)
	nonce := hex.EncodeToString(b)
	mac := hmac.New(sha256.New, []byte(secret))
	fmt.Fprintf(mac, "%s|%s|%s|%d|%s", protocol, role, room, ts, nonce)
	return fmt.Sprintf("%s hello %s %s %d %s %s", protocol, role, room, ts, nonce, hex.EncodeToString(mac.Sum(nil)))
}

// Read shared HMAC vectors; the retired host1 vector is cryptographic history,
// not an admission contract. TestProtocolBoundAuthentication covers its rejection.
func TestHelloVector(t *testing.T) {
	data, err := os.ReadFile("../../../../protocol/fixtures/relay-hello.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors []struct {
		Protocol, Role, Room, Secret, Nonce, HMAC string
		Timestamp                                 int64
	}
	if err := json.Unmarshal(data, &vectors); err != nil {
		t.Fatal(err)
	}
	if len(vectors) != 3 {
		t.Fatalf("expected 3 shared vectors, got %d", len(vectors))
	}
	for _, vector := range vectors {
		got := hex.EncodeToString(versionedHelloMAC([]byte(vector.Secret), vector.Protocol, vector.Role, vector.Room,
			strconv.FormatInt(vector.Timestamp, 10), vector.Nonce))
		if got != vector.HMAC {
			t.Fatalf("%s/%s: unexpected signature %s", vector.Protocol, vector.Role, got)
		}
	}
}

func server() *relay {
	return &relay{secret: []byte(testSecret), rooms: map[string]*room{}, nonces: map[string]time.Time{}}
}

func TestForwardBothWays(t *testing.T) {
	s := server()
	host := host2(t, s, "home")
	phone, peer := phone1(t, s, host, "home")
	phone.send("vibepier1 abc 1 talk down rcmd")
	if id, body := from(t, host); id != peer || body != "vibepier1 abc 1 talk down rcmd" {
		t.Fatal(id, body)
	}
	big := strings.Repeat("x", 200000)
	host.send(directed(peer, big))
	if got := phone.read(t); got != big {
		t.Fatal("big frame mismatch", len(got))
	}
	phone.raw.Close()
	if got := host.read(t); got != "vibepier-relay2 peer down "+peer {
		t.Fatal(got)
	}
}

func TestRejectsBadAuthAndReplay(t *testing.T) {
	s := server()
	bad := dial(t, s)
	bad.send(hello("host", "home", "wrong-secret-wrong-secret-wrong!!", time.Now().Unix()))
	if got := bad.read(t); got != "vibepier-relay2 error auth" {
		t.Fatal(got)
	}
	old := dial(t, s)
	old.send(hello("host", "home", testSecret, time.Now().Unix()-600))
	if got := old.read(t); got != "vibepier-relay2 error clock" {
		t.Fatal(got)
	}
	line := hello("client", "home", testSecret, time.Now().Unix())
	first := dial(t, s)
	first.send(line)
	if got := first.read(t); got != "vibepier-relay1 ok" {
		t.Fatal(got)
	}
	again := dial(t, s)
	again.send(line)
	if got := again.read(t); got != "vibepier-relay1 error replay" {
		t.Fatal(got)
	}
}

func TestNewHostReplacesOnlyHost(t *testing.T) {
	s := server()
	first := host2(t, s, "r")
	second := host2(t, s, "r")
	if got := first.read(t); got != "<close>" {
		t.Fatal(got)
	}
	phone, peer := phone1(t, s, second, "r")
	phone.send("ping-through")
	if id, body := from(t, second); id != peer || body != "ping-through" {
		t.Fatal(id, body)
	}
}

func host2(t *testing.T, s *relay, roomName string) *client {
	t.Helper()
	c := dial(t, s)
	c.send(helloVersion("vibepier-relay2", "host", roomName, testSecret, time.Now().Unix()))
	if got := c.read(t); got != "vibepier-relay2 ok" {
		t.Fatal(got)
	}
	return c
}

func phone1(t *testing.T, s *relay, host *client, roomName string) (*client, string) {
	t.Helper()
	c := dial(t, s)
	c.send(hello("client", roomName, testSecret, time.Now().Unix()))
	if got := c.read(t); got != "vibepier-relay1 ok" {
		t.Fatal(got)
	}
	if got := c.read(t); got != "vibepier-relay1 peer up" {
		t.Fatal(got)
	}
	line := host.read(t)
	parts := strings.Fields(line)
	if len(parts) != 4 || strings.Join(parts[:3], " ") != "vibepier-relay2 peer up" || !peerPattern.MatchString(parts[3]) {
		t.Fatal(line)
	}
	return c, parts[3]
}

func directed(id, body string) string {
	return "vibepier-relay2 to " + id + " " + base64.StdEncoding.EncodeToString([]byte(body))
}

func from(t *testing.T, c *client) (string, string) {
	t.Helper()
	line := c.read(t)
	parts := strings.SplitN(line, " ", 4)
	if len(parts) != 4 || parts[0] != "vibepier-relay2" || parts[1] != "from" || !peerPattern.MatchString(parts[2]) {
		t.Fatal(line)
	}
	body, err := base64.StdEncoding.Strict().DecodeString(parts[3])
	if err != nil {
		t.Fatal(err)
	}
	return parts[2], string(body)
}

func TestMultiplePhonesDirectedRepliesAndIsolation(t *testing.T) {
	s := server()
	host := host2(t, s, "many")
	first, firstID := phone1(t, s, host, "many")
	second, secondID := phone1(t, s, host, "many")
	if firstID == secondID {
		t.Fatal("route collision")
	}
	first.noMessage(t) // connecting another phone must neither replace nor notify this one

	requests := map[string]string{firstID: "{\"type\":\"vibepier-session1\",\"body\":\"encrypted first\"}\n中文", secondID: "vibepier-watch1 second"}
	go first.send(requests[firstID])
	go second.send(requests[secondID])
	seen := map[string]bool{}
	for range 2 {
		id, body := from(t, host)
		if seen[id] || requests[id] != body {
			t.Fatalf("mixed request %q %q", id, body)
		}
		seen[id] = true
	}
	host.send(directed(secondID, "reply only second"))
	host.send(directed(firstID, "reply only first"))
	if got := first.read(t); got != "reply only first" {
		t.Fatal(got)
	}
	if got := second.read(t); got != "reply only second" {
		t.Fatal(got)
	}
	first.noMessage(t)
	second.noMessage(t)

	// Hosts must use a route. Phones cannot forge either protocol's reserved frames.
	host.send("unsafe unwrapped reply")
	first.send(directed(secondID, "forged reply"))
	first.send("vibepier-relay1 peer down")
	host.noMessage(t)
	first.noMessage(t)
	second.noMessage(t)

	first.raw.Close()
	if got := host.read(t); got != "vibepier-relay2 peer down "+firstID {
		t.Fatal(got)
	}
	second.noMessage(t)
	host.send(directed(firstID, "late reply to disconnected phone"))
	second.noMessage(t)
	second.send("still connected")
	if id, body := from(t, host); id != secondID || body != "still connected" {
		t.Fatalf("%q %q", id, body)
	}
}

func TestReplacingHostKeepsAllPhoneRoutes(t *testing.T) {
	s := server()
	old := host2(t, s, "replace")
	first, firstID := phone1(t, s, old, "replace")
	second, secondID := phone1(t, s, old, "replace")
	newHost := host2(t, s, "replace")
	if got := old.read(t); got != "<close>" {
		t.Fatal(got)
	}
	for _, phone := range []*client{first, second} {
		if got := phone.read(t); got != "vibepier-relay1 peer down" {
			t.Fatal(got)
		}
		if got := phone.read(t); got != "vibepier-relay1 peer up" {
			t.Fatal(got)
		}
	}
	routes := map[string]bool{firstID: false, secondID: false}
	for range 2 {
		line := newHost.read(t)
		id := strings.TrimPrefix(line, "vibepier-relay2 peer up ")
		if _, exists := routes[id]; !exists || routes[id] {
			t.Fatal(line)
		}
		routes[id] = true
	}
	newHost.send(directed(firstID, "after host replacement"))
	if got := first.read(t); got != "after host replacement" {
		t.Fatal(got)
	}
	newHost.noMessage(t)
	second.noMessage(t) // old host's deferred leave cannot remove its successor
	newHost.raw.Close()
	for _, phone := range []*client{first, second} {
		if got := phone.read(t); got != "vibepier-relay1 peer down" {
			t.Fatal(got)
		}
	}
	returning := host2(t, s, "replace")
	for _, phone := range []*client{first, second} {
		if got := phone.read(t); got != "vibepier-relay1 peer up" {
			t.Fatal(got)
		}
	}
	returning.read(t)
	returning.read(t)
	second.send("survives host outage")
	if id, body := from(t, returning); id != secondID || body != "survives host outage" {
		t.Fatalf("%q %q", id, body)
	}
}

func TestPhonesCanJoinBeforeHostAndReconnectIndependently(t *testing.T) {
	s := server()
	first := dial(t, s)
	first.send(hello("client", "offline", testSecret, time.Now().Unix()))
	first.read(t)
	second := dial(t, s)
	second.send(hello("client", "offline", testSecret, time.Now().Unix()))
	second.read(t)
	first.noMessage(t)
	host := host2(t, s, "offline")
	first.read(t)
	second.read(t)
	ids := map[string]bool{}
	for range 2 {
		ids[strings.TrimPrefix(host.read(t), "vibepier-relay2 peer up ")] = true
	}
	first.send("first before reconnect")
	firstID, _ := from(t, host)
	first.raw.Close()
	if got := host.read(t); got != "vibepier-relay2 peer down "+firstID {
		t.Fatal(got)
	}
	newFirst, newID := phone1(t, s, host, "offline")
	if ids[newID] {
		t.Fatal("reconnected route ID was reused")
	}
	second.noMessage(t)
	host.send(directed(firstID, "stale"))
	newFirst.noMessage(t)
	second.noMessage(t)
	host.send(directed(newID, "new connection"))
	if got := newFirst.read(t); got != "new connection" {
		t.Fatal(got)
	}
}

func TestLegacyHostRejectedWithoutReplacingCurrentHostOrPhones(t *testing.T) {
	s := server()
	host := host2(t, s, "migration")
	first, firstID := phone1(t, s, host, "migration")
	second, secondID := phone1(t, s, host, "migration")
	old := dial(t, s)
	old.send(helloVersion("vibepier-relay1", "host", "migration", testSecret, time.Now().Unix()))
	if got := old.read(t); got != "vibepier-relay1 error bad-role" {
		t.Fatal(got)
	}
	if got := old.read(t); got != "<close>" {
		t.Fatal(got)
	}
	host.noMessage(t)
	first.noMessage(t)
	second.noMessage(t)
	first.send("first retained")
	if id, body := from(t, host); id != firstID || body != "first retained" {
		t.Fatal(id, body)
	}
	host.send(directed(secondID, "second retained"))
	if got := second.read(t); got != "second retained" {
		t.Fatal(got)
	}
}

func TestLegacyHostRejectedWithoutDroppingOfflinePhones(t *testing.T) {
	s := server()
	phones := []*client{dial(t, s), dial(t, s)}
	for _, phone := range phones {
		phone.send(hello("client", "offline-old", testSecret, time.Now().Unix()))
		if got := phone.read(t); got != "vibepier-relay1 ok" {
			t.Fatal(got)
		}
	}
	old := dial(t, s)
	old.send(helloVersion("vibepier-relay1", "host", "offline-old", testSecret, time.Now().Unix()))
	if got := old.read(t); got != "vibepier-relay1 error bad-role" {
		t.Fatal(got)
	}
	if got := old.read(t); got != "<close>" {
		t.Fatal(got)
	}
	for _, phone := range phones {
		phone.noMessage(t)
	}
	host := host2(t, s, "offline-old")
	peers := map[string]bool{}
	for _, phone := range phones {
		if got := phone.read(t); got != "vibepier-relay1 peer up" {
			t.Fatal(got)
		}
		peers[strings.TrimPrefix(host.read(t), "vibepier-relay2 peer up ")] = true
	}
	for i, phone := range phones {
		body := fmt.Sprintf("retained-%d", i)
		phone.send(body)
		id, got := from(t, host)
		if !peers[id] || got != body {
			t.Fatal(id, got)
		}
		delete(peers, id)
	}
	if len(peers) != 0 {
		t.Fatal("phone routing identity was lost")
	}
}

func TestFileRegistrationRequiresCurrentHostContract(t *testing.T) {
	for _, tc := range []struct {
		protocol, role string
		status         int
	}{
		{"vibepier-relay1", "host", http.StatusForbidden},
		{"vibepier-relay2", "client", http.StatusForbidden},
		{"vibepier-relay1", "client", http.StatusForbidden},
		{"vibepier-relay2", "host", http.StatusCreated},
	} {
		t.Run(tc.protocol+"/"+tc.role, func(t *testing.T) {
			s := server()
			id, read, write := strings.Repeat("a", 64), strings.Repeat("b", 64), strings.Repeat("c", 64)
			body := fmt.Sprintf(`{"id":%q,"read":%q,"write":%q,"room":"files","size":4}`, id, read, write)
			hello := helloVersion(tc.protocol, tc.role, "files", testSecret, time.Now().Unix())
			register := func() int {
				req := httptest.NewRequest(http.MethodPost, "/files/register", strings.NewReader(body))
				req.Header.Set("X-VibePier-Authorization", hello)
				response := httptest.NewRecorder()
				s.ServeHTTP(response, req)
				return response.Code
			}
			if got := register(); got != tc.status {
				t.Fatal(got)
			}
			if tc.status == http.StatusCreated {
				if got := register(); got != http.StatusForbidden {
					t.Fatal("file registration replay accepted", got)
				}
				for _, token := range []string{strings.Repeat("d", 64), read} {
					req := httptest.NewRequest(http.MethodDelete, "/files/"+id, nil)
					req.Header.Set("Authorization", "Bearer "+token)
					response := httptest.NewRecorder()
					s.ServeHTTP(response, req)
					expected := http.StatusForbidden
					if token == read {
						expected = http.StatusNoContent
					}
					if response.Code != expected {
						t.Fatal(response.Code)
					}
				}
			}
		})
	}
}

func TestHostCannotRouteToAnotherRoom(t *testing.T) {
	s := server()
	firstHost := host2(t, s, "room-a")
	firstPhone, firstID := phone1(t, s, firstHost, "room-a")
	secondHost := host2(t, s, "room-b")
	secondPhone, secondID := phone1(t, s, secondHost, "room-b")
	firstHost.send(directed(secondID, "foreign room"))
	firstPhone.noMessage(t)
	secondPhone.noMessage(t)
	firstHost.send("unwrapped reply")
	firstPhone.noMessage(t)
	firstHost.send(directed(firstID, "own phone"))
	if got := firstPhone.read(t); got != "own phone" {
		t.Fatal(got)
	}
	secondPhone.noMessage(t)
}

func TestLargeDirectedPayloadAndMalformedEnvelope(t *testing.T) {
	s := server()
	host := host2(t, s, "large")
	phone, id := phone1(t, s, host, "large")
	big := strings.Repeat("x", maxFrame)
	phone.send(big)
	if gotID, body := from(t, host); gotID != id || body != big {
		t.Fatal("large upstream mismatch")
	}
	host.send(directed(id, big)) // wire frame is larger than 1 MiB after base64
	if got := phone.read(t); got != big {
		t.Fatal("large downstream mismatch")
	}
	for _, line := range []string{"vibepier-relay2 to " + id + " ###", directed(id, big+"x"), directed(strings.Repeat("0", 32), "absent")} {
		host.send(line)
		phone.noMessage(t)
	}
	host.send(directed(id, "valid afterwards"))
	if got := phone.read(t); got != "valid afterwards" {
		t.Fatal(got)
	}
}

func TestConnectionLimitAndStaleLeave(t *testing.T) {
	s := server()
	phones := make([]*conn, maxClients)
	for i := range phones {
		phones[i] = &conn{role: "client", room: "limit", protocol: 1, peerID: fmt.Sprintf("%032x", i+1)}
		if _, _, err := s.join(phones[i]); err != nil {
			t.Fatal(err)
		}
	}
	extra := &conn{role: "client", room: "limit", protocol: 1, peerID: fmt.Sprintf("%032x", maxClients+1)}
	if _, _, err := s.join(extra); err == nil || err.Error() != "too-many-clients" {
		t.Fatal(err)
	}
	s.leave(phones[0])
	if _, _, err := s.join(extra); err != nil {
		t.Fatal(err)
	}
	if got := s.leave(phones[0]); len(got) != 0 {
		t.Fatal("duplicate leave affected room")
	}
	s.mu.Lock()
	if len(s.rooms["limit"].clients) != maxClients {
		t.Fatal("room lost another phone")
	}
	s.mu.Unlock()
}

func TestProtocolBoundAuthentication(t *testing.T) {
	s := server()
	for _, contract := range []struct {
		version int
		role    string
	}{{1, "host"}, {2, "client"}, {0, "host"}} {
		if _, _, err := s.join(&conn{protocol: contract.version, role: contract.role, room: "rejected"}); err == nil {
			t.Fatal("unsupported contract entered room")
		}
	}
	if len(s.rooms) != 0 {
		t.Fatal("rejected contracts changed room state")
	}
	retired := helloVersion("vibepier-relay1", "host", "bound", testSecret, time.Now().Unix())
	if _, _, _, err := s.verify(retired); err == nil || err.Error() != "bad-role" {
		t.Fatal("retired host admitted", err)
	}

	line := helloVersion("vibepier-relay1", "host", "bound", testSecret, time.Now().Unix())
	_, _, _, err := s.verify(strings.Replace(line, "vibepier-relay1 hello", "vibepier-relay2 hello", 1))
	if err == nil || err.Error() != "auth" {
		t.Fatal("protocol change not bound", err)
	}
	line = helloVersion("vibepier-relay2", "host", "bound", testSecret, time.Now().Unix())
	if version, role, _, err := s.verify(line); err != nil || version != 2 || role != "host" {
		t.Fatal(version, role, err)
	}
	line = helloVersion("vibepier-relay2", "client", "bound", testSecret, time.Now().Unix())
	if _, _, _, err := s.verify(line); err == nil || err.Error() != "bad-role" {
		t.Fatal(err)
	}
}

// These manually joined connections make ordering assertions deterministic:
// state operations themselves must enqueue notices, without deferred caller work.
func rawPair(t *testing.T, role string, protocol int, roomName, id string) (*conn, *client) {
	t.Helper()
	near, far := net.Pipe()
	c := &conn{raw: far, reader: bufio.NewReader(far), role: role, protocol: protocol, room: roomName, peerID: id}
	t.Cleanup(func() { c.close(); _ = near.Close() })
	return c, &client{raw: near, reader: bufio.NewReader(near)}
}

func TestTopologyNoticesAreQueuedAtStateChange(t *testing.T) {
	s := server()
	phone, phoneReader := rawPair(t, "client", 1, "order", strings.Repeat("a", 32))
	s.join(phone)
	s.activate(phone)
	old, oldReader := rawPair(t, "host", 2, "order", "")
	s.join(old)
	s.activate(old)
	phoneReader.read(t)
	oldReader.read(t)
	fresh, freshReader := rawPair(t, "host", 2, "order", "")
	s.join(fresh)     // down must already be queued before this returns
	s.activate(fresh) // then up; an obsolete leave cannot send another down
	s.leave(old)
	if got := phoneReader.read(t); got != "vibepier-relay1 peer down" {
		t.Fatal(got)
	}
	if got := phoneReader.read(t); got != "vibepier-relay1 peer up" {
		t.Fatal(got)
	}
	freshReader.read(t)
	phoneReader.noMessage(t)

	s.forward(phone, "before disconnect")
	s.leave(phone)
	s.forward(phone, "after disconnect")
	if id, body := from(t, freshReader); id != phone.peerID || body != "before disconnect" {
		t.Fatal(id, body)
	}
	if got := freshReader.read(t); got != "vibepier-relay2 peer down "+phone.peerID {
		t.Fatal(got)
	}
	freshReader.noMessage(t)
}

func TestNormalFragmentBurstExceeds64FramesWithoutDisconnect(t *testing.T) {
	s := server()
	phone, phoneReader := rawPair(t, "client", 1, "burst", strings.Repeat("b", 32))
	s.join(phone)
	s.activate(phone)
	host, hostReader := rawPair(t, "host", 2, "burst", "")
	s.join(host)
	s.activate(host)
	phoneReader.read(t)
	hostReader.read(t)
	// Pause each reader while queuing an entire >128 KiB encrypted message.
	// A healthy reader can resume after the producer finishes its normal burst.
	for i := range 256 {
		s.forward(phone, fmt.Sprintf("fragment-%03d-%s", i, strings.Repeat("x", 900)))
	}
	for i := range 256 {
		id, body := from(t, hostReader)
		if id != phone.peerID || body != fmt.Sprintf("fragment-%03d-%s", i, strings.Repeat("x", 900)) {
			t.Fatal("upstream burst order", i)
		}
	}
	for i := range 256 {
		s.forward(host, directed(phone.peerID, fmt.Sprintf("reply-%03d-%s", i, strings.Repeat("y", 900))))
	}
	for i := range 256 {
		if got := phoneReader.read(t); got != fmt.Sprintf("reply-%03d-%s", i, strings.Repeat("y", 900)) {
			t.Fatal("downstream burst order", i)
		}
	}
	phoneReader.noMessage(t)
	hostReader.noMessage(t)
}

func TestSlowPhoneIsolatedFromOtherPhoneAndHost(t *testing.T) {
	s := server()
	host := host2(t, s, "slow")
	_, slowID := phone1(t, s, host, "slow")
	fast, fastID := phone1(t, s, host, "slow")
	started := time.Now()
	// The slow phone never reads these outputs. Its writer and byte queue fill;
	// the host's receive loop must keep running and only this phone is closed.
	payload := strings.Repeat("z", 128<<10)
	for range 40 {
		host.send(directed(slowID, payload))
	}
	host.send(directed(fastID, "healthy phone reply"))
	if got := fast.read(t); got != "healthy phone reply" {
		t.Fatal(got)
	}
	if time.Since(started) > 2*time.Second {
		t.Fatal("slow phone stalled other routes")
	}
	if got := host.read(t); got != "vibepier-relay2 peer down "+slowID {
		t.Fatal(got)
	}
	fast.send("healthy upstream")
	if id, body := from(t, host); id != fastID || body != "healthy upstream" {
		t.Fatal(id, body)
	}
	fast.noMessage(t)
}

func TestConcurrentLeaveNeverQueuesFromAfterPeerDown(t *testing.T) {
	for attempt := range 12 {
		s := server()
		phone, phoneReader := rawPair(t, "client", 1, "race", fmt.Sprintf("%032x", attempt+1))
		s.join(phone)
		s.activate(phone)
		host, hostReader := rawPair(t, "host", 2, "race", "")
		s.join(host)
		s.activate(host)
		phoneReader.read(t)
		hostReader.read(t)
		var work sync.WaitGroup
		start := make(chan struct{})
		for range 32 {
			work.Add(1)
			go func() { defer work.Done(); <-start; s.forward(phone, "watch during disconnect") }()
		}
		work.Add(1)
		go func() { defer work.Done(); <-start; s.leave(phone) }()
		close(start)
		work.Wait()
		for {
			line := hostReader.read(t)
			if line == "vibepier-relay2 peer down "+phone.peerID {
				break
			}
			if !strings.HasPrefix(line, "vibepier-relay2 from "+phone.peerID+" ") {
				t.Fatal(line)
			}
		}
		hostReader.noMessage(t)
		phone.close()
		host.close()
	}
}
