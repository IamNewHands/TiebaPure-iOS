import Foundation
import XCTest
@testable import TiebaPure

final class FileOrderedCollectionPersistenceTests: XCTestCase {
    private enum InjectedFailure: Error {
        case beforeCommit
        case swiftDataUnavailable
    }

    private func makeScratchDirectory(function: String = #function) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(function)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    @MainActor
    func testAdaptersPersistIndependentOrderedSnapshotsAcrossReopen() throws {
        let directory = try makeScratchDirectory()
        let browsingEntries = [
            makeBrowsingEntry(threadID: 2, visitedAt: 2),
            makeBrowsingEntry(threadID: 1, visitedAt: 1)
        ]
        let recentEntries = [
            makeRecentForum(name: "second", updatedAt: 2),
            makeRecentForum(name: "first", updatedAt: 1)
        ]
        let searchEntries = ["second", "first"]

        let first = try FileOrderedCollectionPersistenceBundle(directoryURL: directory)
        try first.browsingHistory.replaceAll(browsingEntries)
        try first.recentForums.replaceAll(recentEntries)
        try first.searchHistory.replaceAll(searchEntries)

        let reopened = try FileOrderedCollectionPersistenceBundle(directoryURL: directory)
        XCTAssertEqual(try reopened.browsingHistory.load(), browsingEntries)
        XCTAssertEqual(try reopened.recentForums.load(), recentEntries)
        XCTAssertEqual(try reopened.searchHistory.load(), searchEntries)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
            Set([
                "browsing-history.json",
                "browsing-history.json.backup",
                "recent-forums.json",
                "recent-forums.json.backup",
                "search-history.json",
                "search-history.json.backup"
            ])
        )
    }

    @MainActor
    func testBrowsingHistoryTransactionsAcrossAdaptersDoNotLoseUpdates() async throws {
        let directory = try makeScratchDirectory()
        let first = try FileBrowsingHistoryPersistence(directoryURL: directory)
        let second = try FileBrowsingHistoryPersistence(directoryURL: directory)

        async let firstResult = first.upsert(
            makeBrowsingEntry(threadID: 1, visitedAt: 1),
            limit: 10
        )
        async let secondResult = second.upsert(
            makeBrowsingEntry(threadID: 2, visitedAt: 2),
            limit: 10
        )
        _ = try await (firstResult, secondResult)

        XCTAssertEqual(Set(try first.load().map(\.threadID)), Set([Int64(1), Int64(2)]))
    }

    @MainActor
    func testCancelledBrowsingMutationDoesNotCommitOrPoisonNextMutation() async throws {
        let directory = try makeScratchDirectory()
        let persistence = try FileBrowsingHistoryPersistence(directoryURL: directory)
        let cancelled = Task {
            try await persistence.upsert(
                makeBrowsingEntry(threadID: 1, visitedAt: 1),
                limit: 10
            )
        }
        cancelled.cancel()

        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation before the atomic commit")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(try persistence.load(), [])

        let committed = try await persistence.upsert(
            makeBrowsingEntry(threadID: 2, visitedAt: 2),
            limit: 10
        )
        XCTAssertEqual(committed.map(\.threadID), [2])
        XCTAssertEqual(try persistence.load().map(\.threadID), [2])
    }

    @MainActor
    func testBeforeCommitFailureLeavesPrimaryBytesUnchangedAndNoTemporaryFiles() throws {
        let directory = try makeScratchDirectory()
        let persistence = try FileSearchHistoryPersistence(directoryURL: directory)
        try persistence.replaceAll(["original"])
        let fileURL = directory.appendingPathComponent("search-history.json")
        let originalBytes = try Data(contentsOf: fileURL)

        XCTAssertThrowsError(
            try persistence.replaceAll(["candidate"]) {
                throw InjectedFailure.beforeCommit
            }
        )

        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)
        XCTAssertEqual(try persistence.load(), ["original"])
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains(where: { $0.hasSuffix(".tmp") })
        )
    }

    @MainActor
    func testPrimaryCorruptionRecoversLatestGenerationAndClearDoesNotResurrectData() throws {
        let directory = try makeScratchDirectory()
        let persistence = try FileSearchHistoryPersistence(directoryURL: directory)
        let primaryURL = directory.appendingPathComponent("search-history.json")

        try persistence.replaceAll(["first"])
        try persistence.replaceAll(["latest"])
        try Data("truncated".utf8).write(to: primaryURL)
        XCTAssertEqual(try persistence.load(), ["latest"])

        try persistence.replaceAll([])
        try Data("truncated-again".utf8).write(to: primaryURL)
        XCTAssertEqual(try persistence.load(), [])
    }

    @MainActor
    func testDoubleCorruptionFailsClosedUntilExplicitRecovery() throws {
        let directory = try makeScratchDirectory()
        let persistence = try FileSearchHistoryPersistence(directoryURL: directory)
        let secondInstance = try FileSearchHistoryPersistence(directoryURL: directory)
        try persistence.replaceAll(["protected"])

        let primaryURL = directory.appendingPathComponent("search-history.json")
        let backupURL = directory.appendingPathComponent("search-history.json.backup")
        try Data("bad-primary".utf8).write(to: primaryURL)
        try Data("bad-backup".utf8).write(to: backupURL)

        XCTAssertThrowsError(try persistence.load())
        XCTAssertThrowsError(try secondInstance.replaceAll(["must-not-overwrite-corruption"]))
        XCTAssertEqual(try Data(contentsOf: primaryURL), Data("bad-primary".utf8))

        try secondInstance.recoverCorruptedStorage()
        try persistence.replaceAll(["recovered"])
        XCTAssertEqual(try persistence.load(), ["recovered"])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.contains(".corrupt-") }.count,
            2
        )
    }

    @MainActor
    func testFilesUsePrivatePermissionsAndCompleteProtection() throws {
        let directory = try makeScratchDirectory()
        let persistence = try FileSearchHistoryPersistence(directoryURL: directory)
        try persistence.replaceAll(["private"])

        let fileURL = directory.appendingPathComponent("search-history.json")
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileMode = try XCTUnwrap(fileAttributes[.posixPermissions] as? NSNumber).intValue
        let directoryMode = try XCTUnwrap(
            directoryAttributes[.posixPermissions] as? NSNumber
        ).intValue

        XCTAssertEqual(fileMode & 0o777, 0o600)
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        // CoreSimulator does not expose NSFileProtectionKey on every host
        // filesystem. Verify it whenever the filesystem reports support.
        if let protection = fileAttributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .complete)
        }
    }

    func testApplicationPersistenceLocationHardensEveryOwnedDirectory() throws {
        let applicationSupport = try makeScratchDirectory()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: applicationSupport.path
        )
        let preexisting = applicationSupport.appendingPathComponent(
            "TiebaPure",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: preexisting, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: preexisting.path
        )

        let location = try SecurePersistenceLocation.applicationSupport(
            baseDirectoryURL: applicationSupport
        )

        let ownedDirectories = [
            preexisting,
            preexisting.appendingPathComponent("Persistence", isDirectory: true),
            location.directoryURL
        ]
        for directory in ownedDirectories {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            let mode = try XCTUnwrap(
                attributes[.posixPermissions] as? NSNumber
            ).intValue
            XCTAssertEqual(mode & 0o777, 0o700)
            if let protection = attributes[.protectionKey] as? FileProtectionType {
                XCTAssertEqual(protection, .complete)
            }
        }
        let rootAttributes = try FileManager.default.attributesOfItem(
            atPath: applicationSupport.path
        )
        let rootMode = try XCTUnwrap(
            rootAttributes[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(rootMode & 0o777, 0o755)
    }

    func testApplicationPersistenceLocationRejectsIntermediateSymbolicLink() throws {
        let applicationSupport = try makeScratchDirectory(function: "root")
        let outside = try makeScratchDirectory(function: "outside")
        let linked = applicationSupport.appendingPathComponent("TiebaPure", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linked,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try SecurePersistenceLocation.applicationSupport(
            baseDirectoryURL: applicationSupport
        )) { error in
            XCTAssertEqual(error as? SecureFilePersistenceError, .pathIsSymbolicLink)
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty
        )
    }

    func testMissingFileIsEmptyButOversizedAndSymbolicLinkFilesFailClosed() throws {
        let missingDirectory = try makeScratchDirectory(function: "missing")
        let missing = try SecureCodableFile<[String]>(
            directoryURL: missingDirectory,
            fileName: "values.json"
        )
        XCTAssertNil(try missing.load())

        let oversizedDirectory = try makeScratchDirectory(function: "oversized")
        let oversized = try SecureCodableFile<[String]>(
            directoryURL: oversizedDirectory,
            fileName: "values.json",
            maximumByteCount: 32
        )
        try Data(repeating: 0x41, count: 64).write(to: oversized.fileURL)
        try Data(repeating: 0x42, count: 64).write(to: oversized.backupURL)
        XCTAssertThrowsError(try oversized.load())
        XCTAssertThrowsError(try oversized.replace(["must-not-overwrite"]))

        let symlinkDirectory = try makeScratchDirectory(function: "symlink")
        let outsideURL = symlinkDirectory.appendingPathComponent("outside.json")
        try Data("outside".utf8).write(to: outsideURL)
        let linkURL = symlinkDirectory.appendingPathComponent("values.json")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: outsideURL
        )
        let linked = try SecureCodableFile<[String]>(
            directoryURL: symlinkDirectory,
            fileName: "values.json"
        )
        XCTAssertThrowsError(try linked.load()) { error in
            XCTAssertEqual(error as? SecureFilePersistenceError, .pathIsSymbolicLink)
        }
        XCTAssertEqual(try Data(contentsOf: outsideURL), Data("outside".utf8))
    }

    @MainActor
    func testFactoryMigratesFileBackendWithReceiptAndKeepsSourceSnapshot() throws {
        let sourceDirectory = try makeScratchDirectory(function: "source")
        let destinationDirectory = try makeScratchDirectory(function: "destination")
        let completedAt = Date(timeIntervalSinceReferenceDate: 123)
        let marker = TestOrderedCollectionBackendMarkerPersistence()

        let iOS16Bundle = OrderedCollectionPersistenceFactory(
            directoryURL: sourceDirectory,
            supportsSwiftData: false
        ) {
            throw InjectedFailure.swiftDataUnavailable
        }.make()
        let sourceSnapshot = makeSnapshot()
        try iOS16Bundle.replaceAll(with: sourceSnapshot)

        let migrated = OrderedCollectionPersistenceFactory(
            directoryURL: sourceDirectory,
            supportsSwiftData: true,
            now: { completedAt }
        ) {
            try self.makeDestinationBundle(
                directoryURL: destinationDirectory,
                marker: marker
            )
        }.make()

        XCTAssertEqual(try migrated.snapshot(), sourceSnapshot)
        XCTAssertEqual(
            try FileOrderedCollectionPersistenceBundle(
                directoryURL: sourceDirectory
            ).erased.snapshot(),
            sourceSnapshot
        )

        let manifest = try loadManifest(from: sourceDirectory)
        XCTAssertEqual(manifest.activeBackend, .swiftData)
        XCTAssertEqual(manifest.migrationState, .fileToSwiftDataCompleted)
        XCTAssertEqual(manifest.migrationReceipt?.completedAt, completedAt)
        XCTAssertEqual(manifest.destinationGeneration, marker.generation)
        XCTAssertFalse(try XCTUnwrap(marker.generation).isEmpty)
        XCTAssertEqual(
            manifest.migrationReceipt?.sourceFingerprint,
            try sourceSnapshot.fingerprint()
        )
    }

    @MainActor
    func testMissingManifestWithFileArtifactsFailsClosedWithoutOpeningDestination() throws {
        let sourceDirectory = try makeScratchDirectory(function: "source")
        let sourceSnapshot = makeSnapshot()
        let unmanifestedFiles = try FileOrderedCollectionPersistenceBundle(
            directoryURL: sourceDirectory
        ).erased
        try unmanifestedFiles.replaceAll(with: sourceSnapshot)
        var destinationBuilderCallCount = 0

        let resolved = OrderedCollectionPersistenceFactory(
            directoryURL: sourceDirectory,
            supportsSwiftData: true
        ) {
            destinationBuilderCallCount += 1
            throw InjectedFailure.swiftDataUnavailable
        }.make()

        XCTAssertEqual(resolved.browsingHistory.capability, .unavailable)
        XCTAssertEqual(resolved.recentForums.capability, .unavailable)
        XCTAssertEqual(resolved.searchHistory.capability, .unavailable)
        XCTAssertEqual(destinationBuilderCallCount, 0)
        XCTAssertEqual(try unmanifestedFiles.snapshot(), sourceSnapshot)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sourceDirectory
                .appendingPathComponent("ordered-collections-manifest.json")
                .path
        ))
    }

    @MainActor
    func testMissingManifestWithExistingDestinationMarkerReelectsBackendKeepingEntries() throws {
        let stateDirectory = try makeScratchDirectory(function: "state")
        let destinationDirectory = try makeScratchDirectory(function: "destination")
        let marker = TestOrderedCollectionBackendMarkerPersistence()
        let destination = try makeDestinationBundle(
            directoryURL: destinationDirectory,
            marker: marker
        )
        try destination.replaceAll(with: makeSnapshot())

        _ = OrderedCollectionPersistenceFactory(
            directoryURL: stateDirectory,
            supportsSwiftData: true
        ) {
            destination
        }.make()
        let expectedDestination = try destination.snapshot()
        let abandonedGeneration = try XCTUnwrap(marker.generation)

        let manifest = try SecureCodableFile<OrderedCollectionPersistenceManifest>(
            directoryURL: stateDirectory,
            fileName: "ordered-collections-manifest.json"
        )
        try FileManager.default.removeItem(at: manifest.fileURL)
        try FileManager.default.removeItem(at: manifest.backupURL)

        let resolved = OrderedCollectionPersistenceFactory(
            directoryURL: stateDirectory,
            supportsSwiftData: true
        ) {
            destination
        }.make()

        // The marker is only the store's copy of the backend token: with the
        // manifest gone the election is redone over the leftover marker, and
        // the entries already in the database stay readable.
        XCTAssertEqual(resolved.browsingHistory.capability, .durable)
        XCTAssertEqual(try destination.snapshot(), expectedDestination)
        XCTAssertNotNil(marker.generation)
        XCTAssertNotEqual(marker.generation, abandonedGeneration)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.fileURL.path))
    }

    @MainActor
    func testInitialSwiftDataFallbackDoesNotCommitBackendManifest() throws {
        let directory = try makeScratchDirectory()
        let fallback = OrderedCollectionPersistenceBundle(
            browsingHistory: FallbackTestBrowsingPersistence(),
            recentForums: FallbackTestRecentPersistence(),
            searchHistory: FallbackTestSearchPersistence()
        )

        let resolved = OrderedCollectionPersistenceFactory(
            directoryURL: directory,
            supportsSwiftData: true
        ) {
            fallback
        }.make()

        XCTAssertEqual(resolved.browsingHistory.capability, .fallback)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent("ordered-collections-manifest.json")
                    .path
            )
        )
    }

    @MainActor
    func testNativeSwiftDataActivationPreservesExistingRowsAndCommitsMarker() throws {
        let stateDirectory = try makeScratchDirectory(function: "state")
        let destinationDirectory = try makeScratchDirectory(function: "destination")
        let marker = TestOrderedCollectionBackendMarkerPersistence()
        let destination = try makeDestinationBundle(
            directoryURL: destinationDirectory,
            marker: marker
        )
        let existing = makeSnapshot()
        try destination.replaceAll(with: existing)

        let resolved = OrderedCollectionPersistenceFactory(
            directoryURL: stateDirectory,
            supportsSwiftData: true
        ) { destination }.make()

        XCTAssertEqual(try resolved.snapshot(), existing)
        let manifest = try loadManifest(from: stateDirectory)
        XCTAssertEqual(manifest.activeBackend, .swiftData)
        XCTAssertEqual(manifest.migrationState, .notRequired)
        XCTAssertEqual(manifest.destinationGeneration, marker.generation)
        XCTAssertEqual(marker.replaceCallCount, 1)
    }

    @MainActor
    func testPendingNativeActivationRetriesTheSpecifiedGeneration() throws {
        let stateDirectory = try makeScratchDirectory(function: "state")
        let destinationDirectory = try makeScratchDirectory(function: "destination")
        let marker = TestOrderedCollectionBackendMarkerPersistence()
        marker.replaceError = InjectedFailure.beforeCommit
        let destination = try makeDestinationBundle(
            directoryURL: destinationDirectory,
            marker: marker
        )

        let first = OrderedCollectionPersistenceFactory(
            directoryURL: stateDirectory,
            supportsSwiftData: true
        ) { destination }.make()
        XCTAssertEqual(first.browsingHistory.capability, .unavailable)
        let pending = try loadManifest(from: stateDirectory)
        XCTAssertEqual(pending.migrationState, .swiftDataActivationPending)
        let pendingGeneration = try XCTUnwrap(pending.destinationGeneration)
        XCTAssertNil(marker.generation)

        marker.replaceError = nil
        let retried = OrderedCollectionPersistenceFactory(
            directoryURL: stateDirectory,
            supportsSwiftData: true
        ) { destination }.make()

        XCTAssertEqual(retried.browsingHistory.capability, .durable)
        XCTAssertEqual(marker.generation, pendingGeneration)
        let active = try loadManifest(from: stateDirectory)
        XCTAssertEqual(active.migrationState, .notRequired)
        XCTAssertEqual(active.destinationGeneration, pendingGeneration)
    }

    @MainActor
    func testPendingActivationWithMatchingMarkerOnlyFinishesManifestCommit() throws {
        let stateDirectory = try makeScratchDirectory(function: "state")
        let destinationDirectory = try makeScratchDirectory(function: "destination")
        let generation = "11111111-1111-1111-1111-111111111111"
        let marker = TestOrderedCollectionBackendMarkerPersistence(generation: generation)
        let destination = try makeDestinationBundle(
            directoryURL: destinationDirectory,
            marker: marker
        )
        let manifest = try SecureCodableFile<OrderedCollectionPersistenceManifest>(
            directoryURL: stateDirectory,
            fileName: "ordered-collections-manifest.json"
        )
        try manifest.replace(.pendingSwiftDataActivation(
            destinationGeneration: generation
        ))

        let resolved = OrderedCollectionPersistenceFactory(
            directoryURL: stateDirectory,
            supportsSwiftData: true
        ) { destination }.make()

        XCTAssertEqual(resolved.browsingHistory.capability, .durable)
        XCTAssertEqual(marker.replaceCallCount, 0)
        XCTAssertEqual(try loadManifest(from: stateDirectory).migrationState, .notRequired)
    }

    @MainActor
    func testActiveSwiftDataAdoptsCommittedGenerationAfterDatabaseRebuildLosesMarker() throws {
        let stateDirectory = try makeScratchDirectory(function: "state")
        let destinationDirectory = try makeScratchDirectory(function: "destination")
        let expectedGeneration = "22222222-2222-2222-2222-222222222222"
        let manifest = try SecureCodableFile<OrderedCollectionPersistenceManifest>(
            directoryURL: stateDirectory,
            fileName: "ordered-collections-manifest.json"
        )
        try manifest.replace(.initialSwiftDataBackend(
            destinationGeneration: expectedGeneration
        ))
        let rebuiltMarker = TestOrderedCollectionBackendMarkerPersistence()
        let rebuiltDestination = try makeDestinationBundle(
            directoryURL: destinationDirectory,
            marker: rebuiltMarker
        )

        let resolved = OrderedCollectionPersistenceFactory(
            directoryURL: stateDirectory,
            supportsSwiftData: true
        ) { rebuiltDestination }.make()

        // The manifest is the backend-selection commit point, and the marker is
        // only the store's copy of the same token: a database that lost its own
        // marker is claimed by the committed generation instead of leaving
        // browsing history, recent forums and search history unavailable for the
        // rest of the install.
        XCTAssertEqual(resolved.browsingHistory.capability, .durable)
        XCTAssertEqual(rebuiltMarker.generation, expectedGeneration)
        XCTAssertEqual(rebuiltMarker.replaceCallCount, 1)
    }

    @MainActor
    func testActiveAndPendingSwiftDataAdoptCommittedGenerationOverStaleMarker() throws {
        for migrationState in [
            OrderedCollectionMigrationState.notRequired,
            .swiftDataActivationPending
        ] {
            let stateDirectory = try makeScratchDirectory(function: "state-\(migrationState.rawValue)")
            let destinationDirectory = try makeScratchDirectory(
                function: "destination-\(migrationState.rawValue)"
            )
            let expectedGeneration = "33333333-3333-3333-3333-333333333333"
            let manifest = try SecureCodableFile<OrderedCollectionPersistenceManifest>(
                directoryURL: stateDirectory,
                fileName: "ordered-collections-manifest.json"
            )
            let state: OrderedCollectionPersistenceManifest = migrationState == .notRequired
                ? .initialSwiftDataBackend(destinationGeneration: expectedGeneration)
                : .pendingSwiftDataActivation(destinationGeneration: expectedGeneration)
            try manifest.replace(state)
            let marker = TestOrderedCollectionBackendMarkerPersistence(
                generation: "44444444-4444-4444-4444-444444444444"
            )
            let destination = try makeDestinationBundle(
                directoryURL: destinationDirectory,
                marker: marker
            )

            let resolved = OrderedCollectionPersistenceFactory(
                directoryURL: stateDirectory,
                supportsSwiftData: true
            ) { destination }.make()

            // A marker left by an earlier database is replaced with the
            // committed generation; nothing stored in the destination is
            // dropped, because the generation only names the backend.
            XCTAssertEqual(resolved.browsingHistory.capability, .durable)
            XCTAssertEqual(marker.generation, expectedGeneration)
            XCTAssertEqual(marker.replaceCallCount, 1)
        }
    }

    @MainActor
    func testLegitimateClearKeepsMarkerAndReopensEmptySwiftData() throws {
        let stateDirectory = try makeScratchDirectory(function: "state")
        let destinationDirectory = try makeScratchDirectory(function: "destination")
        let marker = TestOrderedCollectionBackendMarkerPersistence()
        let destination = try makeDestinationBundle(
            directoryURL: destinationDirectory,
            marker: marker
        )
        try destination.replaceAll(with: makeSnapshot())
        _ = OrderedCollectionPersistenceFactory(
            directoryURL: stateDirectory,
            supportsSwiftData: true
        ) { destination }.make()
        let generation = try XCTUnwrap(marker.generation)

        try destination.replaceAll(with: OrderedCollectionPersistenceSnapshot(
            browsingHistory: [],
            recentForums: [],
            searchHistory: []
        ))
        let reopened = OrderedCollectionPersistenceFactory(
            directoryURL: stateDirectory,
            supportsSwiftData: true
        ) { destination }.make()

        XCTAssertTrue(try reopened.snapshot().isEmpty)
        XCTAssertEqual(marker.generation, generation)
        XCTAssertEqual(marker.replaceCallCount, 1)
    }

    @MainActor
    func testFileMigrationRechecksSourceAndRetriesPartialDestination() throws {
        let sourceDirectory = try makeScratchDirectory(function: "source")
        let destinationDirectory = try makeScratchDirectory(function: "destination")
        let source = OrderedCollectionPersistenceFactory(
            directoryURL: sourceDirectory,
            supportsSwiftData: false
        ) { throw InjectedFailure.swiftDataUnavailable }.make()
        try source.replaceAll(with: makeSnapshot())
        let marker = TestOrderedCollectionBackendMarkerPersistence()
        marker.onReplace = { _ in
            try source.searchHistory.replaceAll(["source-changed-during-migration"])
        }

        let first = OrderedCollectionPersistenceFactory(
            directoryURL: sourceDirectory,
            supportsSwiftData: true
        ) {
            try self.makeDestinationBundle(
                directoryURL: destinationDirectory,
                marker: marker
            )
        }.make()

        XCTAssertEqual(try first.searchHistory.load(), ["source-changed-during-migration"])
        XCTAssertEqual(try loadManifest(from: sourceDirectory).activeBackend, .secureFiles)
        XCTAssertNotNil(marker.generation)

        marker.onReplace = nil
        let retried = OrderedCollectionPersistenceFactory(
            directoryURL: sourceDirectory,
            supportsSwiftData: true
        ) {
            try self.makeDestinationBundle(
                directoryURL: destinationDirectory,
                marker: marker
            )
        }.make()

        XCTAssertEqual(try retried.searchHistory.load(), ["source-changed-during-migration"])
        let active = try loadManifest(from: sourceDirectory)
        XCTAssertEqual(active.activeBackend, .swiftData)
        XCTAssertEqual(active.destinationGeneration, marker.generation)
    }

    @MainActor
    func testCommittedSwiftDataBackendFailsClosedWhenOnlyFallbackOpens() throws {
        let directory = try makeScratchDirectory()
        let manifest = try SecureCodableFile<OrderedCollectionPersistenceManifest>(
            directoryURL: directory,
            fileName: "ordered-collections-manifest.json"
        )
        try manifest.replace(.initialSwiftDataBackend(
            destinationGeneration: "55555555-5555-5555-5555-555555555555"
        ))
        let fallback = OrderedCollectionPersistenceBundle(
            browsingHistory: FallbackTestBrowsingPersistence(),
            recentForums: FallbackTestRecentPersistence(),
            searchHistory: FallbackTestSearchPersistence()
        )

        let resolved = OrderedCollectionPersistenceFactory(
            directoryURL: directory,
            supportsSwiftData: true
        ) { fallback }.make()

        XCTAssertEqual(resolved.browsingHistory.capability, .unavailable)
        XCTAssertEqual(resolved.recentForums.capability, .unavailable)
        XCTAssertEqual(resolved.searchHistory.capability, .unavailable)
    }

    @MainActor
    func testMigrationFailureKeepsFileBackendEligibleForRetry() throws {
        let sourceDirectory = try makeScratchDirectory(function: "source")
        let source = OrderedCollectionPersistenceFactory(
            directoryURL: sourceDirectory,
            supportsSwiftData: false
        ) {
            throw InjectedFailure.swiftDataUnavailable
        }.make()
        let sourceSnapshot = makeSnapshot()
        try source.replaceAll(with: sourceSnapshot)

        let failed = OrderedCollectionPersistenceFactory(
            directoryURL: sourceDirectory,
            supportsSwiftData: true
        ) {
            OrderedCollectionPersistenceBundle(
                browsingHistory: UnavailableTestBrowsingPersistence(),
                recentForums: UnavailableTestRecentPersistence(),
                searchHistory: UnavailableTestSearchPersistence()
            )
        }.make()

        XCTAssertEqual(try failed.snapshot(), sourceSnapshot)
        let manifest = try loadManifest(from: sourceDirectory)
        XCTAssertEqual(manifest.activeBackend, .secureFiles)
        XCTAssertEqual(manifest.migrationState, .fileToSwiftDataEligible)
        XCTAssertNil(manifest.migrationReceipt)
    }

    @MainActor
    func testCorruptManifestReturnsUnavailableWithoutSelectingAnotherBackend() throws {
        let directory = try makeScratchDirectory()
        let manifestFile = try SecureCodableFile<OrderedCollectionPersistenceManifest>(
            directoryURL: directory,
            fileName: "ordered-collections-manifest.json"
        )
        try manifestFile.replace(.initialFileBackend())
        try Data("bad-primary".utf8).write(to: manifestFile.fileURL)
        try Data("bad-backup".utf8).write(to: manifestFile.backupURL)
        var swiftDataBuilderCallCount = 0

        let bundle = OrderedCollectionPersistenceFactory(
            directoryURL: directory,
            supportsSwiftData: true
        ) {
            swiftDataBuilderCallCount += 1
            throw InjectedFailure.swiftDataUnavailable
        }.make()

        XCTAssertEqual(bundle.browsingHistory.capability, .unavailable)
        XCTAssertEqual(bundle.recentForums.capability, .unavailable)
        XCTAssertEqual(bundle.searchHistory.capability, .unavailable)
        XCTAssertEqual(swiftDataBuilderCallCount, 0)
    }

    @MainActor
    private func loadManifest(
        from directory: URL
    ) throws -> OrderedCollectionPersistenceManifest {
        let file = try SecureCodableFile<OrderedCollectionPersistenceManifest>(
            directoryURL: directory,
            fileName: "ordered-collections-manifest.json"
        )
        return try XCTUnwrap(file.load())
    }

    @MainActor
    private func makeDestinationBundle(
        directoryURL: URL,
        marker: TestOrderedCollectionBackendMarkerPersistence
    ) throws -> OrderedCollectionPersistenceBundle {
        let files = try FileOrderedCollectionPersistenceBundle(directoryURL: directoryURL)
        return OrderedCollectionPersistenceBundle(
            browsingHistory: files.browsingHistory,
            recentForums: files.recentForums,
            searchHistory: files.searchHistory,
            backendMarker: marker
        )
    }

    private func makeSnapshot() -> OrderedCollectionPersistenceSnapshot {
        OrderedCollectionPersistenceSnapshot(
            browsingHistory: [makeBrowsingEntry(threadID: 1, visitedAt: 1)],
            recentForums: [makeRecentForum(name: "forum", updatedAt: 1)],
            searchHistory: ["keyword"]
        )
    }

    private func makeBrowsingEntry(
        threadID: Int64,
        visitedAt: TimeInterval
    ) -> BrowsingHistoryEntry {
        BrowsingHistoryEntry(
            threadID: threadID,
            title: "thread-\(threadID)",
            authorDisplayName: "author-\(threadID)",
            visitedAt: Date(timeIntervalSinceReferenceDate: visitedAt)
        )
    }

    private func makeRecentForum(
        name: String,
        updatedAt: TimeInterval
    ) -> RecentForum {
        RecentForum(
            name: name,
            displayName: "\(name)吧",
            updatedAt: Date(timeIntervalSinceReferenceDate: updatedAt)
        )
    }
}

@MainActor
private final class UnavailableTestBrowsingPersistence: BrowsingHistoryPersistence {
    let capability: PersistenceCapability = .unavailable

    func load() throws -> [BrowsingHistoryEntry] { [] }
    func replaceAll(
        _ entries: [BrowsingHistoryEntry],
        beforeCommit: () throws -> Void
    ) throws {}
    func upsert(
        _ entry: BrowsingHistoryEntry,
        limit: Int
    ) async throws -> [BrowsingHistoryEntry] { [] }
    func remove(threadIDs: Set<Int64>) async throws -> [BrowsingHistoryEntry] { [] }
    func removeAll() async throws -> [BrowsingHistoryEntry] { [] }
}

@MainActor
private final class UnavailableTestRecentPersistence: RecentForumPersistence {
    let capability: PersistenceCapability = .unavailable

    func load() throws -> [RecentForum] { [] }
    func replaceAll(
        _ entries: [RecentForum],
        beforeCommit: () throws -> Void
    ) throws {}
}

@MainActor
private final class UnavailableTestSearchPersistence: SearchHistoryPersistence {
    let capability: PersistenceCapability = .unavailable

    func load() throws -> [String] { [] }
    func replaceAll(
        _ entries: [String],
        beforeCommit: () throws -> Void
    ) throws {}
}

@MainActor
private final class FallbackTestBrowsingPersistence: BrowsingHistoryPersistence {
    let capability: PersistenceCapability = .fallback

    func load() throws -> [BrowsingHistoryEntry] { [] }
    func replaceAll(
        _ entries: [BrowsingHistoryEntry],
        beforeCommit: () throws -> Void
    ) throws {}
    func upsert(
        _ entry: BrowsingHistoryEntry,
        limit: Int
    ) async throws -> [BrowsingHistoryEntry] { [] }
    func remove(threadIDs: Set<Int64>) async throws -> [BrowsingHistoryEntry] { [] }
    func removeAll() async throws -> [BrowsingHistoryEntry] { [] }
}

@MainActor
private final class FallbackTestRecentPersistence: RecentForumPersistence {
    let capability: PersistenceCapability = .fallback

    func load() throws -> [RecentForum] { [] }
    func replaceAll(
        _ entries: [RecentForum],
        beforeCommit: () throws -> Void
    ) throws {}
}

@MainActor
private final class FallbackTestSearchPersistence: SearchHistoryPersistence {
    let capability: PersistenceCapability = .fallback

    func load() throws -> [String] { [] }
    func replaceAll(
        _ entries: [String],
        beforeCommit: () throws -> Void
    ) throws {}
}

@MainActor
private final class TestOrderedCollectionBackendMarkerPersistence:
    OrderedCollectionBackendMarkerPersistence
{
    let capability: PersistenceCapability
    var generation: String?
    var replaceError: Error?
    var onReplace: ((String) throws -> Void)?
    private(set) var replaceCallCount = 0

    init(
        capability: PersistenceCapability = .durable,
        generation: String? = nil
    ) {
        self.capability = capability
        self.generation = generation
    }

    func loadGeneration() throws -> String? {
        generation
    }

    func replaceGeneration(_ generation: String) throws {
        if let replaceError {
            throw replaceError
        }
        self.generation = generation
        replaceCallCount += 1
        try onReplace?(generation)
    }
}
