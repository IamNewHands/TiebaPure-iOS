import Foundation

enum OrderedCollectionPersistenceBackend: String, Codable, Sendable {
    case secureFiles
    case swiftData
}

enum OrderedCollectionMigrationState: String, Codable, Sendable {
    case notRequired
    case swiftDataActivationPending
    case fileToSwiftDataEligible
    case fileToSwiftDataCompleted
}

struct OrderedCollectionMigrationReceipt: Codable, Equatable, Sendable {
    let migrationVersion: Int
    let sourceBackend: OrderedCollectionPersistenceBackend
    let destinationBackend: OrderedCollectionPersistenceBackend
    let sourceFingerprint: String
    let completedAt: Date
}

struct OrderedCollectionPersistenceManifest: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1
    static let currentMigrationVersion = 1

    let formatVersion: Int
    let activeBackend: OrderedCollectionPersistenceBackend
    let migrationState: OrderedCollectionMigrationState
    let migrationReceipt: OrderedCollectionMigrationReceipt?
    let destinationGeneration: String?

    static func initialFileBackend() -> OrderedCollectionPersistenceManifest {
        OrderedCollectionPersistenceManifest(
            formatVersion: currentFormatVersion,
            activeBackend: .secureFiles,
            migrationState: .fileToSwiftDataEligible,
            migrationReceipt: nil,
            destinationGeneration: nil
        )
    }

    static func pendingSwiftDataActivation(
        destinationGeneration: String
    ) -> OrderedCollectionPersistenceManifest {
        OrderedCollectionPersistenceManifest(
            formatVersion: currentFormatVersion,
            activeBackend: .swiftData,
            migrationState: .swiftDataActivationPending,
            migrationReceipt: nil,
            destinationGeneration: destinationGeneration
        )
    }

    static func initialSwiftDataBackend(
        destinationGeneration: String
    ) -> OrderedCollectionPersistenceManifest {
        OrderedCollectionPersistenceManifest(
            formatVersion: currentFormatVersion,
            activeBackend: .swiftData,
            migrationState: .notRequired,
            migrationReceipt: nil,
            destinationGeneration: destinationGeneration
        )
    }
}

@MainActor
protocol OrderedCollectionBackendMarkerPersistence: AnyObject {
    var capability: PersistenceCapability { get }

    func loadGeneration() throws -> String?
    func replaceGeneration(_ generation: String) throws
}

struct OrderedCollectionPersistenceSnapshot: Codable, Equatable, Sendable {
    let browsingHistory: [BrowsingHistoryEntry]
    let recentForums: [RecentForum]
    let searchHistory: [String]

    var isEmpty: Bool {
        browsingHistory.isEmpty && recentForums.isEmpty && searchHistory.isEmpty
    }

    func fingerprint() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SecurePersistenceDigest.sha256(try encoder.encode(self))
    }
}

@MainActor
struct OrderedCollectionPersistenceBundle {
    let browsingHistory: any BrowsingHistoryPersistence
    let recentForums: any RecentForumPersistence
    let searchHistory: any SearchHistoryPersistence
    let backendMarker: (any OrderedCollectionBackendMarkerPersistence)?

    init(
        browsingHistory: any BrowsingHistoryPersistence,
        recentForums: any RecentForumPersistence,
        searchHistory: any SearchHistoryPersistence,
        backendMarker: (any OrderedCollectionBackendMarkerPersistence)? = nil
    ) {
        self.browsingHistory = browsingHistory
        self.recentForums = recentForums
        self.searchHistory = searchHistory
        self.backendMarker = backendMarker
    }

    var isDurable: Bool {
        browsingHistory.capability.isDurable
            && recentForums.capability.isDurable
            && searchHistory.capability.isDurable
    }

    func snapshot() throws -> OrderedCollectionPersistenceSnapshot {
        OrderedCollectionPersistenceSnapshot(
            browsingHistory: try browsingHistory.load(),
            recentForums: try recentForums.load(),
            searchHistory: try searchHistory.load()
        )
    }

    func replaceAll(with snapshot: OrderedCollectionPersistenceSnapshot) throws {
        // The receipt remains on the source backend until all three writes and
        // the subsequent read-back verification succeed. A crash between these
        // idempotent writes therefore retries from the file snapshot.
        try browsingHistory.replaceAll(snapshot.browsingHistory)
        try recentForums.replaceAll(snapshot.recentForums)
        try searchHistory.replaceAll(snapshot.searchHistory)
    }
}

enum OrderedCollectionPersistenceFactoryError: Error, Equatable {
    case backendUnavailable
    case unsupportedManifestVersion(Int)
    case inconsistentManifest
    case swiftDataUnavailable
    case destinationIsNotDurable
    case migrationVerificationFailed
    case ambiguousBackendRecovery
    case destinationMarkerUnavailable
    case destinationMarkerMismatch
    case sourceChangedDuringMigration
}

@MainActor
struct OrderedCollectionPersistenceFactory {
    typealias SwiftDataBuilder = @MainActor () throws -> OrderedCollectionPersistenceBundle

    private let directoryURL: URL
    private let fileManager: FileManager
    private let supportsSwiftData: Bool
    private let now: () -> Date
    private let makeSwiftDataBundle: SwiftDataBuilder

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        supportsSwiftData: Bool,
        now: @escaping () -> Date = Date.init,
        makeSwiftDataBundle: @escaping SwiftDataBuilder
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.supportsSwiftData = supportsSwiftData
        self.now = now
        self.makeSwiftDataBundle = makeSwiftDataBundle
    }

    func make() -> OrderedCollectionPersistenceBundle {
        do {
            let manifestFile = try SecureCodableFile<OrderedCollectionPersistenceManifest>(
                directoryURL: directoryURL,
                fileName: "ordered-collections-manifest.json",
                fileManager: fileManager,
                maximumByteCount: 64 * 1_024
            )
            if let manifest = try manifestFile.load() {
                try Self.validate(manifest)
                return try resolve(manifest: manifest, manifestFile: manifestFile)
            }
            if hasFileBackendArtifacts {
                throw OrderedCollectionPersistenceFactoryError.ambiguousBackendRecovery
            }
            return try makeInitialBundle(manifestFile: manifestFile)
        } catch {
            PersistenceDiagnostics.report(
                error,
                operation: "resolve ordered collection persistence backend"
            )
            return Self.unavailableBundle()
        }
    }

    static func makeApplicationBundle(
        fileManager: FileManager = .default
    ) -> OrderedCollectionPersistenceBundle {
        do {
            let location = try SecurePersistenceLocation.applicationSupport(fileManager: fileManager)
            if #available(iOS 17.0, *) {
                return OrderedCollectionPersistenceFactory(
                    directoryURL: location.directoryURL,
                    fileManager: fileManager,
                    supportsSwiftData: true
                ) {
                    OrderedCollectionPersistenceBundle(
                        browsingHistory: SwiftDataBrowsingHistoryPersistence(
                            modelContainer: AppModelContainer.shared
                        ),
                        recentForums: SwiftDataRecentForumPersistence(
                            modelContainer: AppModelContainer.shared
                        ),
                        searchHistory: SwiftDataSearchHistoryPersistence(
                            modelContainer: AppModelContainer.shared
                        ),
                        backendMarker: SwiftDataOrderedCollectionBackendMarkerPersistence(
                            modelContainer: AppModelContainer.shared
                        )
                    )
                }.make()
            }
            return OrderedCollectionPersistenceFactory(
                directoryURL: location.directoryURL,
                fileManager: fileManager,
                supportsSwiftData: false
            ) {
                throw OrderedCollectionPersistenceFactoryError.swiftDataUnavailable
            }.make()
        } catch {
            PersistenceDiagnostics.report(
                error,
                operation: "open ordered collection persistence directory"
            )
            return unavailableBundle()
        }
    }

    private func makeInitialBundle(
        manifestFile: SecureCodableFile<OrderedCollectionPersistenceManifest>
    ) throws -> OrderedCollectionPersistenceBundle {
        if supportsSwiftData {
            let bundle = try makeSwiftDataBundle()
            guard bundle.isDurable else {
                // Do not turn a transient in-memory SwiftData fallback into a
                // permanent backend choice. Legacy data remains available for
                // this session and backend selection retries on the next launch.
                return bundle
            }
            let marker = try Self.requireDurableMarker(from: bundle)
            // A marker without a manifest is a lost activation commit. The
            // database is still the only copy of the local records, so re-elect
            // the backend token over the leftover one instead of leaving
            // browsing history, recent forums and search history unavailable
            // for the rest of the install; no entry is touched.
            if let leftoverGeneration = try marker.loadGeneration() {
                PersistenceDiagnostics.note(
                    "浏览历史后端：只找到数据库标记（\(leftoverGeneration)）而没有清单文件，已重新选举后端标记（未删除任何记录）"
                )
            }
            let generation = UUID().uuidString
            try manifestFile.replace(.pendingSwiftDataActivation(
                destinationGeneration: generation
            ))
            return try completePendingSwiftDataActivation(
                bundle: bundle,
                marker: marker,
                generation: generation,
                manifestFile: manifestFile
            )
        }

        let bundle = try makeFileBundle()
        try manifestFile.replace(.initialFileBackend())
        return bundle.erased
    }

    private func resolve(
        manifest: OrderedCollectionPersistenceManifest,
        manifestFile: SecureCodableFile<OrderedCollectionPersistenceManifest>
    ) throws -> OrderedCollectionPersistenceBundle {
        if manifest.migrationState == .swiftDataActivationPending {
            guard supportsSwiftData else {
                throw OrderedCollectionPersistenceFactoryError.swiftDataUnavailable
            }
            let bundle = try makeSwiftDataBundle()
            guard bundle.isDurable else {
                throw OrderedCollectionPersistenceFactoryError.destinationIsNotDurable
            }
            let marker = try Self.requireDurableMarker(from: bundle)
            guard let generation = manifest.destinationGeneration else {
                throw OrderedCollectionPersistenceFactoryError.inconsistentManifest
            }
            return try completePendingSwiftDataActivation(
                bundle: bundle,
                marker: marker,
                generation: generation,
                manifestFile: manifestFile
            )
        }

        switch manifest.activeBackend {
        case .swiftData:
            guard supportsSwiftData else {
                throw OrderedCollectionPersistenceFactoryError.swiftDataUnavailable
            }
            let bundle = try makeSwiftDataBundle()
            guard bundle.isDurable else {
                throw OrderedCollectionPersistenceFactoryError.destinationIsNotDurable
            }
            let marker = try Self.requireDurableMarker(from: bundle)
            guard let expectedGeneration = manifest.destinationGeneration else {
                throw OrderedCollectionPersistenceFactoryError.inconsistentManifest
            }
            try Self.adoptCommittedGeneration(
                expectedGeneration,
                marker: marker,
                context: "浏览历史后端",
                missingMarkerIsRepair: true
            )
            return bundle

        case .secureFiles:
            let fileBundle = try makeFileBundle()
            guard supportsSwiftData,
                  manifest.migrationState == .fileToSwiftDataEligible else {
                return fileBundle.erased
            }
            do {
                return try migrateToSwiftData(
                    source: fileBundle.erased,
                    manifestFile: manifestFile
                )
            } catch {
                PersistenceDiagnostics.report(
                    error,
                    operation: "migrate ordered collections from files to SwiftData"
                )
                return fileBundle.erased
            }
        }
    }

    private func migrateToSwiftData(
        source: OrderedCollectionPersistenceBundle,
        manifestFile: SecureCodableFile<OrderedCollectionPersistenceManifest>
    ) throws -> OrderedCollectionPersistenceBundle {
        let snapshot = try source.snapshot()
        let destination = try makeSwiftDataBundle()
        guard destination.isDurable else {
            throw OrderedCollectionPersistenceFactoryError.destinationIsNotDurable
        }
        let marker = try Self.requireDurableMarker(from: destination)

        try destination.replaceAll(with: snapshot)
        guard try destination.snapshot() == snapshot else {
            throw OrderedCollectionPersistenceFactoryError.migrationVerificationFailed
        }
        let generation = UUID().uuidString
        try marker.replaceGeneration(generation)
        guard try marker.loadGeneration() == generation else {
            throw OrderedCollectionPersistenceFactoryError.destinationMarkerMismatch
        }
        guard try source.snapshot() == snapshot else {
            throw OrderedCollectionPersistenceFactoryError.sourceChangedDuringMigration
        }

        try commitMigrationReceipt(
            sourceSnapshot: snapshot,
            destinationGeneration: generation,
            manifestFile: manifestFile
        )
        return destination
    }

    private func completePendingSwiftDataActivation(
        bundle: OrderedCollectionPersistenceBundle,
        marker: any OrderedCollectionBackendMarkerPersistence,
        generation: String,
        manifestFile: SecureCodableFile<OrderedCollectionPersistenceManifest>
    ) throws -> OrderedCollectionPersistenceBundle {
        try Self.adoptCommittedGeneration(
            generation,
            marker: marker,
            context: "浏览历史后端",
            missingMarkerIsRepair: false
        )
        guard try marker.loadGeneration() == generation else {
            throw OrderedCollectionPersistenceFactoryError.destinationMarkerMismatch
        }
        try manifestFile.replace(.initialSwiftDataBackend(
            destinationGeneration: generation
        ))
        return bundle
    }

    /// Makes the store's own marker agree with the committed manifest.
    ///
    /// The manifest is the backend-selection commit point and the marker is
    /// only the store's copy of the same token. A store whose marker is missing
    /// or belongs to an earlier database used to leave browsing history, recent
    /// forums and search history empty for the rest of the install, with no
    /// recovery and no record of why. Rewriting the marker never touches an
    /// entry.
    private static func adoptCommittedGeneration(
        _ generation: String,
        marker: any OrderedCollectionBackendMarkerPersistence,
        context: String,
        missingMarkerIsRepair: Bool
    ) throws {
        guard let existingGeneration = try marker.loadGeneration() else {
            try marker.replaceGeneration(generation)
            if missingMarkerIsRepair {
                PersistenceDiagnostics.note(
                    "\(context)：数据库缺少后端标记，已按已提交状态重建（未删除任何记录）"
                )
            }
            return
        }
        guard existingGeneration != generation else { return }
        try marker.replaceGeneration(generation)
        PersistenceDiagnostics.note(
            "\(context)：数据库标记与已提交状态不一致（库内 \(existingGeneration)，状态 \(generation)），已按状态覆盖（未删除任何记录）"
        )
    }

    private func commitMigrationReceipt(
        sourceSnapshot: OrderedCollectionPersistenceSnapshot,
        destinationGeneration: String,
        manifestFile: SecureCodableFile<OrderedCollectionPersistenceManifest>
    ) throws {
        let receipt = OrderedCollectionMigrationReceipt(
            migrationVersion: OrderedCollectionPersistenceManifest.currentMigrationVersion,
            sourceBackend: .secureFiles,
            destinationBackend: .swiftData,
            sourceFingerprint: try sourceSnapshot.fingerprint(),
            completedAt: now()
        )
        try manifestFile.replace(OrderedCollectionPersistenceManifest(
            formatVersion: OrderedCollectionPersistenceManifest.currentFormatVersion,
            activeBackend: .swiftData,
            migrationState: .fileToSwiftDataCompleted,
            migrationReceipt: receipt,
            destinationGeneration: destinationGeneration
        ))
    }

    private static func requireDurableMarker(
        from bundle: OrderedCollectionPersistenceBundle
    ) throws -> any OrderedCollectionBackendMarkerPersistence {
        guard let marker = bundle.backendMarker,
              marker.capability.isDurable else {
            throw OrderedCollectionPersistenceFactoryError.destinationMarkerUnavailable
        }
        return marker
    }

    private func makeFileBundle() throws -> FileOrderedCollectionPersistenceBundle {
        try FileOrderedCollectionPersistenceBundle(
            directoryURL: directoryURL,
            fileManager: fileManager
        )
    }

    private var hasFileBackendArtifacts: Bool {
        [
            "browsing-history.json",
            "recent-forums.json",
            "search-history.json"
        ].contains { fileName in
            let primary = directoryURL.appendingPathComponent(fileName, isDirectory: false)
            let backup = directoryURL.appendingPathComponent(
                "\(fileName).backup",
                isDirectory: false
            )
            return fileManager.fileExists(atPath: primary.path)
                || fileManager.fileExists(atPath: backup.path)
        }
    }

    private static func validate(
        _ manifest: OrderedCollectionPersistenceManifest
    ) throws {
        guard manifest.formatVersion == OrderedCollectionPersistenceManifest.currentFormatVersion else {
            throw OrderedCollectionPersistenceFactoryError.unsupportedManifestVersion(
                manifest.formatVersion
            )
        }
        let generationIsValid = manifest.destinationGeneration.flatMap(UUID.init(uuidString:)) != nil
        switch (
            manifest.activeBackend,
            manifest.migrationState,
            manifest.migrationReceipt,
            generationIsValid
        ) {
        case (.secureFiles, .fileToSwiftDataEligible, nil, false):
            return
        case (.swiftData, .swiftDataActivationPending, nil, true),
             (.swiftData, .notRequired, nil, true):
            return
        case let (.swiftData, .fileToSwiftDataCompleted, receipt?, true):
            guard receipt.migrationVersion
                    == OrderedCollectionPersistenceManifest.currentMigrationVersion,
                  receipt.sourceBackend == .secureFiles,
                  receipt.destinationBackend == .swiftData,
                  receipt.sourceFingerprint.isEmpty == false else {
                throw OrderedCollectionPersistenceFactoryError.inconsistentManifest
            }
        default:
            throw OrderedCollectionPersistenceFactoryError.inconsistentManifest
        }
    }

    private static func unavailableBundle() -> OrderedCollectionPersistenceBundle {
        OrderedCollectionPersistenceBundle(
            browsingHistory: UnavailableBrowsingHistoryPersistence(),
            recentForums: UnavailableRecentForumPersistence(),
            searchHistory: UnavailableSearchHistoryPersistence()
        )
    }
}

@MainActor
enum AppOrderedCollectionPersistence {
    private static let bundle = OrderedCollectionPersistenceFactory.makeApplicationBundle()

    static var browsingHistory: any BrowsingHistoryPersistence {
        bundle.browsingHistory
    }

    static var recentForums: any RecentForumPersistence {
        bundle.recentForums
    }

    static var searchHistory: any SearchHistoryPersistence {
        bundle.searchHistory
    }
}

extension BrowsingHistoryStore {
    convenience init(
        defaults: UserDefaults = .standard,
        key: String = "dev.infinityf4p.tiebapure.browsingHistory",
        limit: Int = BrowsingHistoryPolicy.maximumStoredEntries,
        faultInjector: PersistenceFaultInjector = .none,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(
            defaults: defaults,
            key: key,
            limit: limit,
            persistence: AppOrderedCollectionPersistence.browsingHistory,
            faultInjector: faultInjector,
            now: now
        )
    }
}

extension RecentForumStore {
    convenience init(
        defaults: UserDefaults = .standard,
        key: String = "dev.infinityf4p.tiebapure.recentForums",
        limit: Int = RecentForumPolicy.maximumStoredEntries,
        faultInjector: PersistenceFaultInjector = .none,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(
            defaults: defaults,
            key: key,
            limit: limit,
            persistence: AppOrderedCollectionPersistence.recentForums,
            faultInjector: faultInjector,
            now: now
        )
    }
}

extension SearchHistoryStore {
    convenience init(
        defaults: UserDefaults = .standard,
        key: String = "dev.infinityf4p.tiebapure.searchHistory",
        limit: Int = SearchHistoryPolicy.maximumStoredEntries,
        faultInjector: PersistenceFaultInjector = .none
    ) {
        self.init(
            defaults: defaults,
            key: key,
            limit: limit,
            persistence: AppOrderedCollectionPersistence.searchHistory,
            faultInjector: faultInjector
        )
    }
}

@MainActor
private final class UnavailableBrowsingHistoryPersistence: BrowsingHistoryPersistence {
    let capability: PersistenceCapability = .unavailable

    func load() throws -> [BrowsingHistoryEntry] {
        throw OrderedCollectionPersistenceFactoryError.backendUnavailable
    }

    func replaceAll(
        _ entries: [BrowsingHistoryEntry],
        beforeCommit: () throws -> Void
    ) throws {
        throw OrderedCollectionPersistenceFactoryError.backendUnavailable
    }

    func upsert(
        _ entry: BrowsingHistoryEntry,
        limit: Int
    ) async throws -> [BrowsingHistoryEntry] {
        throw OrderedCollectionPersistenceFactoryError.backendUnavailable
    }

    func remove(threadIDs: Set<Int64>) async throws -> [BrowsingHistoryEntry] {
        throw OrderedCollectionPersistenceFactoryError.backendUnavailable
    }

    func removeAll() async throws -> [BrowsingHistoryEntry] {
        throw OrderedCollectionPersistenceFactoryError.backendUnavailable
    }
}

@MainActor
private final class UnavailableRecentForumPersistence: RecentForumPersistence {
    let capability: PersistenceCapability = .unavailable

    func load() throws -> [RecentForum] {
        throw OrderedCollectionPersistenceFactoryError.backendUnavailable
    }

    func replaceAll(
        _ entries: [RecentForum],
        beforeCommit: () throws -> Void
    ) throws {
        throw OrderedCollectionPersistenceFactoryError.backendUnavailable
    }
}

@MainActor
private final class UnavailableSearchHistoryPersistence: SearchHistoryPersistence {
    let capability: PersistenceCapability = .unavailable

    func load() throws -> [String] {
        throw OrderedCollectionPersistenceFactoryError.backendUnavailable
    }

    func replaceAll(
        _ entries: [String],
        beforeCommit: () throws -> Void
    ) throws {
        throw OrderedCollectionPersistenceFactoryError.backendUnavailable
    }
}
