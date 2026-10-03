import XCTest

@testable import VibePierCore

final class DirectAdmissionsTests: XCTestCase {
    private let a = String(repeating: "a", count: 32)
    private let b = String(repeating: "b", count: 32)
    private let c = String(repeating: "c", count: 32)

    func testEachPublicEndpointAdmitsOnlyItsPhoneAndWrongTrafficDoesNotRenewLease() {
        var access = DirectAdmissions()
        XCTAssertTrue(access.offer(sender: "phone-a", token: a, now: 0))
        XCTAssertTrue(access.offer(sender: "phone-b", token: b, now: 0))
        XCTAssertFalse(access.admit(endpoint: "public-a:1", sender: "phone-b", token: a, now: 0))
        XCTAssertTrue(access.admit(endpoint: "public-a:1", sender: "phone-a", token: a, now: 0))
        XCTAssertTrue(access.admit(endpoint: "public-b:2", sender: "phone-b", token: b, now: 0))
        XCTAssertFalse(access.allows(endpoint: "public-a:1", sender: "phone-b", now: 59))
        XCTAssertFalse(access.admit(endpoint: "public-a:1", sender: "phone-b", token: b, now: 59))
        XCTAssertFalse(access.allows(endpoint: "public-a:1", sender: "phone-a", now: 60))
        XCTAssertTrue(access.allows(endpoint: "public-b:2", sender: "phone-b", now: 59))
        XCTAssertTrue(
            access.allows(endpoint: "public-b:2", sender: "phone-b", now: 70), "another phone's expiry is independent")
    }

    func testRepeatedOffersReplaceOnlyThatPhonesTokenAndKeepEstablishedPath() {
        var access = DirectAdmissions()
        XCTAssertTrue(access.offer(sender: "phone-a", token: a, now: 0))
        XCTAssertTrue(access.offer(sender: "phone-b", token: b, now: 0))
        XCTAssertTrue(access.admit(endpoint: "public-a:1", sender: "phone-a", token: a, now: 0))
        XCTAssertTrue(access.offer(sender: "phone-a", token: c, now: 1))
        XCTAssertFalse(access.hasToken(a, sender: "phone-a", now: 1))
        XCTAssertTrue(access.hasToken(c, sender: "phone-a", now: 1))
        XCTAssertTrue(access.hasToken(b, sender: "phone-b", now: 1))
        XCTAssertTrue(access.allows(endpoint: "public-a:1", sender: "phone-a", now: 2))
        XCTAssertFalse(access.offer(sender: "phone-b", token: c, now: 2), "a token cannot be rebound to another phone")
        XCTAssertTrue(access.hasToken(b, sender: "phone-b", now: 2))
        access.removeAll()
        XCTAssertFalse(access.allows(endpoint: "public-a:1", sender: "phone-a", now: 3))
        XCTAssertFalse(access.hasToken(c, sender: "phone-a", now: 3))
    }

    func testManyRetriesByOnePhoneDoNotConsumeOtherPhonesSlots() {
        var access = DirectAdmissions()
        for attempt in 0..<100 {
            let token = String(repeating: "0", count: 30) + String(format: "%02x", attempt)
            XCTAssertTrue(access.offer(sender: "phone-0", token: token, now: 0))
        }
        for phone in 1..<32 {
            let token = String(repeating: "f", count: 30) + String(format: "%02x", phone)
            XCTAssertTrue(access.offer(sender: "phone-\(phone)", token: token, now: 0))
        }
        XCTAssertFalse(access.offer(sender: "phone-extra", token: a, now: 1))
        XCTAssertTrue(access.offer(sender: "phone-0", token: b, now: 1), "existing phone can refresh even at capacity")
        XCTAssertFalse(access.offer(sender: "phone-extra", token: "wrong", now: 1))
        XCTAssertTrue(access.offer(sender: "phone-extra", token: a, now: 120), "expired slots can be reused")
    }

    func testRecognizesSendersBeforeGrantingInternetTraffic() {
        XCTAssertEqual(DirectAdmissions.sender(in: "vibepier-watch1 phone-a"), "phone-a")
        XCTAssertEqual(DirectAdmissions.sender(in: "vibepier1 phone-b 1 talk down rcmd"), "phone-b")
        XCTAssertEqual(DirectAdmissions.sender(in: "vibepier-audio1 phone-a session 1 AAAA"), "phone-a")
        XCTAssertEqual(DirectAdmissions.sender(in: #"{"type":"vibepier-session1","sender":"phone-b"}"#), "phone-b")
        XCTAssertNil(DirectAdmissions.sender(in: "vibepier-watch1"))
        XCTAssertNil(DirectAdmissions.sender(in: "vibepier1 phone-a 1 talk invalid"))
        XCTAssertNil(DirectAdmissions.sender(in: #"{"type":"vibepier-session1"}"#))
    }
}
