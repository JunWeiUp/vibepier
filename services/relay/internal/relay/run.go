// SPDX-License-Identifier: MIT
package relay

import (
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

func readSecret(path string, environment string) ([]byte, error) {
	secret := strings.TrimSpace(environment)
	if secret == "" {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read relay secret: %w", err)
		}
		secret = strings.TrimSpace(string(data))
	}
	if len(secret) < 32 || len(secret) > 256 {
		return nil, errors.New("relay secret must contain between 32 and 256 bytes")
	}
	return []byte(secret), nil
}

// Run starts a self-hosted relay behind a TLS reverse proxy.
func Run(args []string) error {
	flags := flag.NewFlagSet("vibepier-relay", flag.ContinueOnError)
	listen := flags.String("listen", "127.0.0.1:47801", "address to listen on (behind a TLS reverse proxy)")
	secretPath := flags.String("secret", "/etc/vibepier-relay/secret", "file holding the shared secret")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	secret, err := readSecret(*secretPath, os.Getenv("VIBEPIER_RELAY_SECRET"))
	if err != nil {
		return err
	}
	router := &relay{secret: secret, rooms: map[string]*room{}, nonces: map[string]time.Time{}}
	server := &http.Server{
		Addr: *listen, Handler: router, MaxHeaderBytes: 16 << 10,
		ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 10 * time.Second,
		WriteTimeout: 10 * time.Second, IdleTimeout: idleTimeout,
	}
	log.Printf("vibepier-relay listening on %s", *listen)
	return server.ListenAndServe()
}
