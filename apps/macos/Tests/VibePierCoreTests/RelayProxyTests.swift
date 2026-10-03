import CFNetwork
import XCTest

@testable import VibePierCore

final class RelayProxyTests: XCTestCase {
    private let url = URL(string: "wss://relay.example.com/vibepier/relay")!

    func testHTTPParserAndDictionaryPreserveTheEndpointTLS() throws {
        let proxy = try XCTUnwrap(RelayHTTPProxy.parse("  http://LOCALHOST:51837/  "))
        XCTAssertEqual(proxy.host, "localhost")
        XCTAssertEqual(proxy.port, 51837)
        XCTAssertEqual(RelayHTTPProxy.parse("http://proxy.example.com")?.port, 80)
        XCTAssertEqual(RelayHTTPProxy.parse("http://[::1]:51837")?.host, "::1")
        XCTAssertEqual(proxy.connectionProxyDictionary[kCFNetworkProxiesHTTPProxy as String] as? String, "localhost")
        XCTAssertEqual(proxy.connectionProxyDictionary[kCFNetworkProxiesHTTPSProxy as String] as? String, "localhost")
        XCTAssertEqual(proxy.connectionProxyDictionary[kCFNetworkProxiesHTTPPort as String] as? Int, 51837)
        XCTAssertEqual(proxy.connectionProxyDictionary[kCFNetworkProxiesHTTPSPort as String] as? Int, 51837)
        XCTAssertEqual(url.absoluteString, "wss://relay.example.com/vibepier/relay")
        XCTAssertEqual(
            Set(proxy.connectionProxyDictionary.keys.compactMap { $0 as? String }),
            Set([
                kCFNetworkProxiesHTTPEnable as String, kCFNetworkProxiesHTTPProxy as String,
                kCFNetworkProxiesHTTPPort as String,
                kCFNetworkProxiesHTTPSEnable as String, kCFNetworkProxiesHTTPSProxy as String,
                kCFNetworkProxiesHTTPSPort as String,
            ]), "no TLS overrides or unrelated session options")
    }

    func testRejectsUnsupportedSchemesCredentialsAndMalformedProxyOrigins() {
        for raw in [
            "https://proxy.example:443", "socks5://localhost:51837", "proxy.example:80", "http://user@localhost:80",
            "http://user:password@localhost:80", "http://@localhost:80", "http://localhost:0", "http://localhost:65536",
            "http://localhost:bad", "http://bad host:80", "http://999.999.999.999:80", "http://-invalid.example:80",
            "http://localhost:80/path", "http://localhost:80?password=secret", "http://localhost:80#fragment",
            "http:///", "",
        ] {
            XCTAssertNil(RelayHTTPProxy.parse(raw), raw)
        }
    }

    func testDedicatedProxyTakesPriorityAndCanOverrideGenericNoProxy() {
        let values = [
            "VIBEPIER_RELAY_PROXY": "http://localhost:51837", "HTTPS_PROXY": "http://other.example:8080",
            "NO_PROXY": "*",
        ]
        XCTAssertEqual(
            RelayHTTPProxy.selected(for: url, environment: values), RelayHTTPProxy(host: "localhost", port: 51837))
        XCTAssertNil(
            RelayHTTPProxy.selected(
                for: url,
                environment: [
                    "VIBEPIER_RELAY_PROXY": "http://user:pass@localhost:51837",
                    "HTTPS_PROXY": "http://other.example:8080",
                ]), "invalid explicit route must not silently fall back")
        XCTAssertEqual(
            RelayHTTPProxy.selected(
                for: url, environment: ["VIBEPIER_RELAY_PROXY": " ", "HTTPS_PROXY": "http://other.example:8080"])?.host,
            "other.example")
    }

    func testGenericEnvironmentPriorityAndLowercaseCompatibility() {
        XCTAssertEqual(
            RelayHTTPProxy.selected(
                for: url,
                environment: ["HTTPS_PROXY": "http://secure.example:8080", "HTTP_PROXY": "http://plain.example:80"])?
                .host, "secure.example")
        XCTAssertEqual(
            RelayHTTPProxy.selected(for: url, environment: ["https_proxy": "http://lower.example:8080"])?.host,
            "lower.example")
        XCTAssertEqual(
            RelayHTTPProxy.selected(for: url, environment: ["HTTP_PROXY": "http://plain.example:80"])?.host,
            "plain.example")
        XCTAssertNil(RelayHTTPProxy.selected(for: url, environment: ["HTTPS_PROXY": "https://unsupported.example:443"]))
        let plain = URL(string: "ws://relay.example.com/vibepier/relay")!
        XCTAssertEqual(
            RelayHTTPProxy.selected(
                for: plain,
                environment: ["HTTP_PROXY": "http://plain.example:80", "HTTPS_PROXY": "http://secure.example:8080"])?
                .host, "plain.example")
    }

    func testNoProxyExactDomainSuffixAndWildcardRespectLabelBoundaries() {
        for exclusions in [
            "relay.example.com", ".example.com", "*.example.com", "EXAMPLE.COM.", "other.invalid, relay.example.com",
            "*",
        ] {
            XCTAssertNil(
                RelayHTTPProxy.selected(
                    for: url, environment: ["HTTPS_PROXY": "http://localhost:51837", "NO_PROXY": exclusions]),
                exclusions)
        }
        XCTAssertNotNil(
            RelayHTTPProxy.selected(
                for: URL(string: "wss://notexample.com/relay")!,
                environment: ["HTTPS_PROXY": "http://localhost:51837", "NO_PROXY": "example.com"]))
        XCTAssertNil(
            RelayHTTPProxy.selected(
                for: url, environment: ["https_proxy": "http://localhost:51837", "no_proxy": ".example.com"]))
        XCTAssertNil(
            RelayHTTPProxy.selected(
                for: url,
                environment: ["https_proxy": "http://localhost:51837", "NO_PROXY": " ", "no_proxy": ".example.com"]))
    }

    func testNoProxyLocalhostIPv6AndOptionalPorts() {
        for endpoint in ["ws://localhost/relay", "wss://127.0.0.1/relay", "wss://[::1]/relay"] {
            XCTAssertNil(
                RelayHTTPProxy.selected(
                    for: URL(string: endpoint)!,
                    environment: ["HTTP_PROXY": "http://proxy.example:8080", "NO_PROXY": "localhost"]), endpoint)
        }
        XCTAssertNil(
            RelayHTTPProxy.selected(
                for: url, environment: ["HTTPS_PROXY": "http://localhost:51837", "NO_PROXY": "relay.example.com:443"]))
        XCTAssertNotNil(
            RelayHTTPProxy.selected(
                for: url, environment: ["HTTPS_PROXY": "http://localhost:51837", "NO_PROXY": "relay.example.com:8443"]))
        XCTAssertNil(
            RelayHTTPProxy.selected(
                for: URL(string: "wss://[::1]:444/relay")!,
                environment: ["HTTPS_PROXY": "http://localhost:51837", "NO_PROXY": "[::1]:444"]))
        XCTAssertNil(
            RelayHTTPProxy.selected(
                for: URL(string: "wss://[0:0:0:0:0:0:0:1]:444/relay")!,
                environment: ["HTTPS_PROXY": "http://localhost:51837", "NO_PROXY": "[::1]:444"]))
        XCTAssertNotNil(
            RelayHTTPProxy.selected(
                for: URL(string: "wss://127.example.com/relay")!,
                environment: ["HTTPS_PROXY": "http://localhost:51837", "NO_PROXY": "localhost"]),
            "a numeric-looking domain is not localhost")
        XCTAssertNotNil(
            RelayHTTPProxy.selected(
                for: URL(string: "wss://example.127.0.0.1/relay")!,
                environment: ["HTTPS_PROXY": "http://localhost:51837", "NO_PROXY": "127.0.0.1"]),
            "IP exclusions do not act as domain suffixes")
    }
}
