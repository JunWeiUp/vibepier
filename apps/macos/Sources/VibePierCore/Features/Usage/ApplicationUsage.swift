import AppKit
import Foundation

/// Only observed foreground intervals are persisted. A process restart never fills the missing interval.
struct ApplicationUsageLedger: Codable {
    struct Segment: Codable, Equatable {
        var start: Date
        var end: Date
        var appID: String
        var name: String
        var rest: Bool
    }
    var enabled = false
    var segments: [Segment] = []
    var colors: [String: String] = [:]
    var mutations: [String: Double] = [:]

    mutating func setEnabled(_ value: Bool, sequence: Double, device: String) -> Bool {
        guard sequence > (mutations[device] ?? 0) else { return false }
        enabled = value
        mutations[device] = sequence
        return true
    }

    mutating func record(start: Date, now: Date, elapsed: Double, appID: String, name: String, rest: Bool) {
        guard enabled, elapsed.isFinite, elapsed > 0, rest || !appID.isEmpty else { return }
        // Forward clock corrections become gaps, not app time. Backward corrections cannot duplicate time.
        let end = min(start.addingTimeInterval(elapsed), now)
        let beginning = max(start, segments.last?.end ?? start)
        guard end > beginning else { return }
        if !rest { _ = color(for: appID) }
        if let last = segments.last, last.end == beginning, last.appID == appID, last.name == name, last.rest == rest {
            segments[segments.count - 1].end = end
        } else {
            segments.append(.init(start: beginning, end: end, appID: appID, name: name, rest: rest))
        }
        let cutoff = now.addingTimeInterval(-91 * 86400)
        segments.removeAll { $0.end < cutoff }
    }

    func totals(day: DateInterval, cutoff: Date) -> (apps: [String: (name: String, seconds: Double)], rest: Double) {
        var apps: [String: (name: String, seconds: Double)] = [:]
        var rest = 0.0
        for segment in segments {
            let start = max(day.start, segment.start)
            let end = min(day.end, min(cutoff, segment.end))
            guard end > start else { continue }
            let seconds = end.timeIntervalSince(start)
            if segment.rest {
                rest += seconds
            } else {
                apps[segment.appID] = (segment.name, (apps[segment.appID]?.seconds ?? 0) + seconds)
            }
        }
        return (apps, rest)
    }

    /// Preserve every observed interval, including rest; gaps are left for the reader to mark as unknown.
    func timeline(day: DateInterval, cutoff: Date) -> [Segment] {
        segments.compactMap { segment in
            let start = max(day.start, segment.start)
            let end = min(day.end, min(cutoff, segment.end))
            guard end > start else { return nil }
            return Segment(start: start, end: end, appID: segment.appID, name: segment.name, rest: segment.rest)
        }
    }

    mutating func color(for id: String) -> String {
        if let color = colors[id] { return color }
        // Fixed hash, never Swift's per-process randomized Hasher or the current rank.
        let colors = ["#BBDDB2", "#DB9788", "#B6A2D7", "#8EBAD1", "#CFBE94", "#94A9B5", "#B5CFCA", "#D1ADCB"]
        let hash = id.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        let used = Set(self.colors.values)
        for offset in 0..<colors.count {
            let candidate = colors[(Int(hash % UInt64(colors.count)) + offset) % colors.count]
            if !used.contains(candidate) {
                self.colors[id] = candidate
                return candidate
            }
        }
        // More applications keep their own persisted color; do not recycle the first eight.
        var hue = Double(hash % 360) / 360
        for _ in 0..<3600 {
            let saturation = 0.30
            let value = 0.84
            let h = hue * 6
            let sector = Int(h)
            let fraction = h - Double(sector)
            let p = value * (1 - saturation)
            let q = value * (1 - fraction * saturation)
            let t = value * (1 - (1 - fraction) * saturation)
            let rgb: (Double, Double, Double)
            switch sector % 6 {
            case 0: rgb = (value, t, p)
            case 1: rgb = (q, value, p)
            case 2: rgb = (p, value, t)
            case 3: rgb = (p, q, value)
            case 4: rgb = (t, p, value)
            default: rgb = (value, p, q)
            }
            let candidate = String(format: "#%02X%02X%02X", Int(rgb.0 * 255), Int(rgb.1 * 255), Int(rgb.2 * 255))
            if !used.contains(candidate) {
                self.colors[id] = candidate
                return candidate
            }
            hue = (hue + 0.61803398875).truncatingRemainder(dividingBy: 1)
        }
        let fallback = String(format: "#%06X", hash & 0xFFFFFF)
        self.colors[id] = fallback
        return fallback
    }
}

@MainActor final class ApplicationUsage {
    static let shared = ApplicationUsage()
    private let file: URL
    private var ledger: ApplicationUsageLedger
    private var startDate: Date?
    private var startTick: ContinuousClock.Instant?
    private var current = FrontmostApplication(bundleID: "", name: "")
    private var sleeping = false
    private var sessionInactive = false
    private var screenSleeping = false
    private var resting = false
    private var lockState: Bool?
    private var observing = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var storageError: String?
    private var corrupted = false
    private var iconCache: [String: String] = [:]

    init(file: URL = Paths.supportDirectory.appendingPathComponent("application-usage.json")) {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            do { ledger = try JSONDecoder().decode(ApplicationUsageLedger.self, from: Data(contentsOf: file)) } catch {
                ledger = .init()
                corrupted = true
                storageError = L10n.text(
                    "control.could_not_read_local_usage_records_the_original_file_was_kept_0",
                    error.localizedDescription)
            }
        } else {
            ledger = .init()
        }
    }

    func start() {
        guard !observing else { return }
        observing = true
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.transition() }
        observe(workspace, NSWorkspace.willSleepNotification) {
            $0.sleeping = true
            $0.transition()
        }
        observe(workspace, NSWorkspace.didWakeNotification) {
            $0.sleeping = false
            $0.transition()
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) {
            $0.screenSleeping = true
            $0.transition()
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) {
            $0.screenSleeping = false
            $0.transition()
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) {
            $0.sessionInactive = true
            $0.transition()
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) {
            $0.sessionInactive = false
            $0.transition()
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) {
            $0.lockState = true
            $0.transition()
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) {
            $0.lockState = false
            $0.transition()
        }
        transition()
        armCheckpoint()
    }

    func stop() {
        checkpoint()
        startDate = nil
        startTick = nil
        timer?.invalidate()
        timer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        observing = false
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (ApplicationUsage) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { body(self) } }
        }
        observers.append((center, token))
    }

    private func armCheckpoint() {
        timer?.invalidate()
        timer = nil
        guard ledger.enabled else { return }
        // One minute checkpoint bounds an abnormal termination's unknown tail; no phone polling dependency.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.transition() }
        }
        timer?.tolerance = 10
    }

    private func transition() {
        guard ledger.enabled else {
            startDate = nil
            startTick = nil
            return
        }
        checkpoint()
        current = .current()
        resting = sleeping || screenSleeping || sessionInactive || (lockState ?? ScreenLock.locked())
        startDate = ledger.enabled ? Date() : nil
        startTick = ledger.enabled ? ContinuousClock.now : nil
    }

    private func checkpoint() {
        guard let startDate, let startTick else { return }
        let now = Date()
        let tick = ContinuousClock.now
        let duration = startTick.duration(to: tick).components
        let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        ledger.record(
            start: startDate, now: now, elapsed: elapsed, appID: current.bundleID, name: current.name, rest: resting)
        self.startDate = now
        self.startTick = tick
        save()
    }

    private func save() {
        guard !corrupted else { return }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ledger).write(to: file, options: .atomic)
            storageError = nil
        } catch { storageError = L10n.text("control.usage_records_were_not_saved_0", error.localizedDescription) }
    }

    func reply(_ request: [String: Any], device: String = "") throws -> [String: Any] {
        // Even with a broken storage file, pause remains available and cannot leave an unwanted timer running.
        if corrupted {
            if request["op"] as? String == "appUsageSet", request["enabled"] as? Bool == false {
                ledger.enabled = false
                transition()
                armCheckpoint()
            }
            throw CLIError(storageError ?? L10n.text("control.could_not_read_local_usage_records"))
        }
        let source = PhoneBindings.shared.snapshot.server
        if let expected = request["sourceID"] as? String, !expected.isEmpty, expected != source {
            throw CLIError(L10n.text("control.the_mac_source_changed_reopen_the_usage_page"))
        }
        if request["op"] as? String == "appUsageSet" {
            guard let enabled = request["enabled"] as? Bool else {
                throw CLIError(L10n.text("control.missing_usage_tracking_enabled_state"))
            }
            guard let sequence = request["mutationSequence"] as? Double, sequence.isFinite, sequence > 0,
                !device.isEmpty
            else { throw CLIError(L10n.text("control.missing_usage_tracking_operation_version")) }
            if sequence > (ledger.mutations[device] ?? 0) {
                checkpoint()
                let wasEnabled = ledger.enabled
                _ = ledger.setEnabled(enabled, sequence: sequence, device: device)
                save()
                if storageError != nil && enabled && !wasEnabled { ledger.enabled = false }
            }
            transition()
            armCheckpoint()
            if storageError != nil { save() }
            if let error = storageError { throw CLIError(error) }
        } else {
            transition()
            if storageError != nil { save() }
        }
        let now = Date()
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let today = formatter.string(from: now)
        let value = request["date"] as? String ?? today
        guard let date = formatter.date(from: value), formatter.string(from: date) == value,
            let day = calendar.dateInterval(of: .day, for: date), day.start <= now,
            day.start >= calendar.startOfDay(for: now).addingTimeInterval(-90 * 86400)
        else { throw CLIError(L10n.text("control.choose_a_date_within_the_last_90_days")) }
        let cutoff = min(now, day.end)
        let totals = ledger.totals(day: day, cutoff: cutoff)
        let rows = totals.apps.sorted { a, b in
            a.value.seconds == b.value.seconds
                ? a.value.name.localizedStandardCompare(b.value.name) == .orderedAscending
                : a.value.seconds > b.value.seconds
        }
        let apps: [[String: Any]] = rows.enumerated().map { index, entry in
            var row: [String: Any] = [
                "id": entry.key, "name": entry.value.name, "seconds": entry.value.seconds,
                "color": ledger.color(for: entry.key),
            ]
            if index < 24 { row["iconPNG"] = icon(entry.key) }
            return row
        }
        let total = rows.reduce(0.0) { $0 + $1.value.seconds }
        let future = max(0, day.end.timeIntervalSince(cutoff))
        let unrecorded = max(0, cutoff.timeIntervalSince(day.start) - total - totals.rest)
        var reply: [String: Any] = [
            "ok": true, "sourceID": source, "sourceName": Host.current().localizedName ?? "Mac",
            "timeZone": calendar.timeZone.identifier,
            "date": value, "today": today, "dayStart": day.start.timeIntervalSince1970 * 1000,
            "daySeconds": day.duration,
            "syncedAt": now.timeIntervalSince1970 * 1000, "enabled": ledger.enabled, "apps": apps,
            "totalSeconds": total,
            "restSeconds": totals.rest, "unrecordedSeconds": unrecorded, "futureSeconds": future,
        ]
        if ledger.enabled && !resting { reply["currentAppID"] = current.bundleID }
        // Compact, complete chronological intervals. An empty app ID represents observed rest.
        // No suffix limit: omitting early intervals would turn real app time into unknown time.
        reply["timelineVersion"] = 1
        reply["timeline"] = ledger.timeline(day: day, cutoff: cutoff).map {
            [$0.rest ? "" : $0.appID, $0.start.timeIntervalSince1970 * 1000, $0.end.timeIntervalSince1970 * 1000]
                as [Any]
        }
        reply["intervals"] = ledger.segments.filter { !$0.rest && $0.end > day.start && $0.start < cutoff }.suffix(500)
            .map {
                [
                    "appID": $0.appID, "start": max(day.start, $0.start).timeIntervalSince1970 * 1000,
                    "end": min(cutoff, $0.end).timeIntervalSince1970 * 1000,
                ] as [String: Any]
            }
        if let error = storageError { throw CLIError(error) }
        return reply
    }

    private func icon(_ id: String) -> String {
        if let saved = iconCache[id] { return saved }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return "" }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSWorkspace.shared.icon(forFile: url.path).draw(in: NSRect(x: 0, y: 0, width: 48, height: 48))
        NSGraphicsContext.restoreGraphicsState()
        let value = bitmap.representation(using: .png, properties: [:])?.base64EncodedString() ?? ""
        if iconCache.count > 256 { iconCache.removeAll() }
        iconCache[id] = value
        return value
    }
}
