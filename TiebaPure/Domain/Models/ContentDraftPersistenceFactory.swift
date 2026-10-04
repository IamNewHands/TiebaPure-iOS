import Foundation

struct ContentDraftMigrationReceipt: Codable, Equatable, Sendable {
    static let currentMigrationVersion = 1

    let migrationVersion: Int
    let sourceFingerprint: String
    let completedAt: Date

    func validated() throws -> ContentDraftMigrationReceipt {
        guard migrationVersion == Self.currentMigrationVersion,
              Self.isSHA256Hex(sourceFingerprint) else {
            throw ContentDraftPersistenceStateError.invalidState
        }
        return self
    }

    private static func isSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

enum ContentDraftAuthoritativeBackend: String, Codable, Sendable {
    case secureFiles
    case swiftData
    case pendingActivation
}

enum ContentDraftMigrationStatus: String, Codable, Sendable {
    case fileMigrationEligible
    case nativeActivationPending
    case notRequired
    case completed
}

struct ContentDraftPersistenceState: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let activeBackend: ContentDraftAuthoritativeBackend
    let migrationStatus: ContentDraftMigrationStatus
    let destinationGenerationID: String?
    let receipt: ContentDraftMigrationReceipt?

    static var activeFiles: ContentDraftPersistenceState {
        ContentDraftPersistenceState(
            formatVersion: currentFormatVersion,
            activeBackend: .secureFiles,
            migrationStatus: .fileMigrationEligible,
            destinationGenerationID: nil,
            receipt: nil
        )
    }

    static func initialSwiftData(
        generationID: String
    ) -> ContentDraftPersistenceState {
        ContentDraftPersistenceState(
            formatVersion: currentFormatVersion,
            activeBackend: .swiftData,
            migrationStatus: .notRequired,
            destinationGenerationID: generationID,
            receipt: nil
        )
    }

    static func nativeActivationPending(
        generationID: String
    ) -> ContentDraftPersistenceState {
        ContentDraftPersistenceState(
            formatVersion: currentFormatVersion,
            activeBackend: .pendingActivation,
            migrationStatus: .nativeActivationPending,
            destinationGenerationID: generationID,
            receipt: nil
        )
    }

    static func migrated(
        sourceFingerprint: String,
        generationID: String,
        completedAt: Date
    ) -> ContentDraftPersistenceState {
        ContentDraftPersistenceState(
            formatVersion: currentFormatVersion,
            activeBackend: .swiftData,
            migrationStatus: .completed,
            destinationGenerationID: generationID,
            receipt: ContentDraftMigrationReceipt(
                migrationVersion: ContentDraftMigrationReceipt.currentMigrationVersion,
                sourceFingerprint: sourceFingerprint,
                completedAt: completedAt
            )
        )
    }

    func validated() throws -> ContentDraftPersistenceState {
        guard formatVersion == Self.currentFormatVersion else {
            throw ContentDraftPersistenceStateError.unsupportedStateVersion(formatVersion)
        }
        switch (activeBackend, migrationStatus, destinationGenerationID, receipt) {
        case (.secureFiles, .fileMigrationEligible, nil, nil):
            return self
        case let (.pendingActivation, .nativeActivationPending, generationID?, nil):
            guard UUID(uuidString: generationID) != nil else {
                throw ContentDraftPersistenceStateError.invalidState
            }
            return self
        case let (.swiftData, .notRequired, generationID?, nil):
            guard UUID(uuidString: generationID) != nil else {
                throw ContentDraftPersistenceStateError.invalidState
            }
            return self
        case let (.swiftData, .completed, generationID?, receipt?):
            guard UUID(uuidString: generationID) != nil else {
                throw ContentDraftPersistenceStateError.invalidState
            }
            _ = try receipt.validated()
            return self
        default:
            throw ContentDraftPersistenceStateError.invalidState
        }
    }
}

enum ContentDraftPersistenceStateError: Error, Equatable {
    case unsupportedStateVersion(Int)
    case invalidState
    case ambiguousBackends
}

private actor ContentDraftMigrationCoordinator {
    static let shared = ContentDraftMigrationCoordinator()

    private var activeKeys = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ key: String) async {
        if activeKeys.insert(key).inserted { return }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    func release(_ key: String) {
        if var queued = waiters[key], queued.isEmpty == false {
            let continuation = queued.removeFirst()
            waiters[key] = queued.isEmpty ? nil : queued
            continuation.resume()
        } else {
            activeKeys.remove(key)
        }
    }
}

@MainActor
enum ContentDraftPersistenceFactory {
    static let stateFileName = "content-drafts-backend-state.json"

    static func makeApplicationBackend(
        fileManager: FileManager = .default
    ) -> any ContentDraftPersistenceBackend {
        do {
            let location = try SecurePersistenceLocation.applicationSupport(fileManager: fileManager)
            if #available(iOS 17.0, *) {
                return try resolveIOS17Backend(
                    directoryURL: location.directoryURL,
                    fileManager: fileManager,
                    swiftDataBackend: SwiftDataContentDraftPersistenceBackend(
                        modelContainer: AppModelContainer.shared
                    )
                )
            }
            return try resolveIOS16Backend(
                directoryURL: location.directoryURL,
                fileManager: fileManager
            )
        } catch {
            PersistenceDiagnostics.report(error, operation: "resolve content draft persistence backend")
            return UnavailableContentDraftPersistenceBackend()
        }
    }

    static func makeStateFile(
        directoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> SecureCodableFile<ContentDraftPersistenceState> {
        try SecureCodableFile(
            directoryURL: directoryURL,
            fileName: stateFileName,
            fileManager: fileManager,
            maximumByteCount: 64 * 1_024
        )
    }

    static func resolveIOS16Backend(
        directoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> any ContentDraftPersistenceBackend {
        let stateFile = try makeStateFile(directoryURL: directoryURL, fileManager: fileManager)
        if let state = try stateFile.load() {
            let state = try state.validated()
            guard state.activeBackend == .secureFiles else {
                throw ContentDraftPersistenceStateError.invalidState
            }
            let backend = try FileContentDraftPersistenceBackend(
                directoryURL: directoryURL,
                fileManager: fileManager
            )
            _ = try backend.catalogPresence()
            return backend
        }

        let backend = try FileContentDraftPersistenceBackend(
            directoryURL: directoryURL,
            fileManager: fileManager
        )
        _ = try backend.catalogPresence()
        try stateFile.replace(.activeFiles)
        return backend
    }

    @available(iOS 17.0, *)
    static func resolveIOS17Backend(
        directoryURL: URL,
        fileManager: FileManager = .default,
        swiftDataBackend: SwiftDataContentDraftPersistenceBackend
    ) throws -> any ContentDraftPersistenceBackend {
        let stateFile = try makeStateFile(directoryURL: directoryURL, fileManager: fileManager)
        if let state = try stateFile.load() {
            let state = try state.validated()
            switch state.activeBackend {
            case .pendingActivation:
                guard swiftDataBackend.persistenceAvailability.canPersist,
                      state.migrationStatus == .nativeActivationPending,
                      let generationID = state.destinationGenerationID else {
                    throw ContentDraftPersistenceError.unavailable
                }
                // A missing marker is the normal shape here: activation writes
                // the pending state before it writes the marker.
                try adoptCommittedGeneration(
                    generationID,
                    in: swiftDataBackend,
                    context: "草稿后端",
                    missingMarkerIsRepair: false
                )
                let activeState = ContentDraftPersistenceState.initialSwiftData(
                    generationID: generationID
                )
                _ = try activeState.validated()
                try stateFile.replace(activeState)
                return swiftDataBackend
            case .swiftData:
                guard swiftDataBackend.persistenceAvailability.canPersist else {
                    throw ContentDraftPersistenceError.unavailable
                }
                guard let generationID = state.destinationGenerationID else {
                    throw ContentDraftPersistenceError.destinationMarkerMismatch
                }
                // Once the state commits SwiftData as active, it remains the
                // sole authority. The retained source is deliberately not read.
                try adoptCommittedGeneration(
                    generationID,
                    in: swiftDataBackend,
                    context: "草稿后端",
                    missingMarkerIsRepair: true
                )
                return swiftDataBackend
            case .secureFiles:
                let source = try FileContentDraftPersistenceBackend(
                    directoryURL: directoryURL,
                    fileManager: fileManager
                )
                _ = try source.catalogPresence()
                guard swiftDataBackend.persistenceAvailability.canPersist else {
                    return source
                }
                return MigratingContentDraftPersistenceBackend(
                    source: source,
                    destination: swiftDataBackend,
                    stateFile: stateFile
                )
            }
        }

        let source = try FileContentDraftPersistenceBackend(
            directoryURL: directoryURL,
            fileManager: fileManager
        )
        let sourcePresence = try source.catalogPresence()
        guard sourcePresence == .absent else {
            // An iOS 16 file store always commits activeFiles before accepting
            // mutations. Missing state beside a catalog can therefore be a
            // lost migration commit; choosing either side could resurrect data.
            throw ContentDraftPersistenceStateError.ambiguousBackends
        }

        guard swiftDataBackend.persistenceAvailability.canPersist else {
            // On iOS 17 an unavailable SwiftData store may only be a transient
            // fallback. Electing an empty file backend here could later erase
            // durable SwiftData records when availability recovers.
            throw ContentDraftPersistenceError.unavailable
        }
        // A marker without state is a lost activation commit. The database is
        // still the only copy of the drafts, so re-elect the backend token over
        // a leftover one instead of refusing every draft read for the rest of
        // the install; no draft row is touched either way.
        let leftoverGeneration = try swiftDataBackend.backendGenerationID()
        let generationID = UUID().uuidString.lowercased()
        let pendingState = ContentDraftPersistenceState.nativeActivationPending(
            generationID: generationID
        )
        _ = try pendingState.validated()
        try stateFile.replace(pendingState)
        if let leftoverGeneration {
            PersistenceDiagnostics.note(
                "草稿后端：只找到数据库标记（\(leftoverGeneration)）而没有状态文件，已重新选举后端标记（未删除任何记录）"
            )
            try swiftDataBackend.replaceNativeBackendMarker(generationID: generationID)
        } else {
            try swiftDataBackend.installNativeBackendMarker(generationID: generationID)
        }
        guard try swiftDataBackend.backendGenerationID() == generationID else {
            throw ContentDraftPersistenceError.destinationMarkerMismatch
        }
        let initialState = ContentDraftPersistenceState.initialSwiftData(
            generationID: generationID
        )
        _ = try initialState.validated()
        try stateFile.replace(initialState)
        return swiftDataBackend
    }

    /// Makes the store's own marker agree with the committed state file.
    ///
    /// The state file is the backend-selection commit point and the marker is
    /// only the store's copy of the same token. A store whose marker is missing
    /// or belongs to an earlier database used to refuse every draft read for
    /// the rest of the install, with no way for the user to recover and no
    /// record of why. Rewriting the marker never touches a draft record, so a
    /// database rebuilt without one simply starts answering with the records it
    /// actually holds.
    @available(iOS 17.0, *)
    private static func adoptCommittedGeneration(
        _ generationID: String,
        in backend: SwiftDataContentDraftPersistenceBackend,
        context: String,
        missingMarkerIsRepair: Bool
    ) throws {
        guard let existingGeneration = try backend.backendGenerationID() else {
            try backend.installNativeBackendMarker(generationID: generationID)
            if missingMarkerIsRepair {
                PersistenceDiagnostics.note(
                    "\(context)：数据库缺少后端标记，已按已提交状态重建（未删除任何记录）"
                )
            }
            return
        }
        guard existingGeneration != generationID else { return }
        try backend.replaceNativeBackendMarker(generationID: generationID)
        PersistenceDiagnostics.note(
            "\(context)：数据库标记与已提交状态不一致（库内 \(existingGeneration)，状态 \(generationID)），已按状态覆盖（未删除任何记录）"
        )
    }
}

@MainActor
final class MigratingContentDraftPersistenceBackend: ContentDraftPersistenceBackend {
    private let source: any ContentDraftPersistenceBackend
    private let destination: any ContentDraftMigrationDestination
    private let stateFile: SecureCodableFile<ContentDraftPersistenceState>
    private let now: () -> Date
    private let beforeStateCommit: () throws -> Void
    private let beforeRecordRead: (String) async throws -> Void
    private var active: any ContentDraftPersistenceBackend
    private var migrationTask: Task<Void, Never>?
    private var migrationResolved = false

    init(
        source: any ContentDraftPersistenceBackend,
        destination: any ContentDraftMigrationDestination,
        stateFile: SecureCodableFile<ContentDraftPersistenceState>,
        now: @escaping () -> Date = Date.init,
        beforeStateCommit: @escaping () throws -> Void = {},
        beforeRecordRead: @escaping (String) async throws -> Void = { _ in }
    ) {
        self.source = source
        self.destination = destination
        self.stateFile = stateFile
        self.now = now
        self.beforeStateCommit = beforeStateCommit
        self.beforeRecordRead = beforeRecordRead
        active = source
    }

    var persistenceAvailability: PersistenceAvailability {
        active.persistenceAvailability
    }

    func load(
        accountID: String,
        target: ContentSubmissionTarget,
        into draft: inout ContentDraft?
    ) -> Bool {
        active.load(accountID: accountID, target: target, into: &draft)
    }

    func loadAsync(
        accountID: String,
        target: ContentSubmissionTarget
    ) async -> ContentDraftLoadOutcome {
        await ensureMigrationResolved()
        guard Task.isCancelled == false else { return .unavailable }
        return await active.loadAsync(accountID: accountID, target: target)
    }

    func save(_ draft: ContentDraft) -> Bool {
        active.save(draft)
    }

    func saveAsync(_ draft: ContentDraft) async throws {
        await ensureMigrationResolved()
        try Task.checkCancellation()
        try await active.saveAsync(draft)
    }

    func delete(accountID: String, target: ContentSubmissionTarget) -> Bool {
        active.delete(accountID: accountID, target: target)
    }

    func clear(accountID: String) -> Bool {
        active.clear(accountID: accountID)
    }

    func repairLegacyMetadataAndPruneAsync() async -> Bool {
        await ensureMigrationResolved()
        guard Task.isCancelled == false else { return false }
        return await active.repairLegacyMetadataAndPruneAsync()
    }

    func migrationManifest() async throws -> ContentDraftMigrationManifest {
        await ensureMigrationResolved()
        try Task.checkCancellation()
        return try await active.migrationManifest()
    }

    func migrationRecord(identity: String) async throws -> ContentDraftPersistenceRecord {
        await ensureMigrationResolved()
        try Task.checkCancellation()
        return try await active.migrationRecord(identity: identity)
    }

    func beginMigration(to manifest: ContentDraftMigrationManifest) async throws {
        await ensureMigrationResolved()
        try Task.checkCancellation()
        try await active.beginMigration(to: manifest)
    }

    func writeMigrationRecord(_ record: ContentDraftPersistenceRecord) async throws {
        await ensureMigrationResolved()
        try Task.checkCancellation()
        try await active.writeMigrationRecord(record)
    }

    private func ensureMigrationResolved() async {
        guard migrationResolved == false else { return }
        if migrationTask == nil {
            migrationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await performMigration()
            }
        }
        // Migration is backend-scoped work shared by every caller. A view task
        // disappearing must not cancel it for the rest of the process.
        await migrationTask?.value
    }

    private func performMigration() async {
        defer {
            migrationResolved = true
            migrationTask = nil
        }
        let coordinationKey = stateFile.fileURL.standardizedFileURL.path
        await ContentDraftMigrationCoordinator.shared.acquire(coordinationKey)
        do {
            try Task.checkCancellation()
            guard let state = try stateFile.load() else {
                throw ContentDraftPersistenceStateError.invalidState
            }
            let validatedState = try state.validated()
            switch validatedState.activeBackend {
            case .pendingActivation:
                throw ContentDraftPersistenceStateError.invalidState
            case .swiftData:
                guard let generationID = validatedState.destinationGenerationID,
                      try await destination.backendGenerationIDAsync() == generationID else {
                    throw ContentDraftPersistenceError.destinationMarkerMismatch
                }
                active = destination
                await ContentDraftMigrationCoordinator.shared.release(coordinationKey)
                return
            case .secureFiles:
                break
            }
            let sourceManifest = try await source.migrationManifest()
            let generationID = UUID().uuidString.lowercased()
            try await destination.beginMigration(
                to: sourceManifest,
                generationID: generationID
            )
            for expectedEntry in sourceManifest.entries {
                try Task.checkCancellation()
                try await beforeRecordRead(expectedEntry.identity)
                try Task.checkCancellation()
                let record = try await source.migrationRecord(identity: expectedEntry.identity)
                guard try ContentDraftMigrationManifestEntry(record: record) == expectedEntry else {
                    throw ContentDraftPersistenceError.sourceChangedDuringMigration
                }
                try await destination.writeMigrationRecord(record)
            }

            let destinationManifest = try await destination.migrationManifest()
            guard destinationManifest == sourceManifest else {
                throw ContentDraftPersistenceError.migrationVerificationFailed
            }
            guard try await destination.backendGenerationIDAsync() == generationID else {
                throw ContentDraftPersistenceError.destinationMarkerMismatch
            }
            let finalSourceManifest = try await source.migrationManifest()
            guard finalSourceManifest == sourceManifest else {
                throw ContentDraftPersistenceError.sourceChangedDuringMigration
            }
            try Task.checkCancellation()
            let completedState = ContentDraftPersistenceState.migrated(
                sourceFingerprint: sourceManifest.fingerprint(),
                generationID: generationID,
                completedAt: now()
            )
            _ = try completedState.validated()
            try stateFile.replace(completedState) {
                try Task.checkCancellation()
                try beforeStateCommit()
            }

            // The state file is the backend-selection commit point. Do not add
            // any throwing work between this assignment and method return.
            active = destination
        } catch is CancellationError {
            active = source
        } catch {
            PersistenceDiagnostics.report(error, operation: "migrate content drafts to SwiftData")
            active = source
        }
        await ContentDraftMigrationCoordinator.shared.release(coordinationKey)
    }
}
