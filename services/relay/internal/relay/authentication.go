// SPDX-License-Identifier: MIT

package relay

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

func versionedHelloMAC(secret []byte, protocol, role, room, ts, nonce string) []byte {
	mac := hmac.New(sha256.New, secret)
	fmt.Fprintf(mac, "%s|%s|%s|%s|%s", protocol, role, room, ts, nonce)
	return mac.Sum(nil)
}

func currentRole(protocol int, role string) bool {
	return (protocol == 2 && role == "host") || (protocol == 1 && role == "client")
}

func (r *relay) verify(line string) (protocol int, role, roomName string, err error) {
	parts := strings.Fields(line)
	if len(parts) != 7 || (parts[0] != "vibepier-relay1" && parts[0] != "vibepier-relay2") || parts[1] != "hello" {
		return 0, "", "", errors.New("bad-hello")
	}
	protocol = 1
	if parts[0] == "vibepier-relay2" {
		protocol = 2
	}
	role, roomName = parts[2], parts[3]
	if !currentRole(protocol, role) {
		return 0, "", "", errors.New("bad-role")
	}
	if !roomPattern.MatchString(roomName) || len(parts[5]) < 16 || len(parts[5]) > 64 {
		return 0, "", "", errors.New("bad-room")
	}
	ts, convErr := strconv.ParseInt(parts[4], 10, 64)
	if convErr != nil || time.Since(time.Unix(ts, 0)).Abs() > clockSkew {
		return 0, "", "", errors.New("clock")
	}
	given, decodeErr := hex.DecodeString(parts[6])
	if decodeErr != nil || !hmac.Equal(given, versionedHelloMAC(r.secret, parts[0], role, roomName, parts[4], parts[5])) {
		return 0, "", "", errors.New("auth")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now()
	for k, seen := range r.nonces {
		if now.Sub(seen) > nonceTTL {
			delete(r.nonces, k)
		}
	}
	if _, used := r.nonces[parts[5]]; used || len(r.nonces) >= 10000 {
		return 0, "", "", errors.New("replay")
	}
	r.nonces[parts[5]] = now
	return protocol, role, roomName, nil
}
