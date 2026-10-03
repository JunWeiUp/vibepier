// SPDX-License-Identifier: MIT
//
// IOKit HID transport for the vendor interface of the AU05 dongle.
//
// The vendor interface uses usage page 0xFFFC, which is not a keyboard, so
// opening it needs no Input Monitoring permission. The transport runs its own
// thread with a CFRunLoop so that it works in both the CLI and the daemon.

import Foundation
import IOKit
import IOKit.hid
import VibeLocalization

public struct HIDDeviceDescription: Sendable, CustomStringConvertible {
    public var vendorID: Int
    public var productID: Int
    public var product: String
    public var manufacturer: String
    public var serialNumber: String
    public var locationID: Int
    public var maxInputReportSize: Int
    public var maxOutputReportSize: Int

    public var description: String {
        String(
            format: "%@ (%04X:%04X, serial %@, location 0x%08X)",
            product, vendorID, productID, serialNumber, locationID)
    }
}

public enum TransportError: Error, CustomStringConvertible {
    case notConnected
    case setReportFailed(IOReturn)
    case openFailed(IOReturn)

    public var description: String {
        switch self {
        case .notConnected: return L10n.text("hardware.not_connected")
        case .setReportFailed(let r): return L10n.text("hardware.set_report_failed", String(format: "%08X", r))
        case .openFailed(let r): return L10n.text("hardware.open_failed", String(format: "%08X", r))
        }
    }
}

/// Event-driven transport boundary; also allows session timing tests without hardware.
public protocol SessionTransport: AnyObject, Sendable {
    var onConnect: (@Sendable (HIDDeviceDescription) -> Void)? { get set }
    var onDisconnect: (@Sendable () -> Void)? { get set }
    var onReport: (@Sendable ([UInt8]) -> Void)? { get set }
    func start()
    func stop()
    func send(report: [UInt8]) throws
}

/// Finds the dongle, opens it, and moves reports in both directions.
public final class HIDTransport: SessionTransport, @unchecked Sendable {
    public var onConnect: (@Sendable (HIDDeviceDescription) -> Void)?
    public var onDisconnect: (@Sendable () -> Void)?
    /// Called on the transport thread with the raw input report (report ID included when present).
    public var onReport: (@Sendable ([UInt8]) -> Void)?

    public let vendorID: Int
    public let productID: Int
    public let usagePage: Int

    private let lock = NSLock()
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var inputBuffer: UnsafeMutablePointer<UInt8>?
    private var inputBufferSize = 0
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let started = DispatchSemaphore(value: 0)

    public init(
        vendorID: Int = VibeUSB.vendorID, productID: Int = VibeUSB.productID,
        usagePage: Int = VibeUSB.usagePage
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.usagePage = usagePage
    }

    deinit {
        stop()
    }

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return device != nil
    }

    /// Starts device matching on a private run-loop thread.
    public func start() {
        lock.lock()
        if thread != nil {
            lock.unlock()
            return
        }
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "vibepier.hid"
        t.qualityOfService = .userInitiated
        thread = t
        lock.unlock()
        t.start()
        started.wait()
    }

    public func stop() {
        lock.lock()
        let rl = runLoop
        let mgr = manager
        let dev = device
        device = nil
        manager = nil
        runLoop = nil
        thread = nil
        lock.unlock()
        if let dev {
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let mgr {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let rl {
            CFRunLoopStop(rl)
        }
    }

    /// Sends one output report. `report` must start with the report ID.
    public func send(report: [UInt8]) throws {
        lock.lock()
        let dev = device
        lock.unlock()
        guard let dev else { throw TransportError.notConnected }
        let reportID = CFIndex(report.first ?? 0)
        let result = report.withUnsafeBufferPointer { buf in
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, reportID, buf.baseAddress!, buf.count)
        }
        if result != kIOReturnSuccess {
            throw TransportError.setReportFailed(result)
        }
    }

    // MARK: Run loop thread

    private func threadMain() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID,
            kIOHIDDeviceUsagePageKey as String: usagePage,
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(
            mgr,
            { ctx, _, _, device in
                guard let ctx else { return }
                Unmanaged<HIDTransport>.fromOpaque(ctx).takeUnretainedValue().deviceMatched(device)
            }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(
            mgr,
            { ctx, _, _, device in
                guard let ctx else { return }
                Unmanaged<HIDTransport>.fromOpaque(ctx).takeUnretainedValue().deviceRemoved(device)
            }, context)
        let rl = CFRunLoopGetCurrent()!
        IOHIDManagerScheduleWithRunLoop(mgr, rl, CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        lock.lock()
        manager = mgr
        runLoop = rl
        lock.unlock()
        started.signal()
        CFRunLoopRun()
    }

    private func deviceMatched(_ dev: IOHIDDevice) {
        lock.lock()
        if device != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        let result = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            FileHandle.standardError.write(Data("vibepier: \(TransportError.openFailed(result))\n".utf8))
            return
        }
        let info = describe(dev)
        let size = max(info.maxInputReportSize, VibeUSB.reportLength)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)

        lock.lock()
        device = dev
        inputBuffer?.deallocate()
        inputBuffer = buffer
        inputBufferSize = size
        lock.unlock()

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            dev, buffer, size,
            { ctx, result, _, _, reportID, report, length in
                guard let ctx, result == kIOReturnSuccess else { return }
                let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                Unmanaged<HIDTransport>.fromOpaque(ctx).takeUnretainedValue().received(bytes, reportID: reportID)
            }, context)
        onConnect?(info)
    }

    private func deviceRemoved(_ dev: IOHIDDevice) {
        lock.lock()
        guard let current = device, CFEqual(current, dev) else {
            lock.unlock()
            return
        }
        device = nil
        lock.unlock()
        onDisconnect?()
    }

    private func received(_ bytes: [UInt8], reportID: UInt32) {
        // IOKit includes the report ID as the first byte for numbered reports.
        var report = bytes
        if reportID != 0, report.first != UInt8(truncatingIfNeeded: reportID) {
            report.insert(UInt8(truncatingIfNeeded: reportID), at: 0)
        }
        onReport?(report)
    }

    private func describe(_ dev: IOHIDDevice) -> HIDDeviceDescription {
        func int(_ key: String) -> Int {
            (IOHIDDeviceGetProperty(dev, key as CFString) as? NSNumber)?.intValue ?? 0
        }
        func str(_ key: String) -> String {
            (IOHIDDeviceGetProperty(dev, key as CFString) as? String) ?? ""
        }
        return HIDDeviceDescription(
            vendorID: int(kIOHIDVendorIDKey), productID: int(kIOHIDProductIDKey),
            product: str(kIOHIDProductKey), manufacturer: str(kIOHIDManufacturerKey),
            serialNumber: str(kIOHIDSerialNumberKey), locationID: int(kIOHIDLocationIDKey),
            maxInputReportSize: int(kIOHIDMaxInputReportSizeKey),
            maxOutputReportSize: int(kIOHIDMaxOutputReportSizeKey))
    }
}
