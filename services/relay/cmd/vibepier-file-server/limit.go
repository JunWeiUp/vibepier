// SPDX-License-Identifier: MIT
package main

import (
	"net"
	"sync"
)

type boundedListener struct {
	net.Listener
	slots chan struct{}
}
type boundedConnection struct {
	net.Conn
	once  sync.Once
	slots chan struct{}
}

func (c *boundedConnection) Close() error {
	err := c.Conn.Close()
	c.once.Do(func() { <-c.slots })
	return err
}
func (l *boundedListener) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		select {
		case l.slots <- struct{}{}:
			return &boundedConnection{Conn: c, slots: l.slots}, nil
		default:
			_ = c.Close()
		}
	}
}
