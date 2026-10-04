// SPDX-License-Identifier: MIT

package relay

import (
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestOutputBudgetIncludesInFlightAndDrainsClosedPeers(t *testing.T) {
	var budget bufferBudget
	var peers []*conn
	for i := 0; i < 3; i++ {
		raw, reader := net.Pipe()
		defer reader.Close()
		c := &conn{raw: raw, budget: &budget}
		peers = append(peers, c)
		defer c.close()
		for j := 0; j < 4; j++ {
			if err := c.push(frame{opcode: 1, payload: make([]byte, 1<<20)}); err != nil {
				t.Fatal(err)
			}
		}
	}
	if got := budget.bytes.Load(); got != maxBufferedOutput {
		t.Fatalf("in-flight bytes escaped budget: %d", got)
	}
	raw, reader := net.Pipe()
	defer reader.Close()
	other := &conn{raw: raw, budget: &budget}
	defer other.close()
	if err := other.push(frame{opcode: 1, payload: []byte("no capacity")}); !errors.Is(err, errCapacity) {
		t.Fatalf("expected capacity, got %v", err)
	}
	for _, c := range peers {
		c.closeWith(closeCapacity)
	}
	deadline := time.Now().Add(2 * time.Second)
	for budget.bytes.Load() != 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if budget.bytes.Load() != 0 {
		t.Fatal("closed queues retained budget")
	}
	if err := other.push(frame{opcode: 1, payload: []byte("recovered")}); err != nil {
		t.Fatal(err)
	}
	other.close()
	deadline = time.Now().Add(2 * time.Second)
	for budget.bytes.Load() != 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if budget.bytes.Load() != 0 {
		t.Fatal("in-flight close did not release budget")
	}
}

func TestSendReportsCapacityBeforeGenericPingWriteFailure(t *testing.T) {
	var budget bufferBudget
	if !budget.acquire(maxBufferedOutput) {
		t.Fatal("cannot fill synthetic output budget")
	}
	defer budget.release(maxBufferedOutput)
	raw, reader := net.Pipe()
	defer reader.Close()
	c := &conn{raw: raw, budget: &budget}
	defer c.close()
	if err := c.send(0xA, []byte("pong")); !errors.Is(err, errCapacity) {
		t.Fatalf("expected capacity, got %v", err)
	}
	if closeReason(c.reason.Load()) != closeCapacity {
		t.Fatal("queue capacity was reported as a generic write/protocol failure")
	}
}

func TestConcurrentPushAndCloseDrainAllReservations(t *testing.T) {
	for attempt := 0; attempt < 30; attempt++ {
		var budget bufferBudget
		raw, reader := net.Pipe()
		var notices atomic.Int32
		c := &conn{raw: raw, budget: &budget, onClose: func(closeReason) { notices.Add(1) }}
		var workers sync.WaitGroup
		for worker := 0; worker < 8; worker++ {
			workers.Add(1)
			go func() {
				defer workers.Done()
				for i := 0; i < 64; i++ {
					if c.push(frame{opcode: 1, payload: make([]byte, 1024)}) != nil {
						return
					}
				}
			}()
		}
		c.closeWith(closeReplaced)
		workers.Wait()
		reader.Close()
		deadline := time.Now().Add(2 * time.Second)
		for budget.bytes.Load() != 0 && time.Now().Before(deadline) {
			time.Sleep(time.Millisecond)
		}
		if budget.bytes.Load() != 0 {
			t.Fatal("concurrent closure leaked output reservations")
		}
		if notices.Load() != 1 {
			t.Fatal("concurrent closure delivered more than one diagnostic")
		}
	}
}

func TestOutputBudgetConcurrentAcquisition(t *testing.T) {
	var budget bufferBudget
	var workers sync.WaitGroup
	for i := 0; i < 32; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for j := 0; j < 100; j++ {
				if budget.acquire(1 << 20) {
					if budget.bytes.Load() > maxBufferedOutput {
						t.Error("aggregate budget exceeded")
					}
					budget.release(1 << 20)
				}
			}
		}()
	}
	workers.Wait()
	if budget.bytes.Load() != 0 {
		t.Fatal("reservation leaked")
	}
}
