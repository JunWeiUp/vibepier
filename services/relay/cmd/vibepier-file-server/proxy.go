// SPDX-License-Identifier: MIT
package main

import (
	"errors"
	"net/http"
	"net/url"
	"os"
	"strings"
)

// Matches the existing Mac relay's explicit proxy policy. Invalid explicit
// configuration must not silently bypass the proxy or expose HTTP credentials.
func fileHTTPProxy(request *http.Request) (*url.URL, error) {
	if explicit := strings.TrimSpace(os.Getenv("VIBEPIER_RELAY_PROXY")); explicit != "" {
		proxy, err := url.Parse(explicit)
		if err != nil || proxy.Scheme != "http" || proxy.Hostname() == "" || proxy.User != nil || proxy.RawQuery != "" || proxy.Fragment != "" || (proxy.Path != "" && proxy.Path != "/") {
			return nil, errors.New("invalid relay proxy")
		}
		return proxy, nil
	}
	return http.ProxyFromEnvironment(request)
}
