import Foundation
import HealthKit

/// Where samples that carry a zone can be looked up, one sample per question.
internal protocol ZoneEvidenceSource {
    /// The newest sample with a stored zone that starts before `before`; with
    /// `excluding`, the newest whose zone is another one.
    func newestZonedSample(before: Date, excluding zone: String?, completion: @escaping ((date: Date, zone: String)?) -> Void)
    /// The start of the oldest sample stored in `zone` that starts after `after` (ever, when nil).
    func oldestSampleStart(in zone: String, after: Date?, completion: @escaping (Date?) -> Void)
}

/// Reads the zones a user's history was recorded in from the samples HealthKit stored a
/// zone with (workouts and sleep of an Apple Watch, mostly), for `ZoneLog.seedHistory`.
///
/// It never scans the history: it walks back from `before` one stretch of a zone at a
/// time, three one-sample queries per stretch. Someone who never changed zone costs
/// three queries; a scan of every sample was the spike a sync start used to cause.
internal enum ZoneHistory {

    /// More stretches than this are not looked for; the oldest ones are left out.
    static let maxStretches = 60

    static func stretches(
        from source: ZoneEvidenceSource,
        before: Date,
        completion: @escaping ([ZoneLog.Entry]) -> Void
    ) {
        var found: [ZoneLog.Entry] = []

        func step(before: Date) {
            guard found.count < maxStretches else { completion(found); return }
            source.newestZonedSample(before: before, excluding: nil) { newest in
                guard let newest = newest, TimeZone(identifier: newest.zone) != nil else { completion(found); return }
                source.newestZonedSample(before: newest.date, excluding: newest.zone) { other in
                    // A source that answers with the same zone would never move back: treat it as none.
                    let earlier = other.flatMap { $0.zone != newest.zone && $0.date < newest.date ? $0 : nil }
                    source.oldestSampleStart(in: newest.zone, after: earlier?.date) { start in
                        found.append(ZoneLog.Entry(since: min(start ?? newest.date, newest.date), zone: newest.zone, seeded: true))
                        guard let earlier = earlier else { completion(found); return }
                        step(before: earlier.date.addingTimeInterval(1))
                    }
                }
            }
        }

        step(before: before)
    }
}

/// `ZoneEvidenceSource` over one HealthKit sample type.
internal struct HealthKitZoneEvidence: ZoneEvidenceSource {
    let store: HKHealthStore
    let type: HKSampleType

    func newestZonedSample(before: Date, excluding zone: String?, completion: @escaping ((date: Date, zone: String)?) -> Void) {
        var parts = [
            NSPredicate(format: "%K < %@", HKPredicateKeyPathStartDate, before as NSDate),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyTimeZone),
        ]
        if let zone = zone {
            parts.append(HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyTimeZone, operatorType: .notEqualTo, value: zone))
        }
        first(matching: parts, ascending: false) { sample in
            guard let sample = sample, let found = sample.metadata?[HKMetadataKeyTimeZone] as? String else {
                completion(nil)
                return
            }
            completion((date: sample.startDate, zone: found))
        }
    }

    func oldestSampleStart(in zone: String, after: Date?, completion: @escaping (Date?) -> Void) {
        var parts = [HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyTimeZone, operatorType: .equalTo, value: zone)]
        if let after = after {
            parts.append(NSPredicate(format: "%K > %@", HKPredicateKeyPathStartDate, after as NSDate))
        }
        first(matching: parts, ascending: true) { completion($0?.startDate) }
    }

    private func first(matching parts: [NSPredicate], ascending: Bool, completion: @escaping (HKSample?) -> Void) {
        let query = HKSampleQuery(
            sampleType: type,
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: parts),
            limit: 1,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: ascending)]
        ) { _, samples, _ in
            // An error (a locked phone, a type that cannot be read) is no evidence, not a failure.
            completion(samples?.first)
        }
        store.execute(query)
    }
}

extension OpenWearablesHealthSDK {

    /// Fills the zone log's past from the tracked workouts and sleep before a full export
    /// starts sending history. Always calls `completion`, after at most `timeout`.
    internal func seedZoneHistory(types: [HKSampleType], timeout: TimeInterval = 15, completion: @escaping () -> Void) {
        let zoned = types.filter {
            $0 == HKObjectType.workoutType() || $0.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue
        }
        guard !zoned.isEmpty else { completion(); return }

        let lock = NSLock()
        var finished = false
        let finish: () -> Void = {
            lock.lock()
            let first = !finished
            finished = true
            lock.unlock()
            if first { completion() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: finish)

        let before = zoneLog.snapshot.first(where: { !$0.seeded })?.since ?? Date()
        var history: [ZoneLog.Entry] = []
        var remaining = zoned
        func next() {
            guard !remaining.isEmpty else {
                zoneLog.seedHistory(history)
                logMessage("Zone history: \(history.count) stretches from samples with a zone")
                finish()
                return
            }
            let source = HealthKitZoneEvidence(store: healthStore, type: remaining.removeFirst())
            ZoneHistory.stretches(from: source, before: before) { found in
                history.append(contentsOf: found)
                next()
            }
        }
        next()
    }
}
