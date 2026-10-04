import CryptoKit
import Foundation
import SwiftData

enum LocalThreadListSearchPolicy {
    static func matches(query: String, fields: [String?]) -> Bool {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard terms.isEmpty == false else { return true }

        let searchableText = fields.compactMap { $0 }.joined(separator: "\n")
        let options: String.CompareOptions = [
            .caseInsensitive,
            .diacriticInsensitive,
            .widthInsensitive
        ]
        return terms.allSatisfy { term in
            searchableText.range(of: term, options: options) != nil
        }
    }
}

enum LocalThreadListSelectionPolicy {
    static func retainedSelection(
        _ selection: Set<Int64>,
        visibleThreadIDs: [Int64]
    ) -> Set<Int64> {
        selection.intersection(Set(visibleThreadIDs))
    }

    static func selectionByTogglingAll(
        _ selection: Set<Int64>,
        visibleThreadIDs: [Int64]
    ) -> Set<Int64> {
        let visible = Set(visibleThreadIDs)
        guard visible.isEmpty == false else { return [] }
        let retained = selection.intersection(visible)
        return retained == visible ? [] : visible
    }
}

private enum ThreadReadingPositionDatabaseMutation: Sendable {
    case upsert(ThreadReadingPosition, limit: Int)
    case delete(threadID: Int64)
    case deleteAll
}

@available(iOS 17.0, *)
@ModelActor
private actor ThreadReadingPositionDatabaseActor {
    func apply(
        _ mutation: ThreadReadingPositionDatabaseMutation
    ) throws -> [ThreadReadingPosition] {
        switch mutation {
        case let .upsert(position, limit):
            return try upsert(position, limit: limit)
        case let .delete(threadID):
            return try delete(threadID: threadID)
        case .deleteAll:
            return try deleteAll()
        }
    }

    private func upsert(
        _ position: ThreadReadingPosition,
        limit: Int
    ) throws -> [ThreadReadingPosition] {
        try Task.checkCancellation()
        let effectiveLimit = min(
            max(limit, 0),
            LocalThreadLibraryPolicy.maximumReadingPositions
        )

        do {
            var records = try modelContext.fetch(
                FetchDescriptor<ThreadReadingPositionRecord>()
            )
            guard effectiveLimit > 0 else {
                for record in records {
                    modelContext.delete(record)
                }
                try Task.checkCancellation()
                try save()
                return []
            }

            if let existing = records.first(where: { $0.threadID == position.threadID }) {
                existing.postIDBitPattern = Int64(bitPattern: position.postID)
                existing.floor = position.floor
                existing.updatedAt = position.updatedAt
            } else {
                let inserted = ThreadReadingPositionRecord(entry: position, sortIndex: 0)
                modelContext.insert(inserted)
                records.append(inserted)
            }

            records.sort {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.threadID < $1.threadID
            }

            var seenThreadIDs = Set<Int64>()
            var retained: [ThreadReadingPositionRecord] = []
            retained.reserveCapacity(min(records.count, effectiveLimit))
            for record in records {
                guard seenThreadIDs.insert(record.threadID).inserted,
                      retained.count < effectiveLimit else {
                    modelContext.delete(record)
                    continue
                }
                record.sortIndex = retained.count
                retained.append(record)
            }
            try Task.checkCancellation()
            try save()
            return retained.map(\.entry)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func delete(threadID: Int64) throws -> [ThreadReadingPosition] {
        try Task.checkCancellation()
        let requestedThreadID = threadID
        do {
            let records = try modelContext.fetch(FetchDescriptor<ThreadReadingPositionRecord>(
                predicate: #Predicate { record in
                    record.threadID == requestedThreadID
                }
            ))
            for record in records {
                modelContext.delete(record)
            }
            try Task.checkCancellation()
            try save()
            return try orderedPositions()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func deleteAll() throws -> [ThreadReadingPosition] {
        try Task.checkCancellation()
        do {
            let records = try modelContext.fetch(
                FetchDescriptor<ThreadReadingPositionRecord>()
            )
            for record in records {
                modelContext.delete(record)
            }
            try Task.checkCancellation()
            try save()
            return []
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func orderedPositions() throws -> [ThreadReadingPosition] {
        try modelContext.fetch(FetchDescriptor<ThreadReadingPositionRecord>())
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(\.entry)
    }

    private func save() throws {
        guard modelContext.hasChanges else { return }
        try modelContext.save()
    }
}

struct ThreadReadingPosition: Codable, Equatable, Identifiable, Sendable {
    var threadID: Int64
    var postID: UInt64
    var floor: Int
    var updatedAt: Date

    var id: Int64 { threadID }
}

enum LocalThreadLibraryPolicy {
    static let maximumReadingPositions = 500

    static func readingPosition(
        threadID: Int64,
        postID: UInt64,
        floor: Int,
        updatedAt: Date
    ) -> ThreadReadingPosition? {
        // Restore targets the post ID; floor is display-only and hot-sorted
        // responses legitimately omit it (floor == 0).
        guard threadID > 0, postID > 0, floor >= 0 else { return nil }
        return ThreadReadingPosition(
            threadID: threadID,
            postID: postID,
            floor: floor,
            updatedAt: updatedAt
        )
    }

    static func addingReadingPosition(
        _ position: ThreadReadingPosition,
        to positions: [ThreadReadingPosition],
        limit: Int
    ) -> [ThreadReadingPosition] {
        let effectiveLimit = min(max(limit, 0), maximumReadingPositions)
        guard effectiveLimit > 0 else { return [] }
        var updated = positions.filter { $0.threadID != position.threadID }
        updated.insert(position, at: 0)
        return Array(updated.prefix(effectiveLimit))
    }

    static func sanitizedReadingPositions(
        _ positions: [ThreadReadingPosition],
        limit: Int
    ) -> [ThreadReadingPosition] {
        let effectiveLimit = min(max(limit, 0), maximumReadingPositions)
        guard effectiveLimit > 0 else { return [] }
        var seenThreadIDs = Set<Int64>()
        var result: [ThreadReadingPosition] = []

        let ordered = positions.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.threadID > $1.threadID
        }
        for position in ordered {
            guard position.threadID > 0,
                  position.postID > 0,
                  position.floor >= 0,
                  position.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  seenThreadIDs.insert(position.threadID).inserted else { continue }
            result.append(position)
            if result.count == effectiveLimit { break }
        }

        return result
    }

    private static func normalized(_ value: String, maximumLength: Int) -> String {
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        return String(collapsed.prefix(maximumLength))
    }
}

@MainActor
protocol ThreadReadingPositionPersistence: AnyObject {
    var capability: PersistenceCapability { get }

    func load() throws -> [ThreadReadingPosition]
    func replaceAll(
        _ positions: [ThreadReadingPosition],
        beforeCommit: () throws -> Void
    ) throws
    func upsert(_ position: ThreadReadingPosition, limit: Int) throws
    func remove(threadID: Int64) throws
    func removeAll(beforeCommit: () throws -> Void) throws
    func clearAll(beforeCommit: () throws -> Void) throws

    func upsertInBackground(
        _ position: ThreadReadingPosition,
        limit: Int
    ) async throws -> [ThreadReadingPosition]
    func removeInBackground(threadID: Int64) async throws -> [ThreadReadingPosition]
    func removeAllInBackground() async throws -> [ThreadReadingPosition]
}

extension ThreadReadingPositionPersistence {
    func replaceAll(_ positions: [ThreadReadingPosition]) throws {
        try replaceAll(positions, beforeCommit: {})
    }

    func removeAll() throws {
        try removeAll(beforeCommit: {})
    }

    func clearAll() throws {
        try clearAll(beforeCommit: {})
    }

    func upsertInBackground(
        _ position: ThreadReadingPosition,
        limit: Int
    ) async throws -> [ThreadReadingPosition] {
        try Task.checkCancellation()
        try upsert(position, limit: limit)
        return try load()
    }

    func removeInBackground(threadID: Int64) async throws -> [ThreadReadingPosition] {
        try Task.checkCancellation()
        try remove(threadID: threadID)
        return try load()
    }

    func removeAllInBackground() async throws -> [ThreadReadingPosition] {
        try Task.checkCancellation()
        try removeAll()
        return []
    }
}

enum ThreadReadingPositionBackend: String, Codable, Sendable {
    case secureFiles
    case swiftData
}

enum ThreadReadingPositionMigrationState: String, Codable, Sendable {
    case fileActive
    case nativeActivationPending
    case nativeSwiftData
    case fileMigrationCompleted
}

struct ThreadReadingPositionBackendActivation: Codable, Equatable, Sendable {
    static let currentMigrationVersion = 1

    let migrationVersion: Int
    let sourceFingerprint: String?
    let destinationGenerationID: String
    let completedAt: Date
}

struct ThreadReadingPositionBackendState: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let activeBackend: ThreadReadingPositionBackend
    let migrationState: ThreadReadingPositionMigrationState
    let retainedFilePositions: [ThreadReadingPosition]
    let activation: ThreadReadingPositionBackendActivation?

    static func initialFileBackend(
        positions: [ThreadReadingPosition] = []
    ) -> ThreadReadingPositionBackendState {
        ThreadReadingPositionBackendState(
            formatVersion: currentFormatVersion,
            activeBackend: .secureFiles,
            migrationState: .fileActive,
            retainedFilePositions: positions,
            activation: nil
        )
    }

    static func nativeSwiftData(
        generationID: String,
        now: Date
    ) -> ThreadReadingPositionBackendState {
        ThreadReadingPositionBackendState(
            formatVersion: currentFormatVersion,
            activeBackend: .swiftData,
            migrationState: .nativeSwiftData,
            retainedFilePositions: [],
            activation: ThreadReadingPositionBackendActivation(
                migrationVersion: ThreadReadingPositionBackendActivation.currentMigrationVersion,
                sourceFingerprint: nil,
                destinationGenerationID: generationID,
                completedAt: now
            )
        )
    }

    static func pendingNativeSwiftData(
        generationID: String,
        now: Date
    ) -> ThreadReadingPositionBackendState {
        ThreadReadingPositionBackendState(
            formatVersion: currentFormatVersion,
            activeBackend: .swiftData,
            migrationState: .nativeActivationPending,
            retainedFilePositions: [],
            activation: ThreadReadingPositionBackendActivation(
                migrationVersion: ThreadReadingPositionBackendActivation.currentMigrationVersion,
                sourceFingerprint: nil,
                destinationGenerationID: generationID,
                completedAt: now
            )
        )
    }

    static func migratedToSwiftData(
        retainedFilePositions: [ThreadReadingPosition],
        sourceFingerprint: String,
        generationID: String,
        now: Date
    ) -> ThreadReadingPositionBackendState {
        ThreadReadingPositionBackendState(
            formatVersion: currentFormatVersion,
            activeBackend: .swiftData,
            migrationState: .fileMigrationCompleted,
            retainedFilePositions: retainedFilePositions,
            activation: ThreadReadingPositionBackendActivation(
                migrationVersion: ThreadReadingPositionBackendActivation.currentMigrationVersion,
                sourceFingerprint: sourceFingerprint,
                destinationGenerationID: generationID,
                completedAt: now
            )
        )
    }

    func validated() throws -> ThreadReadingPositionBackendState {
        guard formatVersion == Self.currentFormatVersion else {
            throw ThreadReadingPositionPersistenceFactoryError.unsupportedStateVersion(
                formatVersion
            )
        }
        switch (activeBackend, migrationState, activation) {
        case (.secureFiles, .fileActive, nil):
            return self
        case let (.swiftData, .nativeActivationPending, activation?):
            guard activation.migrationVersion
                    == ThreadReadingPositionBackendActivation.currentMigrationVersion,
                  activation.sourceFingerprint == nil,
                  retainedFilePositions.isEmpty,
                  UUID(uuidString: activation.destinationGenerationID) != nil else {
                throw ThreadReadingPositionPersistenceFactoryError.invalidState
            }
            return self
        case let (.swiftData, .nativeSwiftData, activation?):
            guard activation.migrationVersion
                    == ThreadReadingPositionBackendActivation.currentMigrationVersion,
                  activation.sourceFingerprint == nil,
                  retainedFilePositions.isEmpty,
                  UUID(uuidString: activation.destinationGenerationID) != nil else {
                throw ThreadReadingPositionPersistenceFactoryError.invalidState
            }
            return self
        case let (.swiftData, .fileMigrationCompleted, activation?):
            guard activation.migrationVersion
                    == ThreadReadingPositionBackendActivation.currentMigrationVersion,
                  let sourceFingerprint = activation.sourceFingerprint,
                  sourceFingerprint.count == 64,
                  try ThreadReadingPositionFileMigration.fingerprint(
                    retainedFilePositions
                  ) == sourceFingerprint,
                  UUID(uuidString: activation.destinationGenerationID) != nil else {
                throw ThreadReadingPositionPersistenceFactoryError.invalidState
            }
            return self
        default:
            throw ThreadReadingPositionPersistenceFactoryError.invalidState
        }
    }
}

@MainActor
protocol ThreadReadingPositionMigrationDestination: ThreadReadingPositionPersistence {
    func backendGenerationID() throws -> String?
    func establishNativeBackendMarker(generationID: String) throws
    /// Rewrites the store's backend marker to the committed generation,
    /// replacing a marker left behind by an earlier database. Reading positions
    /// are never touched: the generation only identifies the backend.
    func replaceNativeBackendMarker(generationID: String) throws
    func replaceAllForMigration(
        _ positions: [ThreadReadingPosition],
        generationID: String
    ) throws
}

@MainActor
final class FileThreadReadingPositionPersistence: ThreadReadingPositionPersistence {
    enum StorageError: Error, Equatable {
        case backendIsNotActive
    }

    let capability: PersistenceCapability
    let fileURL: URL

    private let fileManager: FileManager
    private let stateFile: SecureCodableFile<ThreadReadingPositionBackendState>

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        capability: PersistenceCapability = .durable
    ) throws {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.capability = capability
        stateFile = try SecureCodableFile<ThreadReadingPositionBackendState>(
            directoryURL: fileURL.deletingLastPathComponent(),
            fileName: fileURL.lastPathComponent,
            fileManager: fileManager
        )
    }

    var hasStateArtifacts: Bool {
        fileManager.fileExists(atPath: stateFile.fileURL.path)
            || fileManager.fileExists(atPath: stateFile.backupURL.path)
    }

    func loadBackendState() throws -> ThreadReadingPositionBackendState? {
        try stateFile.load()?.validated()
    }

    func initializeFileBackendIfNeeded() throws {
        guard try loadBackendState() == nil else { return }
        try stateFile.replace(.initialFileBackend())
    }

    func load() throws -> [ThreadReadingPosition] {
        guard let state = try loadBackendState() else { return [] }
        guard state.activeBackend == .secureFiles else {
            throw StorageError.backendIsNotActive
        }
        return state.retainedFilePositions
    }

    func replaceAll(
        _ positions: [ThreadReadingPosition],
        beforeCommit: () throws -> Void
    ) throws {
        let current = try loadBackendState() ?? .initialFileBackend()
        guard current.activeBackend == .secureFiles else {
            throw StorageError.backendIsNotActive
        }
        try stateFile.replace(.initialFileBackend(positions: positions)) {
            try Task.checkCancellation()
            try beforeCommit()
        }
    }

    func upsert(_ position: ThreadReadingPosition, limit: Int) throws {
        let current = LocalThreadLibraryPolicy.sanitizedReadingPositions(
            try load(),
            limit: limit
        )
        try replaceAll(LocalThreadLibraryPolicy.addingReadingPosition(
            position,
            to: current,
            limit: limit
        ))
    }

    func remove(threadID: Int64) throws {
        let current = try load()
        try replaceAll(current.filter { $0.threadID != threadID })
    }

    func removeAll(beforeCommit: () throws -> Void) throws {
        try replaceAll([], beforeCommit: beforeCommit)
    }

    func clearAll(beforeCommit: () throws -> Void) throws {
        try removeAll(beforeCommit: beforeCommit)
    }

    func prepareNativeSwiftDataActivation(
        generationID: String,
        now: Date
    ) throws -> ThreadReadingPositionBackendState {
        guard try loadBackendState() == nil else {
            throw ThreadReadingPositionPersistenceFactoryError.invalidState
        }
        let pendingState = ThreadReadingPositionBackendState.pendingNativeSwiftData(
            generationID: generationID,
            now: now
        )
        _ = try pendingState.validated()
        try stateFile.replace(pendingState)
        return pendingState
    }

    func activateNativeSwiftData(
        pendingState: ThreadReadingPositionBackendState,
        now: Date
    ) throws {
        guard pendingState.migrationState == .nativeActivationPending,
              let generationID = pendingState.activation?.destinationGenerationID,
              try loadBackendState() == pendingState else {
            throw ThreadReadingPositionPersistenceFactoryError.invalidState
        }
        try stateFile.replace(.nativeSwiftData(generationID: generationID, now: now))
    }

    func activateMigratedSwiftData(
        sourceState: ThreadReadingPositionBackendState,
        retainedFilePositions: [ThreadReadingPosition],
        sourceFingerprint: String,
        generationID: String,
        now: Date
    ) throws {
        guard try loadBackendState() == sourceState,
              sourceState.activeBackend == .secureFiles else {
            throw ThreadReadingPositionPersistenceFactoryError.sourceChangedDuringMigration
        }
        try stateFile.replace(.migratedToSwiftData(
            retainedFilePositions: retainedFilePositions,
            sourceFingerprint: sourceFingerprint,
            generationID: generationID,
            now: now
        ))
    }
}

@MainActor
private final class UnavailableThreadReadingPositionPersistence:
    ThreadReadingPositionPersistence {
    enum BackendError: Error {
        case unavailable
    }

    let capability: PersistenceCapability = .unavailable

    func load() throws -> [ThreadReadingPosition] { throw BackendError.unavailable }

    func replaceAll(
        _ positions: [ThreadReadingPosition],
        beforeCommit: () throws -> Void
    ) throws {
        throw BackendError.unavailable
    }

    func upsert(_ position: ThreadReadingPosition, limit: Int) throws {
        throw BackendError.unavailable
    }

    func remove(threadID: Int64) throws { throw BackendError.unavailable }

    func removeAll(beforeCommit: () throws -> Void) throws {
        throw BackendError.unavailable
    }

    func clearAll(beforeCommit: () throws -> Void) throws {
        throw BackendError.unavailable
    }
}

@available(iOS 17.0, *)
@MainActor
final class SwiftDataThreadReadingPositionPersistence:
    ThreadReadingPositionMigrationDestination {
    enum MarkerError: Error, Equatable {
        case invalidMarker
    }

    private static let markerKey = "thread-reading-position-backend"
    private static let markerFormatVersion = 1

    let capability: PersistenceCapability

    private let modelContext: ModelContext
    private let databaseActorTask: Task<ThreadReadingPositionDatabaseActor, Never>

    init(
        modelContainer: ModelContainer,
        persistenceAvailability: PersistenceAvailability? = nil
    ) {
        modelContext = modelContainer.mainContext
        let resolvedAvailability = persistenceAvailability
            ?? AppModelContainer.persistenceAvailability(for: modelContainer)
        if resolvedAvailability.canPersist {
            capability = AppModelContainer.allowsLegacyCleanup(for: modelContainer)
                ? .durable
                : .fallback
        } else {
            capability = .fallback
        }
        databaseActorTask = Task.detached(priority: .utility) {
            ThreadReadingPositionDatabaseActor(modelContainer: modelContainer)
        }
    }

    func load() throws -> [ThreadReadingPosition] {
        try PersistedRecordStore.fetchOrdered(
            ThreadReadingPositionRecord.self,
            in: modelContext
        ).map(\.entry)
    }

    func replaceAll(
        _ positions: [ThreadReadingPosition],
        beforeCommit: () throws -> Void
    ) throws {
        try PersistedRecordStore.replaceAll(
            ThreadReadingPositionRecord.self,
            with: positions.enumerated().map {
                ThreadReadingPositionRecord(entry: $0.element, sortIndex: $0.offset)
            },
            in: modelContext,
            beforeSave: beforeCommit
        )
    }

    func upsert(_ position: ThreadReadingPosition, limit: Int) throws {
        try PersistedRecordStore.upsertReadingPosition(
            position,
            limit: limit,
            in: modelContext
        )
    }

    func remove(threadID: Int64) throws {
        try PersistedRecordStore.deleteReadingPosition(
            threadID: threadID,
            in: modelContext
        )
    }

    func removeAll(beforeCommit: () throws -> Void) throws {
        try replaceAll([], beforeCommit: beforeCommit)
    }

    func backendGenerationID() throws -> String? {
        let markers = try modelContext.fetch(
            FetchDescriptor<ThreadReadingPositionBackendMarkerRecord>()
        )
        guard markers.isEmpty == false else { return nil }
        guard markers.count == 1,
              let marker = markers.first,
              marker.key == Self.markerKey,
              marker.formatVersion == Self.markerFormatVersion,
              UUID(uuidString: marker.generationID) != nil else {
            throw MarkerError.invalidMarker
        }
        return marker.generationID
    }

    func establishNativeBackendMarker(generationID: String) throws {
        guard UUID(uuidString: generationID) != nil else {
            throw MarkerError.invalidMarker
        }
        if let existing = try backendGenerationID() {
            guard existing == generationID else { throw MarkerError.invalidMarker }
            return
        }
        do {
            modelContext.insert(ThreadReadingPositionBackendMarkerRecord(
                key: Self.markerKey,
                formatVersion: Self.markerFormatVersion,
                generationID: generationID
            ))
            try modelContext.save()
            guard try backendGenerationID() == generationID else {
                throw MarkerError.invalidMarker
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Adopts the committed state file's generation over a marker row left by
    /// an earlier database. Only the marker is rewritten, so no reading
    /// position can be lost.
    func replaceNativeBackendMarker(generationID: String) throws {
        guard UUID(uuidString: generationID) != nil else {
            throw MarkerError.invalidMarker
        }
        do {
            for marker in try modelContext.fetch(
                FetchDescriptor<ThreadReadingPositionBackendMarkerRecord>()
            ) {
                modelContext.delete(marker)
            }
            modelContext.insert(ThreadReadingPositionBackendMarkerRecord(
                key: Self.markerKey,
                formatVersion: Self.markerFormatVersion,
                generationID: generationID
            ))
            try modelContext.save()
            guard try backendGenerationID() == generationID else {
                throw MarkerError.invalidMarker
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func replaceAllForMigration(
        _ positions: [ThreadReadingPosition],
        generationID: String
    ) throws {
        guard UUID(uuidString: generationID) != nil else {
            throw MarkerError.invalidMarker
        }
        do {
            try Task.checkCancellation()
            for record in try modelContext.fetch(
                FetchDescriptor<ThreadReadingPositionRecord>()
            ) {
                modelContext.delete(record)
            }
            for marker in try modelContext.fetch(
                FetchDescriptor<ThreadReadingPositionBackendMarkerRecord>()
            ) {
                modelContext.delete(marker)
            }
            for (index, position) in positions.enumerated() {
                modelContext.insert(ThreadReadingPositionRecord(
                    entry: position,
                    sortIndex: index
                ))
            }
            modelContext.insert(ThreadReadingPositionBackendMarkerRecord(
                key: Self.markerKey,
                formatVersion: Self.markerFormatVersion,
                generationID: generationID
            ))
            try Task.checkCancellation()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func clearAll(beforeCommit: () throws -> Void) throws {
        try PersistedRecordStore.clearThreadLibrary(
            in: modelContext,
            beforeSave: beforeCommit
        )
    }

    func upsertInBackground(
        _ position: ThreadReadingPosition,
        limit: Int
    ) async throws -> [ThreadReadingPosition] {
        let databaseActor = await databaseActorTask.value
        return try await databaseActor.apply(.upsert(position, limit: limit))
    }

    func removeInBackground(threadID: Int64) async throws -> [ThreadReadingPosition] {
        let databaseActor = await databaseActorTask.value
        return try await databaseActor.apply(.delete(threadID: threadID))
    }

    func removeAllInBackground() async throws -> [ThreadReadingPosition] {
        let databaseActor = await databaseActorTask.value
        return try await databaseActor.apply(.deleteAll)
    }

    func purgeRetiredFavorites() {
        guard capability.acceptsUserMutations else { return }
        do {
            try PersistedRecordStore.replaceAll(
                ThreadFavoriteRecord.self,
                with: [],
                in: modelContext
            )
        } catch {
            PersistenceDiagnostics.report(error, operation: "purge retired thread favorites")
        }
    }
}

enum ThreadReadingPositionPersistenceFactoryError: Error, Equatable {
    case backendUnavailable
    case unsupportedStateVersion(Int)
    case invalidState
    case swiftDataUnavailable
    case destinationIsNotDurable
    case migrationVerificationFailed
    case sourceChangedDuringMigration
    case markerMismatch
}

enum ThreadReadingPositionFileMigration {
    static func fingerprint(
        _ positions: [ThreadReadingPosition]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(positions)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

@MainActor
struct ThreadReadingPositionPersistenceFactory {
    typealias SwiftDataBuilder = @MainActor () throws ->
        any ThreadReadingPositionMigrationDestination

    private let fileURL: URL
    private let fileManager: FileManager
    private let supportsSwiftData: Bool
    private let now: () -> Date
    private let makeSwiftData: SwiftDataBuilder

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        supportsSwiftData: Bool,
        now: @escaping () -> Date = Date.init,
        makeSwiftData: @escaping SwiftDataBuilder
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.supportsSwiftData = supportsSwiftData
        self.now = now
        self.makeSwiftData = makeSwiftData
    }

    func make() -> any ThreadReadingPositionPersistence {
        do {
            let file = try FileThreadReadingPositionPersistence(
                fileURL: fileURL,
                fileManager: fileManager
            )
            if let state = try file.loadBackendState() {
                return try resolve(state: state, file: file)
            }
            return try makeInitial(file: file)
        } catch {
            PersistenceDiagnostics.report(
                error,
                operation: "resolve reading position persistence backend"
            )
            return UnavailableThreadReadingPositionPersistence()
        }
    }

    private func makeInitial(
        file: FileThreadReadingPositionPersistence
    ) throws -> any ThreadReadingPositionPersistence {
        guard supportsSwiftData else {
            try file.initializeFileBackendIfNeeded()
            return file
        }

        let destination = try makeSwiftData()
        guard destination.capability.isDurable else {
            throw ThreadReadingPositionPersistenceFactoryError.destinationIsNotDurable
        }
        // A marker without state is a lost activation commit. The database is
        // still the only copy of the positions, so re-elect the backend token
        // over a leftover one instead of leaving reading positions unavailable
        // for the rest of the install; no position row is touched.
        let leftoverGeneration = try destination.backendGenerationID()
        let generationID = UUID().uuidString.lowercased()
        let pendingState = try file.prepareNativeSwiftDataActivation(
            generationID: generationID,
            now: now()
        )
        if let leftoverGeneration {
            PersistenceDiagnostics.note(
                "阅读进度后端：只找到数据库标记（\(leftoverGeneration)）而没有状态文件，已重新选举后端标记（未删除任何记录）"
            )
            try destination.replaceNativeBackendMarker(generationID: generationID)
        } else {
            try destination.establishNativeBackendMarker(generationID: generationID)
        }
        guard try destination.backendGenerationID() == generationID else {
            throw ThreadReadingPositionPersistenceFactoryError.markerMismatch
        }
        try file.activateNativeSwiftData(pendingState: pendingState, now: now())
        return destination
    }

    private func resolve(
        state: ThreadReadingPositionBackendState,
        file: FileThreadReadingPositionPersistence
    ) throws -> any ThreadReadingPositionPersistence {
        switch state.migrationState {
        case .fileActive:
            guard supportsSwiftData else { return file }
            do {
                return try migrateToSwiftData(sourceState: state, file: file)
            } catch {
                PersistenceDiagnostics.report(
                    error,
                    operation: "migrate file reading positions to SwiftData"
                )
                return file
            }

        case .nativeActivationPending:
            guard supportsSwiftData else {
                throw ThreadReadingPositionPersistenceFactoryError.swiftDataUnavailable
            }
            let destination = try makeSwiftData()
            guard destination.capability.isDurable else {
                throw ThreadReadingPositionPersistenceFactoryError.destinationIsNotDurable
            }
            guard let expectedGeneration = state.activation?.destinationGenerationID else {
                throw ThreadReadingPositionPersistenceFactoryError.invalidState
            }
            try Self.adoptCommittedGeneration(
                expectedGeneration,
                in: destination,
                context: "阅读进度后端",
                missingMarkerIsRepair: false
            )
            try file.activateNativeSwiftData(pendingState: state, now: now())
            return destination

        case .nativeSwiftData, .fileMigrationCompleted:
            guard supportsSwiftData else {
                throw ThreadReadingPositionPersistenceFactoryError.swiftDataUnavailable
            }
            let destination = try makeSwiftData()
            guard destination.capability.isDurable else {
                throw ThreadReadingPositionPersistenceFactoryError.destinationIsNotDurable
            }
            guard let expectedGeneration = state.activation?.destinationGenerationID else {
                throw ThreadReadingPositionPersistenceFactoryError.invalidState
            }
            try Self.adoptCommittedGeneration(
                expectedGeneration,
                in: destination,
                context: "阅读进度后端",
                missingMarkerIsRepair: true
            )
            return destination
        }
    }

    /// Makes the store's own marker agree with the committed state file.
    ///
    /// The state file is the backend-selection commit point and the marker is
    /// only the store's copy of the same token. A store whose marker is missing
    /// or belongs to an earlier database used to leave reading positions
    /// unavailable for the rest of the install with no recovery and no record
    /// of why. Rewriting the marker never touches a position record.
    private static func adoptCommittedGeneration(
        _ generationID: String,
        in destination: any ThreadReadingPositionMigrationDestination,
        context: String,
        missingMarkerIsRepair: Bool
    ) throws {
        guard let existingGeneration = try destination.backendGenerationID() else {
            try destination.establishNativeBackendMarker(generationID: generationID)
            if missingMarkerIsRepair {
                PersistenceDiagnostics.note(
                    "\(context)：数据库缺少后端标记，已按已提交状态重建（未删除任何记录）"
                )
            }
            return
        }
        guard existingGeneration != generationID else { return }
        try destination.replaceNativeBackendMarker(generationID: generationID)
        PersistenceDiagnostics.note(
            "\(context)：数据库标记与已提交状态不一致（库内 \(existingGeneration)，状态 \(generationID)），已按状态覆盖（未删除任何记录）"
        )
    }

    private func migrateToSwiftData(
        sourceState: ThreadReadingPositionBackendState,
        file: FileThreadReadingPositionPersistence
    ) throws -> any ThreadReadingPositionPersistence {
        guard sourceState.activeBackend == .secureFiles,
              sourceState.migrationState == .fileActive else {
            throw ThreadReadingPositionPersistenceFactoryError.invalidState
        }
        let destination = try makeSwiftData()
        guard destination.capability.isDurable else {
            throw ThreadReadingPositionPersistenceFactoryError.destinationIsNotDurable
        }
        let sourcePositions = LocalThreadLibraryPolicy.sanitizedReadingPositions(
            sourceState.retainedFilePositions,
            limit: LocalThreadLibraryPolicy.maximumReadingPositions
        )
        let sourceFingerprint = try ThreadReadingPositionFileMigration.fingerprint(
            sourcePositions
        )
        let generationID = UUID().uuidString.lowercased()
        try destination.replaceAllForMigration(sourcePositions, generationID: generationID)
        guard try destination.load() == sourcePositions,
              try destination.backendGenerationID() == generationID else {
            throw ThreadReadingPositionPersistenceFactoryError.migrationVerificationFailed
        }
        guard try file.loadBackendState() == sourceState else {
            throw ThreadReadingPositionPersistenceFactoryError.sourceChangedDuringMigration
        }
        try file.activateMigratedSwiftData(
            sourceState: sourceState,
            retainedFilePositions: sourcePositions,
            sourceFingerprint: sourceFingerprint,
            generationID: generationID,
            now: now()
        )
        return destination
    }
}

@MainActor
enum AppThreadReadingPositionPersistence {
    static let shared: any ThreadReadingPositionPersistence = makeDefault()

    private static func makeDefault(
        fileManager: FileManager = .default
    ) -> any ThreadReadingPositionPersistence {
        do {
            let location = try SecurePersistenceLocation.applicationSupport(
                fileManager: fileManager
            )
            let fileURL = location.directoryURL.appendingPathComponent(
                "thread-reading-position-backend.json",
                isDirectory: false
            )
            if #available(iOS 17.0, *) {
                let persistence = ThreadReadingPositionPersistenceFactory(
                    fileURL: fileURL,
                    fileManager: fileManager,
                    supportsSwiftData: true
                ) {
                    SwiftDataThreadReadingPositionPersistence(
                        modelContainer: AppModelContainer.shared
                    )
                }.make()
                if let swiftData = persistence as? SwiftDataThreadReadingPositionPersistence {
                    swiftData.purgeRetiredFavorites()
                }
                return persistence
            }
            return ThreadReadingPositionPersistenceFactory(
                fileURL: fileURL,
                fileManager: fileManager,
                supportsSwiftData: false
            ) {
                throw ThreadReadingPositionPersistenceFactoryError.swiftDataUnavailable
            }.make()
        } catch {
            PersistenceDiagnostics.report(
                error,
                operation: "open reading position persistence directory"
            )
            return UnavailableThreadReadingPositionPersistence()
        }
    }
}

@MainActor
final class LocalThreadLibraryStore: ObservableObject {
    static let shared = LocalThreadLibraryStore()

    private let defaults: UserDefaults
    private let favoritesKey: String
    private let readingPositionsKey: String
    private let readingPositionLimit: Int
    private let now: () -> Date
    private let persistence: any ThreadReadingPositionPersistence
    private let persistentBackendIsAvailable: Bool
    private let faultInjector: PersistenceFaultInjector
    private var readingPositionMutationTail: Task<Bool, Never>?
    private var readingPositionMutationTailID: UUID?
    private var pendingReadingPositionMutationCount = 0

    @Published private(set) var readingPositions: [ThreadReadingPosition]
    @Published private(set) var persistenceAvailability: PersistenceAvailability

    init(
        defaults: UserDefaults = .standard,
        favoritesKey: String = "dev.infinityf4p.tiebapure.threadFavorites",
        readingPositionsKey: String = "dev.infinityf4p.tiebapure.threadReadingPositions",
        readingPositionLimit: Int = LocalThreadLibraryPolicy.maximumReadingPositions,
        persistence: any ThreadReadingPositionPersistence,
        faultInjector: PersistenceFaultInjector = .none,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.favoritesKey = favoritesKey
        self.readingPositionsKey = readingPositionsKey
        self.readingPositionLimit = min(
            max(readingPositionLimit, 0),
            LocalThreadLibraryPolicy.maximumReadingPositions
        )
        self.now = now
        self.persistence = persistence
        self.faultInjector = faultInjector
        persistentBackendIsAvailable = persistence.capability.acceptsUserMutations
        persistenceAvailability = persistence.capability.availability
        var legacyPositionsFallback: [ThreadReadingPosition]?
        var legacyPositionsMigrationFailed = false
        do {
            try Self.migrateLegacyReadingPositions(
                defaults: defaults,
                key: readingPositionsKey,
                persistence: persistence,
                limit: self.readingPositionLimit,
                legacyFallback: &legacyPositionsFallback,
                faultInjector: faultInjector
            )
        } catch {
            PersistenceDiagnostics.report(error, operation: "migrate reading positions")
            self.persistenceAvailability = .unavailable
            legacyPositionsMigrationFailed = true
        }
        var loadedReadingPositions: [ThreadReadingPosition]
        do {
            let result = try Self.loadAndRepairReadingPositions(
                persistence: persistence,
                limit: self.readingPositionLimit,
                canRepair: persistentBackendIsAvailable,
                faultInjector: faultInjector
            )
            loadedReadingPositions = result.value
            if let error = result.repairError {
                PersistenceDiagnostics.report(error, operation: "repair reading positions")
                self.persistenceAvailability = .unavailable
            }
        } catch {
            PersistenceDiagnostics.report(error, operation: "load reading positions")
            loadedReadingPositions = legacyPositionsMigrationFailed ? (legacyPositionsFallback ?? []) : []
            self.persistenceAvailability = .unavailable
        }
        if legacyPositionsMigrationFailed, loadedReadingPositions.isEmpty,
           let legacyPositionsFallback {
            loadedReadingPositions = legacyPositionsFallback
        }
        readingPositions = loadedReadingPositions
        // Collections live on the Baidu account now. Keep only the historical
        // SwiftData schema compatibility; no local-favorite API is restored.
        defaults.removeObject(forKey: favoritesKey)
    }

    @discardableResult
    func reload() -> Bool {
        guard pendingReadingPositionMutationCount == 0 else { return false }
        var succeeded = true
        do {
            let result = try Self.loadAndRepairReadingPositions(
                persistence: persistence,
                limit: readingPositionLimit,
                canRepair: persistentBackendIsAvailable,
                faultInjector: faultInjector
            )
            readingPositions = result.value
            if let error = result.repairError {
                PersistenceDiagnostics.report(error, operation: "repair reading positions")
                succeeded = false
            }
        } catch {
            PersistenceDiagnostics.report(error, operation: "reload reading positions")
            succeeded = false
        }
        if succeeded {
            markPersistenceSucceeded()
        } else {
            persistenceAvailability = .unavailable
        }
        return succeeded
    }

    func position(for threadID: Int64) -> ThreadReadingPosition? {
        readingPositions.first { $0.threadID == threadID }
    }

    @discardableResult
    func recordReadingPositionInBackground(
        threadID: Int64,
        postID: UInt64,
        floor: Int
    ) async -> Bool {
        await enqueueReadingPosition(
            threadID: threadID,
            postID: postID,
            floor: floor
        ).value
    }

    func enqueueReadingPosition(
        threadID: Int64,
        postID: UInt64,
        floor: Int
    ) -> Task<Bool, Never> {
        guard let position = LocalThreadLibraryPolicy.readingPosition(
            threadID: threadID,
            postID: postID,
            floor: floor,
            updatedAt: now()
        ) else { return completedReadingPositionMutation(false) }
        if pendingReadingPositionMutationCount == 0,
           let current = self.position(for: threadID),
           current.postID == postID,
           current.floor == floor {
            return completedReadingPositionMutation(true)
        }
        return enqueueReadingPositionMutation(
            .upsert(position, limit: readingPositionLimit),
            operation: "save reading position"
        )
    }

    @discardableResult
    func clearReadingPositionInBackground(threadID: Int64) async -> Bool {
        await enqueueClearReadingPosition(threadID: threadID).value
    }

    func enqueueClearReadingPosition(threadID: Int64) -> Task<Bool, Never> {
        guard pendingReadingPositionMutationCount > 0
                || readingPositions.contains(where: { $0.threadID == threadID }) else {
            return completedReadingPositionMutation(true)
        }
        return enqueueReadingPositionMutation(
            .delete(threadID: threadID),
            operation: "clear reading position"
        )
    }

    @discardableResult
    func clearReadingPositionsInBackground() async -> Bool {
        await enqueueClearReadingPositions().value
    }

    func enqueueClearReadingPositions() -> Task<Bool, Never> {
        enqueueReadingPositionMutation(
            .deleteAll,
            operation: "clear reading positions",
            removesLegacyValueOnSuccess: true
        )
    }

    func waitForPendingReadingPositionMutations() async {
        while let tail = readingPositionMutationTail {
            _ = await tail.value
        }
    }

    @discardableResult
    func recordReadingPosition(threadID: Int64, postID: UInt64, floor: Int) -> Bool {
        guard pendingReadingPositionMutationCount == 0 else { return false }
        guard let position = LocalThreadLibraryPolicy.readingPosition(
            threadID: threadID,
            postID: postID,
            floor: floor,
            updatedAt: now()
        ) else { return false }
        if let current = self.position(for: threadID),
           current.postID == postID,
           current.floor == floor {
            return true
        }
        guard persistentBackendIsAvailable else {
            persistenceAvailability = .unavailable
            return false
        }
        let updated = LocalThreadLibraryPolicy.addingReadingPosition(
            position,
            to: readingPositions,
            limit: readingPositionLimit
        )
        do {
            try persistence.upsert(position, limit: readingPositionLimit)
            readingPositions = updated
            markPersistenceSucceeded()
            return true
        } catch {
            PersistenceDiagnostics.report(error, operation: "save reading position")
            persistenceAvailability = .unavailable
            return false
        }
    }

    @discardableResult
    func clearReadingPosition(threadID: Int64) -> Bool {
        guard pendingReadingPositionMutationCount == 0 else { return false }
        guard readingPositions.contains(where: { $0.threadID == threadID }) else { return true }
        guard persistentBackendIsAvailable else {
            persistenceAvailability = .unavailable
            return false
        }
        do {
            try persistence.remove(threadID: threadID)
            readingPositions.removeAll { $0.threadID == threadID }
            markPersistenceSucceeded()
            return true
        } catch {
            PersistenceDiagnostics.report(error, operation: "clear reading position")
            persistenceAvailability = .unavailable
            return false
        }
    }

    @discardableResult
    func clearReadingPositions() -> Bool {
        guard pendingReadingPositionMutationCount == 0 else { return false }
        guard persistentBackendIsAvailable else {
            persistenceAvailability = .unavailable
            return false
        }
        do {
            try persistence.removeAll()
            defaults.removeObject(forKey: readingPositionsKey)
            readingPositions = []
            markPersistenceSucceeded()
            return true
        } catch {
            PersistenceDiagnostics.report(error, operation: "clear reading positions")
            persistenceAvailability = .unavailable
            return false
        }
    }

    @discardableResult
    func clearAll() -> Bool {
        guard pendingReadingPositionMutationCount == 0 else { return false }
        guard persistentBackendIsAvailable else {
            persistenceAvailability = .unavailable
            return false
        }
        do {
            try persistence.clearAll {
                try faultInjector.check(.clearAll)
            }
            defaults.removeObject(forKey: readingPositionsKey)
            readingPositions = []
            markPersistenceSucceeded()
            return true
        } catch {
            PersistenceDiagnostics.report(error, operation: "clear local thread library")
            persistenceAvailability = .unavailable
            return false
        }
    }

    private func enqueueReadingPositionMutation(
        _ mutation: ThreadReadingPositionDatabaseMutation,
        operation: String,
        removesLegacyValueOnSuccess: Bool = false
    ) -> Task<Bool, Never> {
        guard persistentBackendIsAvailable else {
            persistenceAvailability = .unavailable
            return completedReadingPositionMutation(false)
        }

        let previousMutation = readingPositionMutationTail
        let mutationID = UUID()
        pendingReadingPositionMutationCount += 1
        readingPositionMutationTailID = mutationID

        let mutationTask = Task { @MainActor [weak self] in
            if let previousMutation {
                _ = await previousMutation.value
            }
            guard let self else { return false }
            defer {
                self.pendingReadingPositionMutationCount = max(
                    self.pendingReadingPositionMutationCount - 1,
                    0
                )
                if self.readingPositionMutationTailID == mutationID {
                    self.readingPositionMutationTail = nil
                    self.readingPositionMutationTailID = nil
                }
            }

            do {
                let persisted: [ThreadReadingPosition]
                switch mutation {
                case let .upsert(position, limit):
                    persisted = try await self.persistence.upsertInBackground(
                        position,
                        limit: limit
                    )
                case let .delete(threadID):
                    persisted = try await self.persistence.removeInBackground(
                        threadID: threadID
                    )
                case .deleteAll:
                    persisted = try await self.persistence.removeAllInBackground()
                }
                self.readingPositions = persisted
                if removesLegacyValueOnSuccess {
                    self.defaults.removeObject(forKey: self.readingPositionsKey)
                }
                self.markPersistenceSucceeded()
                return true
            } catch {
                PersistenceDiagnostics.report(error, operation: operation)
                self.persistenceAvailability = .unavailable
                return false
            }
        }
        readingPositionMutationTail = mutationTask
        return mutationTask
    }

    private func completedReadingPositionMutation(_ result: Bool) -> Task<Bool, Never> {
        Task { result }
    }

    private func markPersistenceSucceeded() {
        guard persistentBackendIsAvailable else { return }
        persistenceAvailability = .available
    }

    private static func loadAndRepairReadingPositions(
        persistence: any ThreadReadingPositionPersistence,
        limit: Int,
        canRepair: Bool,
        faultInjector: PersistenceFaultInjector = .none
    ) throws -> PersistenceLoadResult<[ThreadReadingPosition]> {
        let raw = try persistence.load()
        let sanitized = LocalThreadLibraryPolicy.sanitizedReadingPositions(
            raw,
            limit: limit
        )
        if canRepair, raw != sanitized {
            do {
                try persistence.replaceAll(sanitized) {
                    try faultInjector.check(.repair)
                }
            } catch {
                return PersistenceLoadResult(value: sanitized, repairError: error)
            }
        }
        return PersistenceLoadResult(value: sanitized, repairError: nil)
    }

    // One-time import of the pre-SwiftData UserDefaults JSON blob.
    private static func migrateLegacyReadingPositions(
        defaults: UserDefaults,
        key: String,
        persistence: any ThreadReadingPositionPersistence,
        limit: Int,
        legacyFallback: inout [ThreadReadingPosition]?,
        faultInjector: PersistenceFaultInjector
    ) throws {
        guard let data = defaults.data(forKey: key) else { return }
        let existing: [ThreadReadingPosition]
        do {
            existing = try persistence.load()
        } catch {
            if let decoded = PersistedArrayDecoder.decode(
                ThreadReadingPosition.self,
                from: data
            ) {
                legacyFallback = LocalThreadLibraryPolicy.sanitizedReadingPositions(
                    decoded,
                    limit: limit
                )
            }
            throw error
        }
        let source: [ThreadReadingPosition]
        if existing.isEmpty {
            guard let decoded = PersistedArrayDecoder.decode(
                ThreadReadingPosition.self,
                from: data
            ) else {
                throw LegacyStorageMigration.DecodeError.invalidTopLevelArray
            }
            source = LocalThreadLibraryPolicy.sanitizedReadingPositions(decoded, limit: limit)
            legacyFallback = source
        } else {
            source = existing
        }
        let sanitized = LocalThreadLibraryPolicy.sanitizedReadingPositions(source, limit: limit)
        try LegacyStorageMigration.persistThenRemoveLegacyValue(
            defaults: defaults,
            key: key,
            destinationIsDurable: persistence.capability.isDurable
        ) {
            try persistence.replaceAll(sanitized) {
                try faultInjector.check(.legacyMigration)
            }
        }
    }
}

extension LocalThreadLibraryStore {
    convenience init(
        defaults: UserDefaults = .standard,
        favoritesKey: String = "dev.infinityf4p.tiebapure.threadFavorites",
        readingPositionsKey: String = "dev.infinityf4p.tiebapure.threadReadingPositions",
        readingPositionLimit: Int = LocalThreadLibraryPolicy.maximumReadingPositions,
        faultInjector: PersistenceFaultInjector = .none,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(
            defaults: defaults,
            favoritesKey: favoritesKey,
            readingPositionsKey: readingPositionsKey,
            readingPositionLimit: readingPositionLimit,
            persistence: AppThreadReadingPositionPersistence.shared,
            faultInjector: faultInjector,
            now: now
        )
    }
}

@available(iOS 17.0, *)
extension LocalThreadLibraryStore {
    convenience init(
        defaults: UserDefaults = .standard,
        favoritesKey: String = "dev.infinityf4p.tiebapure.threadFavorites",
        readingPositionsKey: String = "dev.infinityf4p.tiebapure.threadReadingPositions",
        readingPositionLimit: Int = LocalThreadLibraryPolicy.maximumReadingPositions,
        modelContainer: ModelContainer,
        persistenceAvailability: PersistenceAvailability? = nil,
        faultInjector: PersistenceFaultInjector = .none,
        now: @escaping () -> Date = Date.init
    ) {
        let persistence = SwiftDataThreadReadingPositionPersistence(
            modelContainer: modelContainer,
            persistenceAvailability: persistenceAvailability
        )
        self.init(
            defaults: defaults,
            favoritesKey: favoritesKey,
            readingPositionsKey: readingPositionsKey,
            readingPositionLimit: readingPositionLimit,
            persistence: persistence,
            faultInjector: faultInjector,
            now: now
        )
        persistence.purgeRetiredFavorites()
    }
}
