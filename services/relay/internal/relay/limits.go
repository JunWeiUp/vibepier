// SPDX-License-Identifier: MIT

package relay

import (
	"regexp"
	"time"
)

const (
	maxHello        = 1024
	maxConnections  = 128
	maxFrame        = 1 << 20
	maxHostFrame    = 2 << 20 // base64 routing envelope around a 1 MiB payload
	maxClients      = 32
	maxQueued       = 4 << 20
	maxQueuedFrames = 2048 // normal encrypted Codex/APK bursts exceed 64 frames
	helloTimeout    = 10 * time.Second
	pingEvery       = 25 * time.Second
	idleTimeout     = 75 * time.Second
	clockSkew       = 120 * time.Second
	nonceTTL        = 5 * time.Minute
)

var roomPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
var peerPattern = regexp.MustCompile(`^[a-f0-9]{32}$`)
