// SPDX-License-Identifier: MIT

package relay

import (
	"bufio"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"
)

type frame struct {
	opcode  byte
	payload []byte
	result  chan error
}

type conn struct {
	raw      net.Conn
	reader   *bufio.Reader
	once     sync.Once
	start    sync.Once
	queueMu  sync.Mutex
	queued   int
	outbound chan frame
	done     chan struct{}
	role     string
	room     string
	protocol int
	peerID   string
	order    uint64
	ready    bool // protected by relay.mu
	budget   *bufferBudget
	reason   atomic.Uint32
	onClose  func(closeReason)
}

var errSlowPeer = errors.New("slow-peer")
var errCapacity = errors.New("capacity")

func (c *conn) releaseFrame(f frame) {
	c.queueMu.Lock()
	c.queued -= len(f.payload)
	c.queueMu.Unlock()
	c.budget.release(len(f.payload))
}

func (c *conn) startWriter() {
	c.start.Do(func() {
		c.outbound = make(chan frame, maxQueuedFrames)
		c.done = make(chan struct{})
		go func() {
			defer func() {
				for {
					select {
					case f := <-c.outbound:
						c.releaseFrame(f)
						if f.result != nil {
							f.result <- net.ErrClosed
						}
					default:
						return
					}
				}
			}()
			for {
				select {
				case <-c.done:
					return
				case f := <-c.outbound:
					err := c.writeFrame(f.opcode, f.payload)
					c.releaseFrame(f)
					if f.result != nil {
						f.result <- err
					}
					if err != nil {
						c.closeWith(closeWrite)
						return
					}
				}
			}
		}()
	})
}

func (c *conn) push(f frame) error {
	c.startWriter()
	c.queueMu.Lock()
	defer c.queueMu.Unlock()
	select {
	case <-c.done:
		return net.ErrClosed
	default:
	}
	if c.queued+len(f.payload) > maxQueued {
		return errSlowPeer
	}
	if !c.budget.acquire(len(f.payload)) {
		return errCapacity
	}
	select {
	case c.outbound <- f:
		c.queued += len(f.payload)
		return nil
	default:
		c.budget.release(len(f.payload))
		return errSlowPeer
	}
}

func (c *conn) send(opcode byte, payload []byte) error {
	f := frame{opcode: opcode, payload: payload, result: make(chan error, 1)}
	if err := c.push(f); err != nil {
		c.closeWith(queueCloseReason(err))
		return err
	}
	select {
	case err := <-f.result:
		return err
	case <-c.done:
		return net.ErrClosed
	}
}

func (c *conn) writeFrame(opcode byte, payload []byte) error {
	header := []byte{0x80 | opcode}
	switch n := len(payload); {
	case n < 126:
		header = append(header, byte(n))
	case n <= 0xffff:
		header = append(header, 126, byte(n>>8), byte(n))
	default:
		header = append(header, 127)
		header = binary.BigEndian.AppendUint64(header, uint64(n))
	}
	_ = c.raw.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if _, err := c.raw.Write(append(header, payload...)); err != nil {
		return err
	}
	return nil
}

func (c *conn) text(s string) error { return c.send(1, []byte(s)) }

// A slow phone cannot block forwarding to the other phones. Its bounded writer
// queue preserves frame order and forces a reconnect instead of dropping replies.
func (c *conn) relayText(s string) {
	if err := c.push(frame{opcode: 1, payload: []byte(s)}); err != nil {
		c.closeWith(queueCloseReason(err))
	}
}

func queueCloseReason(err error) closeReason {
	if errors.Is(err, errCapacity) {
		return closeCapacity
	}
	if errors.Is(err, errSlowPeer) {
		return closeSlowPeer
	}
	return closeNormal
}

func (c *conn) close() {
	c.closeWith(closeNormal)
}

func (c *conn) closeWith(reason closeReason) {
	c.once.Do(func() {
		c.startWriter()
		c.reason.Store(uint32(reason))
		c.queueMu.Lock()
		close(c.done)
		c.queueMu.Unlock()
		_ = c.raw.Close()
		if c.onClose != nil {
			c.onClose(reason)
		}
	})
}

// next returns the next complete text message, answering pings itself.
func (c *conn) next() (string, error) {
	var message []byte
	fragmented := false
	for {
		var head [2]byte
		if _, err := io.ReadFull(c.reader, head[:]); err != nil {
			return "", err
		}
		fin, opcode := head[0]&0x80 != 0, head[0]&0x0f
		if head[0]&0x70 != 0 || (opcode != 0 && opcode != 1 && opcode != 8 && opcode != 9 && opcode != 10) {
			return "", errors.New("unsupported websocket frame")
		}
		if head[1]&0x80 == 0 {
			return "", errors.New("unmasked client frame")
		}
		length := uint64(head[1] & 0x7f)
		switch length {
		case 126:
			var ext [2]byte
			if _, err := io.ReadFull(c.reader, ext[:]); err != nil {
				return "", err
			}
			length = uint64(binary.BigEndian.Uint16(ext[:]))
			if length < 126 {
				return "", errors.New("nonminimal frame length")
			}
		case 127:
			var ext [8]byte
			if _, err := io.ReadFull(c.reader, ext[:]); err != nil {
				return "", err
			}
			length = binary.BigEndian.Uint64(ext[:])
			if length < 65536 || length>>63 != 0 {
				return "", errors.New("invalid frame length")
			}
		}
		if opcode >= 8 && (!fin || length > 125 || (opcode == 8 && length == 1)) {
			return "", errors.New("invalid control frame")
		}
		limit := uint64(maxFrame)
		if c.role == "" {
			limit = maxHello
		} else if c.protocol == 2 && c.role == "host" {
			limit = maxHostFrame
		}
		if length > limit || (opcode < 8 && uint64(len(message))+length > limit) {
			return "", errors.New("frame too large")
		}
		if (opcode == 0 && !fragmented) || (opcode == 1 && fragmented) {
			return "", errors.New("invalid continuation")
		}
		var mask [4]byte
		if _, err := io.ReadFull(c.reader, mask[:]); err != nil {
			return "", err
		}
		payload := make([]byte, length)
		if _, err := io.ReadFull(c.reader, payload); err != nil {
			return "", err
		}
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
		// Until admission succeeds the original hello deadline is absolute: pings
		// or partial fragments cannot keep an unauthenticated socket alive forever.
		if c.role != "" {
			_ = c.raw.SetReadDeadline(time.Now().Add(idleTimeout))
		}
		switch opcode {
		case 0x8:
			return "", io.EOF
		case 0x9:
			if err := c.send(0xA, payload); err != nil {
				return "", err
			}
			continue
		case 0xA:
			continue
		case 0x0, 0x1:
			message = append(message, payload...)
			if fin {
				if !utf8.Valid(message) {
					return "", errors.New("invalid text encoding")
				}
				return string(message), nil
			}
			fragmented = true
		default:
			return "", errors.New("bad opcode")
		}
	}
}
