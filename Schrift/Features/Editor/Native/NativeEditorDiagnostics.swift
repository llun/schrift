import Darwin
import Foundation
import OSLog
import Synchronization

/// Every stage measured along the native editor pipeline (PR15 Step 4).
/// Raw values are static ASCII identifiers; no document, user, or server data
/// may ever appear in any case or payload.
enum NativeEditorStage: String, Codable, Sendable, CaseIterable {
    case diskRestore
    case decodeIntegrate
    case projection
    case storageApply
    case firstVisibleContent
    case timeToEdit
    case inputToDisplay
    case mailboxQueueWait
    case remoteMerge
    case checkpointCompact
}

struct StageSample: Codable, Equatable, Sendable {
    let sessionSeq: UInt64
    let stage: NativeEditorStage
    let durationMs: Double
    let byteCount: Int
    let itemCount: Int
    let timestampUptimeMs: Double
}

struct ReplicaWorkloadMetrics: Codable, Equatable, Sendable {
    var rawBytes: Int = 0
    var yjsStructCount: Int = 0
    var tombstoneCount: Int = 0
    var blockCount: Int = 0
    var mediaBlockCount: Int = 0
    var journalSegmentCount: Int = 0
    var outboxSegmentCount: Int = 0
}

struct SurfaceWorkCounters: Codable, Equatable, Sendable {
    var textPatchCount: Int = 0
    var blockPatchCount: Int = 0
    var fullStorageRebuildCount: Int = 0
    var presentationRestyleCount: Int = 0
    var realisedAttachmentViewCount: Int = 0
    var realisedControlViewCount: Int = 0
    var undoDepth: Int = 0
}

struct MemorySample: Codable, Equatable, Sendable {
    var baselineBytes: UInt64 = 0
    var peakBytes: UInt64 = 0
    var steadyBytes: UInt64 = 0
    var closeDeltaBytes: Int64 = 0
}

struct StageDistribution: Codable, Equatable, Sendable {
    let count: Int
    let p50Ms: Double
    let p95Ms: Double
    let p99Ms: Double
    let maxMs: Double

    static func compute(from values: [Double]) -> StageDistribution {
        guard !values.isEmpty else {
            return StageDistribution(count: 0, p50Ms: 0, p95Ms: 0, p99Ms: 0, maxMs: 0)
        }
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double {
            let index = min(sorted.count - 1, max(0, Int(ceil(p * Double(sorted.count))) - 1))
            return sorted[index]
        }
        return StageDistribution(
            count: sorted.count,
            p50Ms: percentile(0.50),
            p95Ms: percentile(0.95),
            p99Ms: percentile(0.99),
            maxMs: sorted[sorted.count - 1])
    }
}

struct SessionDiagnosticsSummary: Codable, Equatable, Sendable {
    let sessionSeq: UInt64
    var workload: ReplicaWorkloadMetrics
    var counters: SurfaceWorkCounters
    var memory: MemorySample
    var stages: [String: StageDistribution]
    var isOpen: Bool
}

struct NativeEditorDiagnosticsSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generatedUptimeMs: Double
    let activeSessionCount: Int
    let totalSampleCount: Int
    let stageDistributions: [String: StageDistribution]
    let recentSamples: [StageSample]
    let sessions: [SessionDiagnosticsSummary]
}

/// Signpost and bounded in-memory telemetry store for the native editor (PR15).
///
/// Signposts stay active in Release/TestFlight builds for Instruments capture.
/// In-memory ring recording is active whenever `NativeEditorPreference.isEnabled`
/// or `--native-diagnostics` / `--native-scroll-sampler` is passed (or when
/// explicitly forced on an isolated test store instance).
///
/// Strict privacy invariant: this store accepts and emits only monotonic session
/// sequence integers, stage identifiers, counts, byte sizes, and timings.
final class NativeEditorDiagnosticsStore: Sendable {
    static let shared = NativeEditorDiagnosticsStore()
    static let defaultMaxSamples = 256
    static let defaultMaxSessions = 32

    static let logger = Logger(subsystem: "dev.llun.Schrift", category: "NativeEditor")
    static let signposter = OSSignposter(logger: logger)

    private struct SessionRecord {
        let seq: UInt64
        var workload = ReplicaWorkloadMetrics()
        var counters = SurfaceWorkCounters()
        var memory = MemorySample()
        var stageSamples: [NativeEditorStage: [Double]] = [:]
        var isOpen = true
    }

    private struct State {
        var nextSessionSeq: UInt64 = 1
        var samples: [StageSample] = []
        var sessions: [SessionRecord] = []
        var activeSessions: Set<UInt64> = []
        var forcedCollection: Bool?
    }

    let maxSamples: Int
    let maxSessions: Int
    private let state: Mutex<State>

    init(
        maxSamples: Int = defaultMaxSamples,
        maxSessions: Int = defaultMaxSessions,
        forcedCollection: Bool? = nil
    ) {
        self.maxSamples = max(1, maxSamples)
        self.maxSessions = max(1, maxSessions)
        var initial = State()
        initial.forcedCollection = forcedCollection
        self.state = Mutex(initial)
    }

    /// Reads the process resident footprint via Mach `task_vm_info` (`phys_footprint`).
    static func currentPhysFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    static var uptimeMs: Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
    }

    private static let hasDiagnosticLaunchArg: Bool = {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--native-diagnostics") || args.contains("--native-scroll-sampler")
    }()

    typealias IntervalToken = (signpostID: OSSignpostID, state: OSSignpostIntervalState, startNs: UInt64)

    var isCollecting: Bool {
        if let forced = state.withLock({ $0.forcedCollection }) {
            return forced
        }
        return NativeEditorPreference.isEnabled() || Self.hasDiagnosticLaunchArg
    }

    func setForcedCollection(_ forced: Bool?) {
        state.withLock { $0.forcedCollection = forced }
    }

    @discardableResult
    func beginSession() -> UInt64 {
        guard isCollecting else { return 0 }
        let footprint = Self.currentPhysFootprintBytes()
        return state.withLock { state in
            guard Self.shouldCollectLocked(state) else { return 0 }
            let seq = state.nextSessionSeq
            state.nextSessionSeq &+= 1
            var record = SessionRecord(seq: seq)
            record.memory.baselineBytes = footprint
            record.memory.peakBytes = footprint
            Self.appendSessionLocked(&state, record: record, maxSessions: maxSessions)
            state.activeSessions.insert(seq)
            return seq
        }
    }

    func endSession(_ sessionSeq: UInt64) {
        guard sessionSeq != 0, isCollecting else { return }
        let footprint = Self.currentPhysFootprintBytes()
        state.withLock { state in
            state.activeSessions.remove(sessionSeq)
            guard let index = state.sessions.firstIndex(where: { $0.seq == sessionSeq }) else { return }
            state.sessions[index].isOpen = false
            state.sessions[index].memory.steadyBytes = footprint
            let baseline = Int64(bitPattern: state.sessions[index].memory.baselineBytes)
            let current = Int64(bitPattern: footprint)
            state.sessions[index].memory.closeDeltaBytes = current - baseline
        }
    }

    func sampleMemory(sessionSeq: UInt64, steady: Bool = false) {
        guard sessionSeq != 0, isCollecting else { return }
        let footprint = Self.currentPhysFootprintBytes()
        guard footprint > 0 else { return }
        state.withLock { state in
            guard Self.shouldCollectLocked(state),
                let index = state.sessions.firstIndex(where: { $0.seq == sessionSeq })
            else { return }
            if footprint > state.sessions[index].memory.peakBytes {
                state.sessions[index].memory.peakBytes = footprint
            }
            if steady {
                state.sessions[index].memory.steadyBytes = footprint
            }
        }
    }

    func beginInterval(_ stage: NativeEditorStage) -> IntervalToken? {
        guard isCollecting else { return nil }
        let id = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval("NativeEditorStage", id: id, "\(stage.rawValue, privacy: .public)")
        return (id, interval, DispatchTime.now().uptimeNanoseconds)
    }

    func endInterval(
        _ stage: NativeEditorStage,
        token: IntervalToken?,
        sessionSeq: UInt64 = 0,
        byteCount: Int = 0,
        itemCount: Int = 0
    ) {
        guard let token, isCollecting else { return }
        let endNs = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Double(endNs &- token.startNs) / 1_000_000.0
        Self.signposter.endInterval(
            "NativeEditorStage",
            token.state,
            "stage=\(stage.rawValue, privacy: .public) bytes=\(byteCount) items=\(itemCount)")
        recordDuration(stage, durationMs: elapsedMs, sessionSeq: sessionSeq, byteCount: byteCount, itemCount: itemCount)
    }

    func measure<T>(
        _ stage: NativeEditorStage,
        sessionSeq: UInt64 = 0,
        byteCount: Int = 0,
        itemCount: Int = 0,
        body: () throws -> T
    ) rethrows -> T {
        guard let token = beginInterval(stage) else {
            return try body()
        }
        defer { endInterval(stage, token: token, sessionSeq: sessionSeq, byteCount: byteCount, itemCount: itemCount) }
        return try body()
    }

    func recordDuration(
        _ stage: NativeEditorStage,
        durationMs: Double,
        sessionSeq: UInt64 = 0,
        byteCount: Int = 0,
        itemCount: Int = 0
    ) {
        guard isCollecting else { return }
        let sanitizedDuration = max(0, durationMs)
        Self.signposter.emitEvent(
            "NativeEditorMetric",
            "stage=\(stage.rawValue, privacy: .public) session=\(sessionSeq) bytes=\(byteCount) items=\(itemCount)")
        let nowMs = Self.uptimeMs
        state.withLock { state in
            guard Self.shouldCollectLocked(state) else { return }
            let sample = StageSample(
                sessionSeq: sessionSeq,
                stage: stage,
                durationMs: sanitizedDuration,
                byteCount: max(0, byteCount),
                itemCount: max(0, itemCount),
                timestampUptimeMs: nowMs)
            state.samples.append(sample)
            if state.samples.count > maxSamples {
                state.samples.removeFirst(state.samples.count - maxSamples)
            }
            if sessionSeq != 0, let index = state.sessions.firstIndex(where: { $0.seq == sessionSeq }) {
                var durations = state.sessions[index].stageSamples[stage] ?? []
                durations.append(sanitizedDuration)
                if durations.count > maxSamples {
                    durations.removeFirst(durations.count - maxSamples)
                }
                state.sessions[index].stageSamples[stage] = durations
            }
        }
    }

    func recordWorkload(_ metrics: ReplicaWorkloadMetrics, sessionSeq: UInt64) {
        guard sessionSeq != 0, isCollecting else { return }
        state.withLock { state in
            guard Self.shouldCollectLocked(state) else { return }
            let index = Self.ensureSessionLocked(&state, seq: sessionSeq, maxSessions: maxSessions)
            state.sessions[index].workload = metrics
        }
    }

    func mutateCounters(sessionSeq: UInt64, _ mutate: (inout SurfaceWorkCounters) -> Void) {
        guard sessionSeq != 0, isCollecting else { return }
        state.withLock { state in
            guard Self.shouldCollectLocked(state) else { return }
            let index = Self.ensureSessionLocked(&state, seq: sessionSeq, maxSessions: maxSessions)
            mutate(&state.sessions[index].counters)
        }
    }

    func snapshot() -> NativeEditorDiagnosticsSnapshot {
        state.withLock { state in
            var byStage: [NativeEditorStage: [Double]] = [:]
            for sample in state.samples {
                byStage[sample.stage, default: []].append(sample.durationMs)
            }
            var distributions: [String: StageDistribution] = [:]
            for (stage, durations) in byStage {
                distributions[stage.rawValue] = StageDistribution.compute(from: durations)
            }
            let summaries = state.sessions.map { record in
                var stageMap: [String: StageDistribution] = [:]
                for (stage, durations) in record.stageSamples {
                    stageMap[stage.rawValue] = StageDistribution.compute(from: durations)
                }
                return SessionDiagnosticsSummary(
                    sessionSeq: record.seq,
                    workload: record.workload,
                    counters: record.counters,
                    memory: record.memory,
                    stages: stageMap,
                    isOpen: record.isOpen)
            }
            return NativeEditorDiagnosticsSnapshot(
                schemaVersion: 1,
                generatedUptimeMs: Self.uptimeMs,
                activeSessionCount: state.activeSessions.count,
                totalSampleCount: state.samples.count,
                stageDistributions: distributions,
                recentSamples: state.samples,
                sessions: summaries)
        }
    }

    func sessionSummary(for sessionSeq: UInt64) -> SessionDiagnosticsSummary? {
        snapshot().sessions.first { $0.sessionSeq == sessionSeq }
    }

    func sanitizedJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot()), let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    func reset() {
        state.withLock { state in
            state.samples.removeAll(keepingCapacity: false)
            state.sessions.removeAll(keepingCapacity: false)
            state.activeSessions.removeAll(keepingCapacity: false)
        }
    }

    private static func shouldCollectLocked(_ state: State) -> Bool {
        if let forced = state.forcedCollection { return forced }
        return NativeEditorPreference.isEnabled() || hasDiagnosticLaunchArg
    }

    private static func ensureSessionLocked(_ state: inout State, seq: UInt64, maxSessions: Int) -> Int {
        if let index = state.sessions.firstIndex(where: { $0.seq == seq }) {
            return index
        }
        let record = SessionRecord(seq: seq)
        appendSessionLocked(&state, record: record, maxSessions: maxSessions)
        return state.sessions.count - 1
    }

    private static func appendSessionLocked(_ state: inout State, record: SessionRecord, maxSessions: Int) {
        state.sessions.append(record)
        if state.sessions.count > maxSessions {
            state.sessions.removeFirst(state.sessions.count - maxSessions)
        }
    }
}
