// SPDX-License-Identifier: MIT
package main

import (
	"net/http"
	"testing"
)

func TestExplicitRelayProxyPolicy(t *testing.T) {
	request, _ := http.NewRequest("GET", "https://relay.example/files", nil)
	t.Setenv("NO_PROXY", "relay.example")
	for _, value := range []string{"http://127.0.0.1:7890", "http://[::1]:7890/"} {
		t.Setenv("VIBEPIER_RELAY_PROXY", value)
		proxy, err := fileHTTPProxy(request)
		if err != nil || proxy == nil || proxy.Scheme != "http" {
			t.Fatal("explicit proxy rejected")
		}
	}
	for _, value := range []string{"https://proxy.example", "http://user:password@proxy.example", "http://proxy.example/path", "http://proxy.example?key=value"} {
		t.Setenv("VIBEPIER_RELAY_PROXY", value)
		proxy, err := fileHTTPProxy(request)
		if err == nil || proxy != nil {
			t.Fatal("invalid proxy silently bypassed")
		}
	}
}
