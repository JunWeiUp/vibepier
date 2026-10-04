// SPDX-License-Identifier: MIT

package relay

import "sync/atomic"

// Counts queued and currently writing payloads across every room. The process
// also needs memory for readers, Go runtime and connection metadata; this is a
// sending budget, not a claim that total process RSS is bounded by this value.
const maxBufferedOutput = 12 << 20

type bufferBudget struct{ bytes atomic.Int64 }

func (b *bufferBudget) acquire(n int) bool {
	if b == nil {
		return true
	}
	for {
		used := b.bytes.Load()
		if int64(n) > maxBufferedOutput-used {
			return false
		}
		if b.bytes.CompareAndSwap(used, used+int64(n)) {
			return true
		}
	}
}

func (b *bufferBudget) release(n int) {
	if b != nil {
		b.bytes.Add(-int64(n))
	}
}

type closeReason uint32

const (
	closeNormal closeReason = iota + 1
	closeTimeout
	closeProtocol
	closeAuthentication
	closeSlowPeer
	closeCapacity
	closeWrite
	closeReplaced
)

func (r closeReason) String() string {
	switch r {
	case closeTimeout:
		return "timeout"
	case closeProtocol:
		return "protocol"
	case closeAuthentication:
		return "authentication"
	case closeSlowPeer:
		return "slow_peer"
	case closeCapacity:
		return "capacity"
	case closeWrite:
		return "write"
	case closeReplaced:
		return "replaced"
	default:
		return "closed"
	}
}
