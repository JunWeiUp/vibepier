import Foundation

/// Accessed only on the session queue; the key and reservation identity survive worker cancellation races.
struct APKStageReservations {
    struct Reservation: Sendable {
        let id = UUID().uuidString
        let job = APKPreparationJob()
        let deviceKey: Data
        let name: String
        let digest: String?
    }
    private var pending: [String: Reservation] = [:]
    func reservation(_ device: String) -> Reservation? { pending[device] }
    mutating func begin(device: String, key: Data, name: String, digest: String?) -> Reservation? {
        guard pending[device] == nil else { return nil }
        let value = Reservation(deviceKey: key, name: name, digest: digest)
        pending[device] = value
        return value
    }
    mutating func claim(device: String, reservation: Reservation, currentKey: Data?) -> Bool {
        guard pending[device]?.id == reservation.id else { return false }
        pending.removeValue(forKey: device)
        return currentKey == reservation.deviceKey && (try? reservation.job.check()) != nil
    }
    mutating func cancel(_ device: String) {
        pending.removeValue(forKey: device)?.job.cancel()
    }
    mutating func cancelAll() {
        for value in pending.values { value.job.cancel() }
        pending.removeAll()
    }
    func status(_ device: String) -> PhoneAPKStatus? {
        guard let value = pending[device] else { return nil }
        return PhoneAPKStatus(
            transfer: value.id, name: value.name, size: 0, received: 0,
            state: L10n.text("mac.preparing"), phase: .preparing)
    }
}
