import VibeKit
import XCTest

@testable import VibePierCore

final class RemoteControlOwnersTests: XCTestCase {
    private func event(_ sender: String, _ control: Control, _ action: String) -> RemoteEvent {
        RemoteEvent(sender: sender, seq: 1, control: control, event: action)
    }

    func testOnlyTalkOwnerMayKeepAliveOrReleaseAcrossRelayAndUDP() {
        var owners = RemoteControlOwners()
        XCTAssertTrue(owners.accept(event("relay:phone-a", .talk, "down")))
        XCTAssertEqual(owners.owner(.talk), "phone-a")
        XCTAssertFalse(owners.accept(event("phone-b", .talk, "down")), "another phone cannot renew this hold")
        XCTAssertFalse(owners.accept(event("relay:phone-b", .talk, "up")), "another phone disconnect cannot release it")
        XCTAssertTrue(
            owners.accept(event("phone-a", .talk, "down")), "owner keepalive remains valid after changing paths")
        XCTAssertTrue(owners.owns(.talk, sender: "relay:phone-a"))
        XCTAssertTrue(owners.accept(event("phone-a", .talk, "up")))
        XCTAssertTrue(owners.accept(event("phone-b", .talk, "down")))
        XCTAssertFalse(
            owners.accept(event("phone-a", .talk, "up")), "an old owner's watchdog cannot release the new owner")
        XCTAssertEqual(owners.owner(.talk), "phone-b")
    }

    func testOrdinaryHeldControlsHaveIndependentOwnersAndIgnoreDuplicatePresses() {
        var owners = RemoteControlOwners()
        XCTAssertTrue(owners.accept(event("phone-a", .confirm, "down")))
        XCTAssertFalse(owners.accept(event("relay:phone-a", .confirm, "down")))
        XCTAssertFalse(owners.accept(event("phone-b", .confirm, "down")))
        XCTAssertFalse(owners.accept(event("phone-b", .confirm, "step")))
        XCTAssertFalse(owners.accept(event("phone-b", .confirm, "up")))
        XCTAssertTrue(owners.accept(event("phone-b", .cancel, "down")))
        XCTAssertEqual(owners.owner(.confirm), "phone-a")
        XCTAssertEqual(owners.owner(.cancel), "phone-b")
        XCTAssertTrue(owners.accept(event("relay:phone-a", .confirm, "up")))
        XCTAssertTrue(owners.accept(event("phone-b", .confirm, "down")))
        XCTAssertTrue(owners.accept(event("phone-b", .cancel, "up")))
        XCTAssertEqual(owners.owner(.confirm), "phone-b")
    }

    func testUnownedReleasesAndMalformedTalkStepsCannotChangeHolds() {
        var owners = RemoteControlOwners()
        XCTAssertFalse(owners.accept(event("phone-a", .confirm, "up")))
        XCTAssertFalse(owners.accept(event("phone-a", .talk, "step")))
        XCTAssertTrue(owners.accept(event("phone-a", .knobPress, "step")))
        XCTAssertTrue(owners.accept(event("phone-b", .knobPress, "step")))
        XCTAssertNil(owners.owner(.knobPress))
        XCTAssertTrue(owners.accept(event("relay:phone-a", .talk, "down")))
        let actualOwner = owners.owner(.talk)!
        XCTAssertTrue(owners.accept(event(actualOwner, .talk, "up")), "forced app-switch release uses the actual owner")
        XCTAssertNil(owners.owner(.talk))
        XCTAssertEqual(
            RemoteControlOwners.identity("relay:relay:phone-a"), "relay:phone-a", "strip only one transport prefix")
        owners.removeAll()
        XCTAssertTrue(owners.accept(event("phone-b", .talk, "down")))
    }
}
