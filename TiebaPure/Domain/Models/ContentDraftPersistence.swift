import CryptoKit
import Foundation

struct ContentDraftPersistenceRecord: Equatable, Sendable {
    let accountID: String
    let targetKey: String
    let targetData: Data
    let title: String
    let body: String
    let imagesBlob: Data
    let imagesByteCount: Int
    let updatedAt: Date

    var identity: String {
        "\(accountID)\u{1f}\(targetKey)"
    }

    func validated() throws -> ContentDraftPersistenceRecord {
        let normalizedAccountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedAccountID.isEmpty == false,
              normalizedAccountID == accountID,
              accountID.contains("\u{1f}") == false,
              targetKey.isEmpty == false,
              targetKey.contains("\u{1f}") == false,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              imagesByteCount == imagesBlob.count,
              imagesByteCount <= ContentDraftPolicy.maximumAttachmentBytesPerDraft,
              let target = try? JSONDecoder().decode(
                ContentSubmissionTarget.self,
                from: targetData
              ),
              target.draftKey == targetKey else {
            throw ContentDraftPersistenceError.invalidRecord
        }
        switch ContentDraftImageBlobCodec.decodeWithIntegrity(imagesBlob) {
        case .decoded:
            return self
        case .cancelled:
            throw CancellationError()
        case .damagedContainer:
            throw ContentDraftPersistenceError.invalidRecord
        }
    }
}

struct ContentDraftMigrationManifestEntry: Codable, Equatable, Sendable {
    let identity: String
    let accountID: String
    let targetKey: String
    let updatedAt: Date
    let imagesByteCount: Int
    let metadataDigest: String
    let blobDigest: String

    init(
        identity: String,
        accountID: String,
        targetKey: String,
        updatedAt: Date,
        imagesByteCount: Int,
        metadataDigest: String,
        blobDigest: String
    ) {
        self.identity = identity
        self.accountID = accountID
        self.targetKey = targetKey
        self.updatedAt = updatedAt
        self.imagesByteCount = imagesByteCount
        self.metadataDigest = metadataDigest
        self.blobDigest = blobDigest
    }

    init(record: ContentDraftPersistenceRecord) throws {
        let record = try record.validated()
        identity = record.identity
        accountID = record.accountID
        targetKey = record.targetKey
        updatedAt = record.updatedAt
        imagesByteCount = record.imagesByteCount
        metadataDigest = Self.metadataDigest(record)
        blobDigest = SecurePersistenceDigest.sha256(record.imagesBlob)
    }

    static func metadataDigest(_ record: ContentDraftPersistenceRecord) -> String {
        metadataDigest(
            accountID: record.accountID,
            targetKey: record.targetKey,
            targetData: record.targetData,
            title: record.title,
            body: record.body,
            updatedAt: record.updatedAt
        )
    }

    static func metadataDigest(
        accountID: String,
        targetKey: String,
        targetData: Data,
        title: String,
        body: String,
        updatedAt: Date
    ) -> String {
        var hasher = SHA256()
        ContentDraftMigrationManifest.update(&hasher, with: Data(accountID.utf8))
        ContentDraftMigrationManifest.update(&hasher, with: Data(targetKey.utf8))
        ContentDraftMigrationManifest.update(&hasher, with: targetData)
        ContentDraftMigrationManifest.update(&hasher, with: Data(title.utf8))
        ContentDraftMigrationManifest.update(&hasher, with: Data(body.utf8))
        ContentDraftMigrationManifest.update(
            &hasher,
            with: updatedAt.timeIntervalSinceReferenceDate.bitPattern
        )
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct ContentDraftMigrationManifest: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let entries: [ContentDraftMigrationManifestEntry]

    init(entries: [ContentDraftMigrationManifestEntry]) throws {
        var identities = Set<String>()
        var candidates: [ContentDraftPruneCandidate] = []
        candidates.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            let normalizedAccountID = entry.accountID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard normalizedAccountID.isEmpty == false,
                  normalizedAccountID == entry.accountID,
                  entry.accountID.contains("\u{1f}") == false,
                  entry.targetKey.isEmpty == false,
                  entry.targetKey.contains("\u{1f}") == false,
                  entry.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  entry.identity == "\(entry.accountID)\u{1f}\(entry.targetKey)",
                  identities.insert(entry.identity).inserted,
                  entry.imagesByteCount >= 0,
                  entry.imagesByteCount <= ContentDraftPolicy.maximumAttachmentBytesPerDraft,
                  Self.isSHA256Hex(entry.metadataDigest),
                  Self.isSHA256Hex(entry.blobDigest) else {
                throw ContentDraftPersistenceError.invalidManifest
            }
            candidates.append(ContentDraftPruneCandidate(
                sourceIndex: index,
                persistentID: entry.identity,
                accountID: entry.accountID,
                targetKey: entry.targetKey,
                updatedAt: entry.updatedAt,
                imagesByteCount: entry.imagesByteCount
            ))
        }
        guard ContentDraftPruner.deletionIndices(for: candidates).isEmpty else {
            throw ContentDraftPersistenceError.invalidManifest
        }
        formatVersion = Self.currentFormatVersion
        self.entries = entries.sorted { $0.identity < $1.identity }
    }

    func fingerprint() -> String {
        var hasher = SHA256()
        Self.update(&hasher, with: UInt64(formatVersion))
        Self.update(&hasher, with: UInt64(entries.count))
        for entry in entries {
            Self.update(&hasher, with: Data(entry.identity.utf8))
            Self.update(&hasher, with: Data(entry.metadataDigest.utf8))
            Self.update(&hasher, with: Data(entry.blobDigest.utf8))
            Self.update(&hasher, with: UInt64(entry.imagesByteCount))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func update(_ hasher: inout SHA256, with data: Data) {
        update(&hasher, with: UInt64(data.count))
        hasher.update(data: data)
    }

    static func update(_ hasher: inout SHA256, with value: UInt64) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { hasher.update(bufferPointer: $0) }
    }

    private static func isSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

enum ContentDraftPersistenceError: Error, Equatable {
    case unavailable
    case invalidRecord
    case invalidManifest
    case missingMigrationRecord
    case migrationVerificationFailed
    case sourceChangedDuringMigration
    case destinationMarkerMismatch
}

@MainActor
protocol ContentDraftPersistenceBackend: AnyObject {
    var persistenceAvailability: PersistenceAvailability { get }

    func load(
        accountID: String,
        target: ContentSubmissionTarget,
        into draft: inout ContentDraft?
    ) -> Bool
    func loadAsync(
        accountID: String,
        target: ContentSubmissionTarget
    ) async -> ContentDraftLoadOutcome
    func save(_ draft: ContentDraft) -> Bool
    func saveAsync(_ draft: ContentDraft) async throws
    func delete(accountID: String, target: ContentSubmissionTarget) -> Bool
    func clear(accountID: String) -> Bool
    func repairLegacyMetadataAndPruneAsync() async -> Bool

    /// Migration is intentionally manifest + one-record-at-a-time. No call may
    /// aggregate attachment blobs across drafts in memory.
    func migrationManifest() async throws -> ContentDraftMigrationManifest
    func migrationRecord(identity: String) async throws -> ContentDraftPersistenceRecord
    func beginMigration(to manifest: ContentDraftMigrationManifest) async throws
    func writeMigrationRecord(_ record: ContentDraftPersistenceRecord) async throws
}

@MainActor
protocol ContentDraftMigrationDestination: ContentDraftPersistenceBackend {
    func backendGenerationID() throws -> String?
    func backendGenerationIDAsync() async throws -> String?
    func installNativeBackendMarker(generationID: String) throws
    /// Rewrites the store's backend marker to the committed generation,
    /// replacing a marker left behind by an earlier database. Draft rows are
    /// never touched: the generation only identifies the backend, so adopting
    /// the state file's value cannot lose a record.
    func replaceNativeBackendMarker(generationID: String) throws
    func beginMigration(
        to manifest: ContentDraftMigrationManifest,
        generationID: String
    ) async throws
}

extension ContentDraftPersistenceBackend {
    func draft(accountID: String, target: ContentSubmissionTarget) -> ContentDraft? {
        var loaded: ContentDraft?
        guard load(accountID: accountID, target: target, into: &loaded) else { return nil }
        return loaded
    }
}

@MainActor
final class UnavailableContentDraftPersistenceBackend: ContentDraftPersistenceBackend {
    let persistenceAvailability: PersistenceAvailability = .unavailable

    func load(
        accountID: String,
        target: ContentSubmissionTarget,
        into draft: inout ContentDraft?
    ) -> Bool {
        draft = nil
        return false
    }

    func loadAsync(
        accountID: String,
        target: ContentSubmissionTarget
    ) async -> ContentDraftLoadOutcome {
        .unavailable
    }

    func save(_ draft: ContentDraft) -> Bool { false }

    func saveAsync(_ draft: ContentDraft) async throws {
        throw ContentDraftPersistenceError.unavailable
    }

    func delete(accountID: String, target: ContentSubmissionTarget) -> Bool { false }
    func clear(accountID: String) -> Bool { false }
    func repairLegacyMetadataAndPruneAsync() async -> Bool { false }

    func migrationManifest() async throws -> ContentDraftMigrationManifest {
        throw ContentDraftPersistenceError.unavailable
    }

    func migrationRecord(identity: String) async throws -> ContentDraftPersistenceRecord {
        throw ContentDraftPersistenceError.unavailable
    }

    func beginMigration(to manifest: ContentDraftMigrationManifest) async throws {
        throw ContentDraftPersistenceError.unavailable
    }

    func writeMigrationRecord(_ record: ContentDraftPersistenceRecord) async throws {
        throw ContentDraftPersistenceError.unavailable
    }
}
