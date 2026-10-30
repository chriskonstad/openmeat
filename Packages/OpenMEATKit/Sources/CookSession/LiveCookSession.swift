import CookCore
import Foundation
import ThermoWorksCloud

/// Everything the UI, Live Activity and notification layers need at a point in time.
public struct SessionSnapshot: Sendable, Equatable {
    public var cook: Cook
    /// Only for internal probes that have a target.
    public var estimates: [ChannelKey: Estimate]
    public var staleChannels: Set<ChannelKey>
    /// Battery/signal for the cook's devices plus the gateway, keyed by serial. Refreshed every few minutes.
    public var devices: [String: DeviceHealth]
    public var lastPoll: Date?
    public var lastError: String?
    public var now: Date

    public init(cook: Cook, estimates: [ChannelKey: Estimate] = [:], staleChannels: Set<ChannelKey> = [],
                devices: [String: DeviceHealth] = [:], lastPoll: Date? = nil, lastError: String? = nil, now: Date) {
        self.cook = cook
        self.estimates = estimates
        self.staleChannels = staleChannels
        self.devices = devices
        self.lastPoll = lastPoll
        self.lastError = lastError
        self.now = now
    }

    public func estimate(_ key: ChannelKey) -> Estimate? { estimates[key] }

    /// Time of the newest reading from any channel — "how fresh is what I'm looking at".
    public var latestReadingTime: Date? {
        cook.probes.compactMap { cook.series[$0.key]?.last?.time }.max()
    }

    /// True when no channel has reported recently (gateway offline, app was suspended, network down).
    public var isStale: Bool {
        !cook.probes.isEmpty && cook.probes.allSatisfy { staleChannels.contains($0.key) }
    }

    /// The probe to feature (Live Activity, compact UI): soonest ETA, else first targeted, else first internal.
    public var primaryProbe: CookProbe? {
        let internals = cook.probes.filter { $0.role == .internal }
        let withETA = internals.compactMap { p in estimates[p.key]?.eta.map { (p, $0) } }
        if let soonest = withETA.min(by: { $0.1 < $1.1 }) { return soonest.0 }
        return internals.first { $0.target != nil } ?? internals.first
    }
}

/// Owns an active cook: polls ThermoWorks, records samples, runs estimators, persists, publishes snapshots.
public actor LiveCookSession {
    public typealias EstimatorFactory = @Sendable () -> any DoneTimeEstimator

    public struct Options: Sendable {
        /// Real-time seconds between polls.
        public var pollInterval: Duration = .seconds(15)
        /// A channel with no new reading for this long (in `TimeSource` time) is stale.
        public var staleAfter: TimeInterval = 180
        /// Ambient readings older than this (relative to the probe reading) aren't used for estimates.
        public var ambientMaxAge: TimeInterval = 120
        /// Persist after this many poll cycles that recorded new samples.
        public var saveEveryPolls: Int = 4
        /// Re-read device documents (battery, signal) this often, in `TimeSource` time.
        public var deviceRefreshInterval: TimeInterval = 5 * 60

        public init() {}
    }

    public private(set) var cook: Cook
    private let service: any ThermoWorksService
    private let store: (any CookStore)?
    private let time: any TimeSource
    private let options: Options
    private let makeEstimator: EstimatorFactory

    private var estimators: [ChannelKey: any DoneTimeEstimator] = [:]
    private var lastTelemetry: [ChannelKey: Date] = [:]
    private var lastPoll: Date?
    private var lastError: String?
    private var devices: [String: DeviceHealth] = [:]
    private var lastDeviceRefresh: Date?
    private var pollsSinceSave = 0
    private var pollTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<SessionSnapshot>.Continuation] = [:]

    public init(
        cook: Cook,
        service: any ThermoWorksService,
        store: (any CookStore)?,
        timeSource: any TimeSource,
        options: Options = Options(),
        makeEstimator: @escaping EstimatorFactory = { NewtonEWMAEstimator() }
    ) {
        self.cook = cook
        self.service = service
        self.store = store
        self.time = timeSource
        self.options = options
        self.makeEstimator = makeEstimator
        // Resuming a cook (e.g. after relaunch): rebuild estimator state from recorded samples.
        estimators = Self.estimators(for: cook, make: makeEstimator, ambientMaxAge: options.ambientMaxAge)
        for (key, samples) in cook.series {
            lastTelemetry[key] = samples.last?.time
        }
    }

    // MARK: Observation

    public func snapshot() -> SessionSnapshot {
        let now = time.now
        var estimates: [ChannelKey: Estimate] = [:]
        for probe in cook.probes where probe.role == .internal {
            guard let target = probe.target, let estimator = estimators[probe.key] else { continue }
            estimates[probe.key] = estimator.estimate(target: target, now: now)
        }
        let stale = Set(cook.probes.map(\.key).filter { key in
            guard let last = cook.series[key]?.last?.time else { return lastPoll != nil }
            return now.timeIntervalSince(last) > options.staleAfter
        })
        return SessionSnapshot(cook: cook, estimates: estimates, staleChannels: stale, devices: devices,
                               lastPoll: lastPoll, lastError: lastError, now: now)
    }

    /// Emits the current snapshot immediately, then after every change.
    public func snapshots() -> AsyncStream<SessionSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: SessionSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        continuation.yield(snapshot())
        return stream
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    private func publish() {
        let snap = snapshot()
        for continuation in continuations.values { continuation.yield(snap) }
    }

    // MARK: Polling

    public func start() {
        guard pollTask == nil else { return }
        let interval = options.pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One poll cycle. Exposed for tests and background refresh.
    @discardableResult
    public func pollOnce() async -> SessionSnapshot {
        let refs = cook.probes.map { TWChannelRef(deviceSerial: $0.key.deviceSerial, number: $0.key.channel) }
        do {
            let channels = try await service.channels(refs)
            ingest(channels)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refreshDevicesIfDue()
        lastPoll = time.now
        publish()
        return snapshot()
    }

    /// Battery and signal change slowly; one extra request every few minutes keeps them current.
    /// Failures keep the previous values (channel polling reports errors).
    private func refreshDevicesIfDue() async {
        let now = time.now
        if let last = lastDeviceRefresh, now.timeIntervalSince(last) < options.deviceRefreshInterval { return }
        guard let fetched = try? await service.devices() else { return }
        lastDeviceRefresh = now
        let serials = Set(cook.probes.map(\.key.deviceSerial))
        devices = Dictionary(uniqueKeysWithValues: fetched
            .filter { serials.contains($0.serial) || $0.isGateway }
            .map { ($0.serial, DeviceHealth(device: $0)) })
    }

    func ingest(_ channels: [TWChannel]) {
        let now = time.now
        var updated: [ChannelKey] = []
        for channel in channels {
            let key = channel.key
            guard cook.probe(key) != nil, let temperature = channel.temperature else { continue }
            let readingTime = channel.lastTelemetrySaved ?? now
            // Firestore docs don't change between telemetry packets — don't record duplicates.
            if let last = lastTelemetry[key], readingTime <= last { continue }
            if cook.append(Sample(time: readingTime, celsius: temperature.celsius), to: key) {
                lastTelemetry[key] = readingTime
                updated.append(key)
            }
        }
        // Estimators after all samples so paired ambient readings from this poll are available.
        for key in updated {
            guard let probe = cook.probe(key), probe.role == .internal, let sample = cook.series[key]?.last else { continue }
            estimators[key, default: makeEstimator()]
                .ingest(Self.input(for: sample, ambientKey: probe.pairedAmbient, in: cook, maxAge: options.ambientMaxAge))
        }
        if !updated.isEmpty {
            pollsSinceSave += 1
            if pollsSinceSave >= options.saveEveryPolls { persistSoon() }
        }
    }

    private static func estimators(for cook: Cook, make: EstimatorFactory, ambientMaxAge: TimeInterval) -> [ChannelKey: any DoneTimeEstimator] {
        var result: [ChannelKey: any DoneTimeEstimator] = [:]
        for probe in cook.probes where probe.role == .internal {
            var estimator = make()
            for sample in cook.series[probe.key] ?? [] {
                estimator.ingest(input(for: sample, ambientKey: probe.pairedAmbient, in: cook, maxAge: ambientMaxAge))
            }
            result[probe.key] = estimator
        }
        return result
    }

    private func rebuildEstimators() {
        estimators = Self.estimators(for: cook, make: makeEstimator, ambientMaxAge: options.ambientMaxAge)
    }

    private static func input(for sample: Sample, ambientKey: ChannelKey?, in cook: Cook, maxAge: TimeInterval) -> EstimatorInput {
        // Most recent ambient reading at or before the probe reading.
        let ambient = ambientKey.flatMap { key in
            cook.series[key]?.last { $0.time <= sample.time && sample.time.timeIntervalSince($0.time) <= maxAge }
        }
        return EstimatorInput(time: sample.time, probeCelsius: sample.celsius, ambientCelsius: ambient?.celsius)
    }

    // MARK: Mutations

    public func setTarget(_ target: Temperature?, for key: ChannelKey) {
        guard let index = cook.probes.firstIndex(where: { $0.key == key }) else { return }
        cook.probes[index].target = target
        persistSoon()
        publish()
    }

    /// Changes a channel's role mid-cook and re-pairs ambients. Existing series keep their colors.
    public func setRole(_ role: ProbeRole, for key: ChannelKey) {
        guard let index = cook.probes.firstIndex(where: { $0.key == key }), cook.probes[index].role != role else { return }
        let previous = cook.probes
        cook.probes[index].role = role
        if role != .internal { cook.probes[index].target = nil }
        cook.probes = ProbeDiscovery.pairAndColor(cook.probes, preservingColorsOf: previous)
        rebuildEstimators()
        persistSoon()
        publish()
    }

    public func setLabel(_ label: String, for key: ChannelKey) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = cook.probes.firstIndex(where: { $0.key == key }) else { return }
        cook.probes[index].label = trimmed
        persistSoon()
        publish()
    }

    @discardableResult
    public func addNote(_ text: String, at date: Date? = nil, isQuickNote: Bool = false) -> CookNote {
        let note = CookNote(time: date ?? time.now, text: text, isQuickNote: isQuickNote)
        cook.notes.append(note)
        cook.notes.sort { $0.time < $1.time }
        persistSoon()
        publish()
        return note
    }

    public func deleteNote(id: UUID) {
        cook.notes.removeAll { $0.id == id }
        persistSoon()
        publish()
    }

    public func setTitle(_ title: String) {
        cook.title = title
        persistSoon()
        publish()
    }

    public func setAlmostDoneLeadTime(_ lead: TimeInterval?) {
        cook.almostDoneLeadTime = lead
        persistSoon()
        publish()
    }

    /// Stops polling, stamps the end time, saves, and finishes all snapshot streams.
    public func end() async throws -> Cook {
        stop()
        cook.endedAt = time.now
        await flushSaves()
        try await store?.save(cook)
        publish()
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
        return cook
    }

    public func save() async throws {
        pollsSinceSave = 0
        try await store?.save(cook)
    }

    private var saveChain: Task<Void, Never>?

    /// Saves in the background, chained so writes land in order.
    private func persistSoon() {
        pollsSinceSave = 0
        guard let store else { return }
        let cook = cook
        let previous = saveChain
        saveChain = Task {
            await previous?.value
            try? await store.save(cook)
        }
    }

    /// Waits for queued background saves (tests, app backgrounding).
    public func flushSaves() async {
        await saveChain?.value
    }
}
