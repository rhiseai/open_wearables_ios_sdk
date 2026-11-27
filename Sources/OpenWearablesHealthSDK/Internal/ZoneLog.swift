import Foundation

/// The time zones this phone has been in, as the SDK saw them change (RHISE-8334).
///
/// HealthKit stores a zone on few samples. One without it is sent with the phone's
/// offset, and the phone's zone at upload is wrong for a sample recorded before a trip
/// ended or began. The log remembers each zone and when the SDK first saw it, so a
/// sample takes the zone the phone was in at the sample's own time.
///
/// It describes the device, not the signed-in user: sign-out and sign-in keep it. A
/// reinstall starts it again. The time before its first observed entry is filled from
/// the samples HealthKit did store a zone with (`seedHistory`); a sample older than
/// every entry takes the first one, the earliest zone known.
internal final class ZoneLog {

    struct Entry: Codable, Equatable {
        /// When the SDK first saw the phone in `zone`.
        let since: Date
        /// IANA identifier, so the offset is read at the sample's time (daylight saving).
        let zone: String
        /// Read from a HealthKit sample that carries a zone, not seen on the phone itself.
        var seeded: Bool = false

        init(since: Date, zone: String, seeded: Bool = false) {
            self.since = since
            self.zone = zone
            self.seeded = seeded
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            since = try container.decode(Date.self, forKey: .since)
            zone = try container.decode(String.self, forKey: .zone)
            seeded = try container.decodeIfPresent(Bool.self, forKey: .seeded) ?? false
        }
    }

    static let defaultsKey = "deviceZoneLog"
    /// Old entries only matter for samples not uploaded yet.
    static let maxEntries = 200

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var entries: [Entry]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: ZoneLog.defaultsKey),
           let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = stored
        } else {
            entries = []
        }
    }

    /// Notes the zone the phone is in at `now`; stored only when it differs from the last one.
    func record(_ zone: TimeZone, at now: Date) {
        lock.lock()
        defer { lock.unlock() }
        _record(zone, at: now)
    }

    /// The zone the phone was in at `date`, after noting the one it is in at `now`.
    func zone(at date: Date, current: TimeZone, now: Date) -> TimeZone {
        lock.lock()
        defer { lock.unlock() }
        _record(current, at: now)
        // The log is never empty here. A date before its first entry takes that entry.
        let entry = entries.last(where: { $0.since <= date }) ?? entries[0]
        return TimeZone(identifier: entry.zone) ?? current
    }

    /// Replaces what is known about the time before the phone's own first entry with
    /// `history`: where zones began according to samples that carry one. Entries at or
    /// after that first observed entry are dropped; what the phone saw itself stands.
    func seedHistory(_ history: [Entry]) {
        lock.lock()
        defer { lock.unlock() }
        let observed = entries.filter { !$0.seeded }
        let firstObserved = observed.first?.since
        var seeded: [Entry] = []
        for entry in history.sorted(by: { $0.since < $1.since }) {
            if let firstObserved = firstObserved, entry.since >= firstObserved { break }
            if seeded.last?.zone == entry.zone { continue }
            seeded.append(Entry(since: entry.since, zone: entry.zone, seeded: true))
        }
        entries = seeded + observed
        trimAndStore()
    }

    var snapshot: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    private func _record(_ zone: TimeZone, at now: Date) {
        if entries.last?.zone == zone.identifier { return }
        // A clock set back must not put an entry before the one it follows.
        let since = max(now, entries.last?.since ?? now)
        entries.append(Entry(since: since, zone: zone.identifier))
        trimAndStore()
    }

    private func trimAndStore() {
        if entries.count > ZoneLog.maxEntries {
            entries.removeFirst(entries.count - ZoneLog.maxEntries)
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: ZoneLog.defaultsKey)
        }
    }
}
