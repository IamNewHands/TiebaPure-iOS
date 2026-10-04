import Foundation
import SwiftData

struct ContentDraft: Equatable, Sendable {
    var accountID: String
    var target: ContentSubmissionTarget
    var title: String
    var body: String
    var images: [ContentSubmissionImage]
    var updatedAt: Date
}

enum ContentDraftLoadOutcome: Equatable, Sendable {
    case loaded(ContentDraft?)
    case damaged(ContentDraftDamage)
    case unavailable
}

enum ContentDraftDamage: Equatable, Sendable {
    case targetMetadata
    case attachmentContainer
}

enum ContentDraftPolicy {
    static let maximumDraftsPerAccount = 100
    static let maximumDraftsGlobally = 200
    static let maximumAttachmentBytesPerDraft = 96 * 1_024 * 1_024
    static let maximumAttachmentBytesPerAccount = 256 * 1_024 * 1_024
    static let maximumAttachmentBytesGlobally = 512 * 1_024 * 1_024
}

private enum ContentDraftStoreError: Error {
    case persistenceUnavailable
    case invalidAccountID
    case damagedTarget
    case damagedAttachmentContainer
    case attachmentBudgetExceeded
}

enum ContentDraftImageBlobDecodeOutcome: Equatable, Sendable {
    case decoded([ContentSubmissionImage])
    case damagedContainer
    case cancelled
}

struct ContentDraftPruneCandidate: Sendable {
    let sourceIndex: Int
    let persistentID: String?
    let accountID: String
    let targetKey: String
    let updatedAt: Date
    let imagesByteCount: Int?
}

enum ContentDraftPruner {
    static func deletionIndices(for candidates: [ContentDraftPruneCandidate]) -> Set<Int> {
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            if lhs.accountID != rhs.accountID {
                return lhs.accountID < rhs.accountID
            }
            if lhs.targetKey != rhs.targetKey {
                return lhs.targetKey < rhs.targetKey
            }
            if let lhsID = lhs.persistentID, let rhsID = rhs.persistentID, lhsID != rhsID {
                return lhsID < rhsID
            }
            if lhs.persistentID != nil, rhs.persistentID == nil {
                return true
            }
            if lhs.persistentID == nil, rhs.persistentID != nil {
                return false
            }
            return lhs.sourceIndex < rhs.sourceIndex
        }

        var deletionIndices = Set<Int>()
        var retainedDraftsByAccount: [String: Int] = [:]
        var retainedBytesByAccount: [String: Int] = [:]
        var retainedGlobalDrafts = 0
        var retainedGlobalBytes = 0

        for candidate in ordered {
            let accountDrafts = retainedDraftsByAccount[candidate.accountID, default: 0]
            let accountBytes = retainedBytesByAccount[candidate.accountID, default: 0]
            let byteCount = candidate.imagesByteCount.flatMap { $0 >= 0 ? $0 : nil }

            let exceedsCount = accountDrafts >= ContentDraftPolicy.maximumDraftsPerAccount
                || retainedGlobalDrafts >= ContentDraftPolicy.maximumDraftsGlobally
            let exceedsByteBudget: Bool
            if let byteCount {
                exceedsByteBudget = byteCount > ContentDraftPolicy.maximumAttachmentBytesPerDraft
                    || fits(
                        additionalBytes: byteCount,
                        usedBytes: accountBytes,
                        limit: ContentDraftPolicy.maximumAttachmentBytesPerAccount
                    ) == false
                    || fits(
                        additionalBytes: byteCount,
                        usedBytes: retainedGlobalBytes,
                        limit: ContentDraftPolicy.maximumAttachmentBytesGlobally
                    ) == false
            } else {
                // Legacy rows remain count-limited but are not guessed into a
                // byte budget. Background repair resolves them before the next
                // exact byte-based prune.
                exceedsByteBudget = false
            }

            if exceedsCount || exceedsByteBudget {
                deletionIndices.insert(candidate.sourceIndex)
                continue
            }

            retainedDraftsByAccount[candidate.accountID] = accountDrafts + 1
            retainedGlobalDrafts += 1
            if let byteCount {
                retainedBytesByAccount[candidate.accountID] = accountBytes + byteCount
                retainedGlobalBytes += byteCount
            }
        }
        return deletionIndices
    }

    private static func fits(additionalBytes: Int, usedBytes: Int, limit: Int) -> Bool {
        additionalBytes <= limit && usedBytes <= limit - additionalBytes
    }
}

/// Encodes each attachment in an independently checksummed frame. Any damaged
/// frame blocks the draft so editing never silently discards an attachment.
enum ContentDraftImageBlobCodec {
    private static let magic = Data([0x54, 0x50, 0x44, 0x49]) // TPDI
    private static let version: UInt8 = 2
    private static let legacyJSONVersion: UInt8 = 1
    private static let headerSize = 8
    private static let frameHeaderSize = 8
    private static let maximumFrameBytes = 16 * 1_024 * 1_024
    private static let maximumUUIDBytes = 64
    private static let maximumMIMETypeBytes = 128

    static func encode(_ images: [ContentSubmissionImage]) throws -> Data {
        var blob = Data()
        blob.append(magic)
        blob.append(version)
        blob.append(contentsOf: [0, 0, 0])

        for image in images {
            try Task.checkCancellation()
            let payload = try encodeFrame(image)
            guard payload.count <= maximumFrameBytes,
                  payload.count <= Int(UInt32.max) else {
                throw ContentDraftStoreError.attachmentBudgetExceeded
            }
            append(UInt32(payload.count), to: &blob)
            append(checksum(payload), to: &blob)
            blob.append(payload)
        }
        return blob
    }

    static func decode(_ blob: Data) -> [ContentSubmissionImage] {
        guard case let .decoded(images) = decodeWithIntegrity(blob) else {
            return []
        }
        return images
    }

    static func decodeWithIntegrity(_ blob: Data) -> ContentDraftImageBlobDecodeOutcome {
        guard blob.count >= headerSize,
              blob.prefix(magic.count) == magic else {
            return .damagedContainer
        }

        let storedVersion = blob[magic.count]
        guard storedVersion == version || storedVersion == legacyJSONVersion else {
            return .damagedContainer
        }
        var images: [ContentSubmissionImage] = []
        var offset = headerSize
        while offset < blob.count {
            guard Task.isCancelled == false else { return .cancelled }
            guard images.count < ContentSubmissionPolicy.maximumImages else {
                return .damagedContainer
            }
            guard offset + frameHeaderSize <= blob.count else {
                return .damagedContainer
            }
            guard let lengthValue = readUInt32(blob, at: offset),
                  let expectedChecksum = readUInt32(blob, at: offset + 4) else {
                return .damagedContainer
            }
            offset += frameHeaderSize
            let length = Int(lengthValue)
            guard length <= maximumFrameBytes,
                  offset <= blob.count,
                  length <= blob.count - offset else {
                return .damagedContainer
            }

            let payload = Data(blob[offset..<(offset + length)])
            offset += length
            guard checksum(payload) == expectedChecksum,
                  let image = decodeFrame(payload, version: storedVersion),
                  image.data.isEmpty == false,
                  image.data.count <= ContentSubmissionPolicy.maximumImageBytes,
                  image.pixelWidth > 0,
                  image.pixelHeight > 0,
                  ContentSubmissionPolicy.allowedImageMIMETypes.contains(image.mimeType.lowercased()) else {
                return .damagedContainer
            }
            images.append(image)
        }
        return .decoded(images)
    }

    private static func encodeFrame(_ image: ContentSubmissionImage) throws -> Data {
        let uuid = Data(image.id.uuidString.utf8)
        let mimeType = Data(image.mimeType.lowercased().utf8)
        guard uuid.isEmpty == false,
              uuid.count <= maximumUUIDBytes,
              mimeType.isEmpty == false,
              mimeType.count <= maximumMIMETypeBytes,
              image.data.isEmpty == false,
              image.data.count <= ContentSubmissionPolicy.maximumImageBytes,
              image.pixelWidth > 0,
              image.pixelHeight > 0,
              image.pixelWidth <= Int(UInt32.max),
              image.pixelHeight <= Int(UInt32.max) else {
            throw ContentDraftStoreError.attachmentBudgetExceeded
        }

        var payload = Data()
        payload.reserveCapacity(1 + uuid.count + 4 + 4 + 2 + mimeType.count + image.data.count)
        payload.append(UInt8(uuid.count))
        payload.append(uuid)
        append(UInt32(image.pixelWidth), to: &payload)
        append(UInt32(image.pixelHeight), to: &payload)
        append(UInt16(mimeType.count), to: &payload)
        payload.append(mimeType)
        payload.append(image.data)
        return payload
    }

    private static func decodeFrame(
        _ payload: Data,
        version: UInt8
    ) -> ContentSubmissionImage? {
        if version == legacyJSONVersion {
            return try? JSONDecoder().decode(ContentSubmissionImage.self, from: payload)
        }

        var offset = 0
        guard let uuidLength = readUInt8(payload, at: &offset),
              uuidLength > 0,
              uuidLength <= maximumUUIDBytes,
              let uuidData = read(payload, count: uuidLength, at: &offset),
              let uuidString = String(data: uuidData, encoding: .utf8),
              let id = UUID(uuidString: uuidString),
              let width = readUInt32(payload, at: offset) else {
            return nil
        }
        offset += 4
        guard let height = readUInt32(payload, at: offset) else { return nil }
        offset += 4
        guard let mimeLength = readUInt16(payload, at: offset) else { return nil }
        offset += 2
        guard mimeLength > 0,
              mimeLength <= maximumMIMETypeBytes,
              let mimeData = read(payload, count: mimeLength, at: &offset),
              let mimeType = String(data: mimeData, encoding: .utf8),
              offset < payload.count else {
            return nil
        }
        let imageData = Data(payload[offset...])
        return ContentSubmissionImage(
            id: id,
            data: imageData,
            pixelWidth: Int(width),
            pixelHeight: Int(height),
            mimeType: mimeType
        )
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func readUInt8(_ data: Data, at offset: inout Int) -> Int? {
        guard offset < data.count else { return nil }
        defer { offset += 1 }
        return Int(data[offset])
    }

    private static func read(_ data: Data, count: Int, at offset: inout Int) -> Data? {
        guard count >= 0, offset >= 0, count <= data.count - offset else { return nil }
        defer { offset += count }
        return Data(data[offset..<(offset + count)])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return Int(UInt16(data[offset]) << 8 | UInt16(data[offset + 1]))
    }

    private static func checksum(_ data: Data) -> UInt32 {
        data.reduce(2_166_136_261) { value, byte in
            (value ^ UInt32(byte)) &* 16_777_619
        }
    }
}

@available(iOS 17.0, *)
private struct ContentDraftByteCountUpdate: Sendable {
    let persistentID: PersistentIdentifier
    let byteCount: Int
}

@available(iOS 17.0, *)
private struct ContentDraftBackgroundLoadResult: Sendable {
    let outcome: ContentDraftLoadOutcome
    let byteCountUpdate: ContentDraftByteCountUpdate?
}

/// External attachment data is faulted only inside this model actor. The main
/// context receives scalar byte-count updates and can enforce capacity without
/// touching every attachment blob.
@ModelActor
@available(iOS 17.0, *)
private actor ContentDraftDatabaseActor {
    func backendGenerationID() throws -> String? {
        try Task.checkCancellation()
        let markers = try modelContext.fetch(
            FetchDescriptor<ContentDraftBackendMarkerRecord>()
        )
        guard markers.isEmpty == false else { return nil }
        guard markers.count == 1,
              let marker = markers.first,
              marker.key == SwiftDataContentDraftPersistenceBackend.markerKey,
              marker.formatVersion == SwiftDataContentDraftPersistenceBackend.markerFormatVersion,
              UUID(uuidString: marker.generationID) != nil else {
            throw ContentDraftPersistenceError.destinationMarkerMismatch
        }
        return marker.generationID
    }

    func load(
        accountID: String,
        target: ContentSubmissionTarget
    ) throws -> ContentDraftBackgroundLoadResult {
        try Task.checkCancellation()
        let requestedAccountID = accountID
        let requestedTargetKey = target.draftKey
        let records = try modelContext.fetch(FetchDescriptor<ContentDraftRecord>(
            predicate: #Predicate { record in
                record.accountID == requestedAccountID
                    && record.targetKey == requestedTargetKey
            }
        ))
        guard let record = preferredRecord(in: records) else {
            return ContentDraftBackgroundLoadResult(outcome: .loaded(nil), byteCountUpdate: nil)
        }
        guard let storedTarget = try? JSONDecoder().decode(
            ContentSubmissionTarget.self,
            from: record.targetData
        ), storedTarget.draftKey == requestedTargetKey else {
            return ContentDraftBackgroundLoadResult(
                outcome: .damaged(.targetMetadata),
                byteCountUpdate: nil
            )
        }

        let imagesBlob = record.imagesBlob
        try Task.checkCancellation()
        let byteCountUpdate = record.imagesByteCount == imagesBlob.count
            ? nil
            : ContentDraftByteCountUpdate(
                persistentID: record.persistentModelID,
                byteCount: imagesBlob.count
            )
        let images: [ContentSubmissionImage]
        switch ContentDraftImageBlobCodec.decodeWithIntegrity(imagesBlob) {
        case let .decoded(decodedImages):
            images = decodedImages
        case .damagedContainer:
            return ContentDraftBackgroundLoadResult(
                outcome: .damaged(.attachmentContainer),
                byteCountUpdate: byteCountUpdate
            )
        case .cancelled:
            throw CancellationError()
        }

        return ContentDraftBackgroundLoadResult(
            outcome: .loaded(ContentDraft(
                accountID: accountID,
                target: storedTarget,
                title: record.title,
                body: record.body,
                images: images,
                updatedAt: record.updatedAt
            )),
            byteCountUpdate: byteCountUpdate
        )
    }

    func missingByteCountUpdates() throws -> [ContentDraftByteCountUpdate] {
        let records = try modelContext.fetch(FetchDescriptor<ContentDraftRecord>())
        var updates: [ContentDraftByteCountUpdate] = []
        updates.reserveCapacity(records.count)
        for record in records {
            if let byteCount = record.imagesByteCount, byteCount >= 0 {
                continue
            }
            try Task.checkCancellation()
            updates.append(ContentDraftByteCountUpdate(
                persistentID: record.persistentModelID,
                byteCount: record.imagesBlob.count
            ))
        }
        return updates
    }

    func migrationIdentities() throws -> [String] {
        try Task.checkCancellation()
        let records = try modelContext.fetch(FetchDescriptor<ContentDraftRecord>())
        var preferredByIdentity: [String: ContentDraftRecord] = [:]
        for record in records {
            try Task.checkCancellation()
            let identity = "\(record.accountID)\u{1f}\(record.targetKey)"
            if let existing = preferredByIdentity[identity] {
                if record.updatedAt > existing.updatedAt
                    || (record.updatedAt == existing.updatedAt
                        && existing.persistentModelID < record.persistentModelID) {
                    preferredByIdentity[identity] = record
                }
            } else {
                preferredByIdentity[identity] = record
            }
        }
        return preferredByIdentity.keys.sorted()
    }

    func migrationRecord(identity: String) throws -> ContentDraftPersistenceRecord {
        try Task.checkCancellation()
        guard let separator = identity.firstIndex(of: "\u{1f}") else {
            throw ContentDraftPersistenceError.missingMigrationRecord
        }
        let requestedAccountID = String(identity[..<separator])
        let requestedTargetKey = String(identity[identity.index(after: separator)...])
        let records = try modelContext.fetch(FetchDescriptor<ContentDraftRecord>(
            predicate: #Predicate { record in
                record.accountID == requestedAccountID
                    && record.targetKey == requestedTargetKey
            }
        ))
        guard let record = preferredRecord(in: records) else {
            throw ContentDraftPersistenceError.missingMigrationRecord
        }
        let imagesBlob = record.imagesBlob
        try Task.checkCancellation()
        return try ContentDraftPersistenceRecord(
            accountID: record.accountID,
            targetKey: record.targetKey,
            targetData: record.targetData,
            title: record.title,
            body: record.body,
            imagesBlob: imagesBlob,
            imagesByteCount: imagesBlob.count,
            updatedAt: record.updatedAt
        ).validated()
    }

    func beginMigration() throws {
        try Task.checkCancellation()
        do {
            for record in try modelContext.fetch(FetchDescriptor<ContentDraftRecord>()) {
                modelContext.delete(record)
            }
            try Task.checkCancellation()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func beginMigration(generationID: String) throws {
        guard UUID(uuidString: generationID) != nil else {
            throw ContentDraftPersistenceError.destinationMarkerMismatch
        }
        try Task.checkCancellation()
        do {
            for record in try modelContext.fetch(FetchDescriptor<ContentDraftRecord>()) {
                modelContext.delete(record)
            }
            for marker in try modelContext.fetch(
                FetchDescriptor<ContentDraftBackendMarkerRecord>()
            ) {
                modelContext.delete(marker)
            }
            modelContext.insert(ContentDraftBackendMarkerRecord(
                key: SwiftDataContentDraftPersistenceBackend.markerKey,
                formatVersion: SwiftDataContentDraftPersistenceBackend.markerFormatVersion,
                generationID: generationID
            ))
            try Task.checkCancellation()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func writeMigrationRecord(_ record: ContentDraftPersistenceRecord) throws {
        let record = try record.validated()
        try Task.checkCancellation()
        do {
            let requestedAccountID = record.accountID
            let requestedTargetKey = record.targetKey
            let matches = try modelContext.fetch(FetchDescriptor<ContentDraftRecord>(
                predicate: #Predicate { stored in
                    stored.accountID == requestedAccountID
                        && stored.targetKey == requestedTargetKey
                }
            ))
            for match in matches {
                modelContext.delete(match)
            }
            modelContext.insert(ContentDraftRecord(
                accountID: record.accountID,
                targetKey: record.targetKey,
                targetData: record.targetData,
                title: record.title,
                body: record.body,
                imagesBlob: record.imagesBlob,
                imagesByteCount: record.imagesByteCount,
                updatedAt: record.updatedAt
            ))
            try Task.checkCancellation()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func preferredRecord(in records: [ContentDraftRecord]) -> ContentDraftRecord? {
        records.max {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt < $1.updatedAt
            }
            return $0.persistentModelID < $1.persistentModelID
        }
    }
}

@MainActor
@available(iOS 17.0, *)
final class SwiftDataContentDraftPersistenceBackend: ContentDraftMigrationDestination {
    nonisolated static let markerKey = "content-draft-backend"
    nonisolated static let markerFormatVersion = 1

    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let databaseActorTask: Task<ContentDraftDatabaseActor, Never>
    private let persistentBackendIsAvailable: Bool
    private(set) var persistenceAvailability: PersistenceAvailability
    private var maintenanceTask: Task<Void, Never>?

    init(
        modelContainer: ModelContainer = AppModelContainer.shared,
        persistenceAvailability: PersistenceAvailability? = nil
    ) {
        self.modelContainer = modelContainer
        modelContext = modelContainer.mainContext
        databaseActorTask = Task.detached(priority: .utility) {
            ContentDraftDatabaseActor(modelContainer: modelContainer)
        }
        let availability = persistenceAvailability
            ?? AppModelContainer.persistenceAvailability(for: modelContainer)
        persistentBackendIsAvailable = availability.canPersist
        self.persistenceAvailability = availability
    }

    func backendGenerationID() throws -> String? {
        guard requirePersistence(operation: "read content draft backend marker") else {
            throw ContentDraftPersistenceError.unavailable
        }
        let markers = try modelContext.fetch(FetchDescriptor<ContentDraftBackendMarkerRecord>())
        guard markers.isEmpty == false else { return nil }
        guard markers.count == 1,
              let marker = markers.first,
              marker.key == Self.markerKey,
              marker.formatVersion == Self.markerFormatVersion,
              UUID(uuidString: marker.generationID) != nil else {
            throw ContentDraftPersistenceError.destinationMarkerMismatch
        }
        return marker.generationID
    }

    func backendGenerationIDAsync() async throws -> String? {
        guard requirePersistence(operation: "read content draft backend marker") else {
            throw ContentDraftPersistenceError.unavailable
        }
        try Task.checkCancellation()
        let actor = ContentDraftDatabaseActor(modelContainer: modelContainer)
        return try await actor.backendGenerationID()
    }

    func installNativeBackendMarker(generationID: String) throws {
        guard UUID(uuidString: generationID) != nil else {
            throw ContentDraftPersistenceError.destinationMarkerMismatch
        }
        if let existing = try backendGenerationID() {
            guard existing == generationID else {
                throw ContentDraftPersistenceError.destinationMarkerMismatch
            }
            return
        }
        do {
            modelContext.insert(ContentDraftBackendMarkerRecord(
                key: Self.markerKey,
                formatVersion: Self.markerFormatVersion,
                generationID: generationID
            ))
            try modelContext.save()
            guard try backendGenerationID() == generationID else {
                throw ContentDraftPersistenceError.destinationMarkerMismatch
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Adopts the committed state file's generation over a marker row left by
    /// an earlier database. Only the marker is rewritten, so this can never
    /// drop a draft.
    func replaceNativeBackendMarker(generationID: String) throws {
        guard UUID(uuidString: generationID) != nil else {
            throw ContentDraftPersistenceError.destinationMarkerMismatch
        }
        do {
            for marker in try modelContext.fetch(
                FetchDescriptor<ContentDraftBackendMarkerRecord>()
            ) {
                modelContext.delete(marker)
            }
            modelContext.insert(ContentDraftBackendMarkerRecord(
                key: Self.markerKey,
                formatVersion: Self.markerFormatVersion,
                generationID: generationID
            ))
            try modelContext.save()
            guard try backendGenerationID() == generationID else {
                throw ContentDraftPersistenceError.destinationMarkerMismatch
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Returns `true` when the store was read successfully. `draft` is `nil`
    /// for a successful miss, keeping that case distinct from a read failure.
    @discardableResult
    func load(
        accountID: String,
        target: ContentSubmissionTarget,
        into draft: inout ContentDraft?
    ) -> Bool {
        draft = nil
        guard requirePersistence(operation: "load content draft") else { return false }
        do {
            let normalizedAccountID = try normalizedAccountID(accountID)
            let matches = try matchingRecords(
                accountID: normalizedAccountID,
                targetKey: target.draftKey
            )
            guard let record = preferredRecord(in: matches) else {
                markPersistenceSucceeded()
                return true
            }
            guard let storedTarget = try? JSONDecoder().decode(
                ContentSubmissionTarget.self,
                from: record.targetData
            ), storedTarget.draftKey == target.draftKey else {
                throw ContentDraftStoreError.damagedTarget
            }
            let imagesBlob = record.imagesBlob
            let images: [ContentSubmissionImage]
            switch ContentDraftImageBlobCodec.decodeWithIntegrity(imagesBlob) {
            case let .decoded(decodedImages):
                images = decodedImages
            case .damagedContainer:
                throw ContentDraftStoreError.damagedAttachmentContainer
            case .cancelled:
                return false
            }
            record.imagesByteCount = imagesBlob.count
            draft = ContentDraft(
                accountID: normalizedAccountID,
                target: storedTarget,
                title: record.title,
                body: record.body,
                images: images,
                updatedAt: record.updatedAt
            )
            try modelContext.save()
            markPersistenceSucceeded()
            return true
        } catch ContentDraftStoreError.damagedTarget {
            PersistenceDiagnostics.report(
                ContentDraftStoreError.damagedTarget,
                operation: "load content draft"
            )
            markPersistenceSucceeded()
            return false
        } catch ContentDraftStoreError.damagedAttachmentContainer {
            PersistenceDiagnostics.report(
                ContentDraftStoreError.damagedAttachmentContainer,
                operation: "load content draft"
            )
            markPersistenceSucceeded()
            return false
        } catch {
            PersistenceDiagnostics.report(error, operation: "load content draft")
            persistenceAvailability = .unavailable
            return false
        }
    }

    func draft(accountID: String, target: ContentSubmissionTarget) -> ContentDraft? {
        var loaded: ContentDraft?
        guard load(accountID: accountID, target: target, into: &loaded) else { return nil }
        return loaded
    }

    func loadAsync(
        accountID: String,
        target: ContentSubmissionTarget
    ) async -> ContentDraftLoadOutcome {
        guard requirePersistence(operation: "load content draft") else { return .unavailable }
        do {
            let normalizedAccountID = try normalizedAccountID(accountID)
            let databaseActor = await databaseActorTask.value
            try Task.checkCancellation()
            let result = try await databaseActor.load(
                accountID: normalizedAccountID,
                target: target
            )
            guard Task.isCancelled == false else { return .unavailable }
            if let update = result.byteCountUpdate {
                try applyByteCountUpdates([update])
                try modelContext.save()
            }
            markPersistenceSucceeded()
            return result.outcome
        } catch is CancellationError {
            return .unavailable
        } catch {
            modelContext.rollback()
            PersistenceDiagnostics.report(error, operation: "load content draft")
            persistenceAvailability = .unavailable
            return .unavailable
        }
    }

    @discardableResult
    func save(_ draft: ContentDraft) -> Bool {
        guard requirePersistence(operation: "save content draft") else { return false }
        let normalizedID: String
        do {
            normalizedID = try normalizedAccountID(draft.accountID)
        } catch {
            return fail(ContentDraftStoreError.invalidAccountID, operation: "save content draft")
        }

        do {
            let imagesBlob = try ContentDraftImageBlobCodec.encode(draft.images)
            let needsMaintenance = try persist(
                draft,
                normalizedID: normalizedID,
                imagesBlob: imagesBlob
            )
            if needsMaintenance {
                scheduleMaintenance()
            }
            markPersistenceSucceeded()
            return true
        } catch {
            modelContext.rollback()
            return fail(error, operation: "save content draft")
        }
    }

    func saveAsync(_ draft: ContentDraft) async throws {
        guard requirePersistence(operation: "save content draft") else {
            throw ContentDraftStoreError.persistenceUnavailable
        }
        let normalizedID: String
        do {
            normalizedID = try normalizedAccountID(draft.accountID)
        } catch {
            _ = fail(ContentDraftStoreError.invalidAccountID, operation: "save content draft")
            throw ContentDraftStoreError.invalidAccountID
        }

        do {
            let images = draft.images
            let encodingTask = Task.detached(priority: .userInitiated) {
                try ContentDraftImageBlobCodec.encode(images)
            }
            let imagesBlob = try await withTaskCancellationHandler {
                try await encodingTask.value
            } onCancel: {
                encodingTask.cancel()
            }
            try Task.checkCancellation()
            if try hasUnknownByteCounts() {
                let didRepair = await repairLegacyMetadataAndPruneAsync()
                try Task.checkCancellation()
                guard didRepair else {
                    throw ContentDraftStoreError.persistenceUnavailable
                }
            }
            try Task.checkCancellation()
            let needsMaintenance = try persist(
                draft,
                normalizedID: normalizedID,
                imagesBlob: imagesBlob
            )
            if needsMaintenance {
                scheduleMaintenance()
            }
            markPersistenceSucceeded()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            modelContext.rollback()
            _ = fail(error, operation: "save content draft")
            throw error
        }
    }

    @discardableResult
    func save(
        accountID: String,
        target: ContentSubmissionTarget,
        title: String,
        body: String,
        images: [ContentSubmissionImage],
        updatedAt: Date = Date()
    ) -> Bool {
        save(ContentDraft(
            accountID: accountID,
            target: target,
            title: title,
            body: body,
            images: images,
            updatedAt: updatedAt
        ))
    }

    func saveAsync(
        accountID: String,
        target: ContentSubmissionTarget,
        title: String,
        body: String,
        images: [ContentSubmissionImage],
        updatedAt: Date = Date()
    ) async throws {
        try await saveAsync(ContentDraft(
            accountID: accountID,
            target: target,
            title: title,
            body: body,
            images: images,
            updatedAt: updatedAt
        ))
    }

    @discardableResult
    func delete(accountID: String, target: ContentSubmissionTarget) -> Bool {
        guard requirePersistence(operation: "delete content draft") else { return false }
        do {
            let normalizedAccountID = try normalizedAccountID(accountID)
            for record in try matchingRecords(
                accountID: normalizedAccountID,
                targetKey: target.draftKey
            ) {
                modelContext.delete(record)
            }
            try modelContext.save()
            markPersistenceSucceeded()
            return true
        } catch {
            modelContext.rollback()
            return fail(error, operation: "delete content draft")
        }
    }

    @discardableResult
    func clear(accountID: String) -> Bool {
        guard requirePersistence(operation: "clear content drafts") else { return false }
        do {
            let normalizedAccountID = try normalizedAccountID(accountID)
            let requestedAccountID = normalizedAccountID
            let records = try modelContext.fetch(FetchDescriptor<ContentDraftRecord>(
                predicate: #Predicate { record in
                    record.accountID == requestedAccountID
                }
            ))
            for record in records {
                modelContext.delete(record)
            }
            try modelContext.save()
            markPersistenceSucceeded()
            return true
        } catch {
            modelContext.rollback()
            return fail(error, operation: "clear content drafts")
        }
    }

    private func matchingRecords(accountID: String, targetKey: String) throws -> [ContentDraftRecord] {
        let requestedAccountID = accountID
        let requestedTargetKey = targetKey
        return try modelContext.fetch(FetchDescriptor<ContentDraftRecord>(
            predicate: #Predicate { record in
                record.accountID == requestedAccountID
                    && record.targetKey == requestedTargetKey
            }
        ))
    }

    private func persist(
        _ draft: ContentDraft,
        normalizedID: String,
        imagesBlob: Data
    ) throws -> Bool {
        guard imagesBlob.count <= ContentDraftPolicy.maximumAttachmentBytesPerDraft else {
            throw ContentDraftStoreError.attachmentBudgetExceeded
        }
        let targetData = try JSONEncoder().encode(draft.target)
        let matches = try matchingRecords(
            accountID: normalizedID,
            targetKey: draft.target.draftKey
        )
        if let record = preferredRecord(in: matches) {
            record.targetData = targetData
            record.title = draft.title
            record.body = draft.body
            record.imagesBlob = imagesBlob
            record.imagesByteCount = imagesBlob.count
            record.updatedAt = draft.updatedAt
            for duplicate in matches where duplicate !== record {
                modelContext.delete(duplicate)
            }
        } else {
            modelContext.insert(ContentDraftRecord(
                accountID: normalizedID,
                targetKey: draft.target.draftKey,
                targetData: targetData,
                title: draft.title,
                body: draft.body,
                imagesBlob: imagesBlob,
                imagesByteCount: imagesBlob.count,
                updatedAt: draft.updatedAt
            ))
        }
        let needsMaintenance = try pruneUsingByteCountMetadata()
        try modelContext.save()
        return needsMaintenance
    }

    private func normalizedAccountID(_ accountID: String) throws -> String {
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            throw ContentDraftStoreError.invalidAccountID
        }
        return normalized
    }

    private func preferredRecord(in records: [ContentDraftRecord]) -> ContentDraftRecord? {
        records.max {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt < $1.updatedAt
            }
            return $0.persistentModelID < $1.persistentModelID
        }
    }

    @discardableResult
    func repairLegacyMetadataAndPruneAsync() async -> Bool {
        guard requirePersistence(operation: "repair content draft metadata") else { return false }
        do {
            let databaseActor = await databaseActorTask.value
            guard Task.isCancelled == false else { return false }
            let updates = try await databaseActor.missingByteCountUpdates()
            guard Task.isCancelled == false else { return false }
            try applyByteCountUpdates(updates)
            _ = try pruneUsingByteCountMetadata()
            try modelContext.save()
            markPersistenceSucceeded()
            return true
        } catch is CancellationError {
            return false
        } catch {
            modelContext.rollback()
            return fail(error, operation: "repair content draft metadata")
        }
    }

    func migrationManifest() async throws -> ContentDraftMigrationManifest {
        guard requirePersistence(operation: "export content draft migration manifest") else {
            throw ContentDraftPersistenceError.unavailable
        }
        do {
            try Task.checkCancellation()
            let identityActor = ContentDraftDatabaseActor(modelContainer: modelContainer)
            let identities = try await identityActor.migrationIdentities()
            var entries: [ContentDraftMigrationManifestEntry] = []
            entries.reserveCapacity(identities.count)
            for identity in identities {
                try Task.checkCancellation()
                let recordActor = ContentDraftDatabaseActor(modelContainer: modelContainer)
                let record = try await recordActor.migrationRecord(identity: identity)
                entries.append(try ContentDraftMigrationManifestEntry(record: record))
            }
            let manifest = try ContentDraftMigrationManifest(entries: entries)
            markPersistenceSucceeded()
            return manifest
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = fail(error, operation: "export content draft migration manifest")
            throw error
        }
    }

    func migrationRecord(identity: String) async throws -> ContentDraftPersistenceRecord {
        guard requirePersistence(operation: "read content draft migration record") else {
            throw ContentDraftPersistenceError.unavailable
        }
        do {
            try Task.checkCancellation()
            let actor = ContentDraftDatabaseActor(modelContainer: modelContainer)
            let record = try await actor.migrationRecord(identity: identity)
            markPersistenceSucceeded()
            return record
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = fail(error, operation: "read content draft migration record")
            throw error
        }
    }

    func beginMigration(to manifest: ContentDraftMigrationManifest) async throws {
        guard requirePersistence(operation: "begin content draft migration") else {
            throw ContentDraftPersistenceError.unavailable
        }
        do {
            _ = try ContentDraftMigrationManifest(entries: manifest.entries)
            try Task.checkCancellation()
            let actor = ContentDraftDatabaseActor(modelContainer: modelContainer)
            try await actor.beginMigration()
            markPersistenceSucceeded()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = fail(error, operation: "begin content draft migration")
            throw error
        }
    }

    func beginMigration(
        to manifest: ContentDraftMigrationManifest,
        generationID: String
    ) async throws {
        guard requirePersistence(operation: "begin marked content draft migration") else {
            throw ContentDraftPersistenceError.unavailable
        }
        do {
            _ = try ContentDraftMigrationManifest(entries: manifest.entries)
            guard UUID(uuidString: generationID) != nil else {
                throw ContentDraftPersistenceError.destinationMarkerMismatch
            }
            try Task.checkCancellation()
            let actor = ContentDraftDatabaseActor(modelContainer: modelContainer)
            try await actor.beginMigration(generationID: generationID)
            guard try await backendGenerationIDAsync() == generationID else {
                throw ContentDraftPersistenceError.destinationMarkerMismatch
            }
            markPersistenceSucceeded()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = fail(error, operation: "begin marked content draft migration")
            throw error
        }
    }

    func writeMigrationRecord(_ record: ContentDraftPersistenceRecord) async throws {
        guard requirePersistence(operation: "write content draft migration record") else {
            throw ContentDraftPersistenceError.unavailable
        }
        do {
            try Task.checkCancellation()
            let actor = ContentDraftDatabaseActor(modelContainer: modelContainer)
            try await actor.writeMigrationRecord(record)
            markPersistenceSucceeded()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = fail(error, operation: "write content draft migration record")
            throw error
        }
    }

    private func hasUnknownByteCounts() throws -> Bool {
        try modelContext.fetch(FetchDescriptor<ContentDraftRecord>()).contains { record in
            guard let byteCount = record.imagesByteCount else { return true }
            return byteCount < 0
        }
    }

    private func applyByteCountUpdates(_ updates: [ContentDraftByteCountUpdate]) throws {
        guard updates.isEmpty == false else { return }
        let byteCountsByID = Dictionary(uniqueKeysWithValues: updates.map {
            ($0.persistentID, $0.byteCount)
        })
        for record in try modelContext.fetch(FetchDescriptor<ContentDraftRecord>()) {
            if let byteCount = byteCountsByID[record.persistentModelID] {
                record.imagesByteCount = byteCount
            }
        }
    }

    /// Returns whether legacy records still need an off-main byte-count repair.
    private func pruneUsingByteCountMetadata() throws -> Bool {
        let records = try modelContext.fetch(FetchDescriptor<ContentDraftRecord>())
        let candidates = records.enumerated().map { index, record in
            ContentDraftPruneCandidate(
                sourceIndex: index,
                persistentID: String(describing: record.persistentModelID),
                accountID: record.accountID,
                targetKey: record.targetKey,
                updatedAt: record.updatedAt,
                imagesByteCount: record.imagesByteCount
            )
        }
        let deletionIndices = ContentDraftPruner.deletionIndices(for: candidates)
        for index in deletionIndices {
            modelContext.delete(records[index])
        }
        return records.contains { record in
            guard let byteCount = record.imagesByteCount else { return true }
            return byteCount < 0
        }
    }

    private func scheduleMaintenance() {
        guard maintenanceTask == nil else { return }
        maintenanceTask = Task { [weak self] in
            guard let self else { return }
            _ = await repairLegacyMetadataAndPruneAsync()
            maintenanceTask = nil
        }
    }

    private func requirePersistence(operation: String) -> Bool {
        guard persistentBackendIsAvailable else {
            return fail(ContentDraftStoreError.persistenceUnavailable, operation: operation)
        }
        return true
    }

    private func fail(_ error: Error, operation: String) -> Bool {
        PersistenceDiagnostics.report(error, operation: operation)
        persistenceAvailability = .unavailable
        return false
    }

    private func markPersistenceSucceeded() {
        guard persistentBackendIsAvailable else { return }
        persistenceAvailability = .available
    }
}

@MainActor
final class ContentDraftStore {
    private let persistence: any ContentDraftPersistenceBackend

    var persistenceAvailability: PersistenceAvailability {
        persistence.persistenceAvailability
    }

    init(persistence: any ContentDraftPersistenceBackend) {
        self.persistence = persistence
    }

    convenience init() {
        self.init(persistence: ContentDraftPersistenceFactory.makeApplicationBackend())
    }

    @available(iOS 17.0, *)
    convenience init(
        modelContainer: ModelContainer,
        persistenceAvailability: PersistenceAvailability? = nil
    ) {
        self.init(persistence: SwiftDataContentDraftPersistenceBackend(
            modelContainer: modelContainer,
            persistenceAvailability: persistenceAvailability
        ))
    }

    @discardableResult
    func load(
        accountID: String,
        target: ContentSubmissionTarget,
        into draft: inout ContentDraft?
    ) -> Bool {
        persistence.load(accountID: accountID, target: target, into: &draft)
    }

    func draft(accountID: String, target: ContentSubmissionTarget) -> ContentDraft? {
        persistence.draft(accountID: accountID, target: target)
    }

    func loadAsync(
        accountID: String,
        target: ContentSubmissionTarget
    ) async -> ContentDraftLoadOutcome {
        await persistence.loadAsync(accountID: accountID, target: target)
    }

    @discardableResult
    func save(_ draft: ContentDraft) -> Bool {
        persistence.save(draft)
    }

    func saveAsync(_ draft: ContentDraft) async throws {
        try await persistence.saveAsync(draft)
    }

    @discardableResult
    func save(
        accountID: String,
        target: ContentSubmissionTarget,
        title: String,
        body: String,
        images: [ContentSubmissionImage],
        updatedAt: Date = Date()
    ) -> Bool {
        save(ContentDraft(
            accountID: accountID,
            target: target,
            title: title,
            body: body,
            images: images,
            updatedAt: updatedAt
        ))
    }

    func saveAsync(
        accountID: String,
        target: ContentSubmissionTarget,
        title: String,
        body: String,
        images: [ContentSubmissionImage],
        updatedAt: Date = Date()
    ) async throws {
        try await saveAsync(ContentDraft(
            accountID: accountID,
            target: target,
            title: title,
            body: body,
            images: images,
            updatedAt: updatedAt
        ))
    }

    @discardableResult
    func delete(accountID: String, target: ContentSubmissionTarget) -> Bool {
        persistence.delete(accountID: accountID, target: target)
    }

    @discardableResult
    func clear(accountID: String) -> Bool {
        persistence.clear(accountID: accountID)
    }

    @discardableResult
    func repairLegacyMetadataAndPruneAsync() async -> Bool {
        await persistence.repairLegacyMetadataAndPruneAsync()
    }
}
