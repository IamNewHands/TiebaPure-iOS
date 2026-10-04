import Foundation
import SwiftData
import XCTest
@testable import TiebaPure

@available(iOS 17.0, *)
final class ContentDraftMigrationTests: XCTestCase {
    private enum InjectedFailure: Error {
        case stateCommit
    }

    private actor MigrationGate {
        private var entered = false
        private var released = false

        func pause() async throws {
            entered = true
            while released == false {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        func waitUntilEntered() async {
            while entered == false {
                await Task.yield()
            }
        }

        func release() {
            released = true
        }
    }

    private actor InvocationCounter {
        private(set) var count = 0

        func increment() {
            count += 1
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TiebaPure-ContentDraftMigrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(AppModelContainer.models)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }

    private func makeTarget(threadID: Int64) -> ContentSubmissionTarget {
        ContentSubmissionTarget(
            kind: .threadReply,
            forumID: 10,
            forumName: "fixture",
            forumDisplayName: "测试吧",
            threadID: threadID,
            threadTitle: "测试帖子",
            parentPostID: nil,
            parentFloor: nil,
            subpostID: nil,
            replyUserID: nil,
            replyUserDisplayName: nil
        )
    }

    private func makeDraft(
        threadID: Int64,
        marker: UInt8,
        updatedAt: TimeInterval? = nil
    ) -> ContentDraft {
        ContentDraft(
            accountID: "account",
            target: makeTarget(threadID: threadID),
            title: "title-\(threadID)",
            body: "body-\(threadID)",
            images: [ContentSubmissionImage(
                data: Data(repeating: marker, count: 32),
                pixelWidth: 20,
                pixelHeight: 30,
                mimeType: "image/jpeg"
            )],
            updatedAt: Date(timeIntervalSince1970: updatedAt ?? TimeInterval(threadID))
        )
    }

    private func corruptGenerations(_ file: SecureCodableFile<ContentDraftPersistenceState>) throws {
        for url in [file.fileURL, file.backupURL] {
            try Data("corrupt".utf8).write(to: url, options: .atomic)
        }
    }

    private func corruptCatalogGenerations(in directory: URL) throws {
        for name in [
            "content-drafts-catalog.json",
            "content-drafts-catalog.json.backup"
        ] {
            let url = directory.appendingPathComponent(name)
            try Data("corrupt".utf8).write(to: url, options: .atomic)
        }
    }

    @MainActor
    func testVerifiedMigrationCommitsAuthorityAndNeverRechecksRetainedSource() async throws {
        let directory = try makeDirectory()
        let stateFile = try ContentDraftPersistenceFactory.makeStateFile(
            directoryURL: directory
        )
        try stateFile.replace(.activeFiles)
        let source = try FileContentDraftPersistenceBackend(directoryURL: directory)
        let sourceStore = ContentDraftStore(persistence: source)
        let first = makeDraft(threadID: 1, marker: 1)
        let second = makeDraft(threadID: 2, marker: 2)
        XCTAssertTrue(sourceStore.save(first))
        XCTAssertTrue(sourceStore.save(second))
        let sourceBlobNames = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("content-draft-blobs", isDirectory: true),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)

        let destination = SwiftDataContentDraftPersistenceBackend(
            modelContainer: try makeContainer()
        )
        let migrating = MigratingContentDraftPersistenceBackend(
            source: source,
            destination: destination,
            stateFile: stateFile,
            now: { Date(timeIntervalSinceReferenceDate: 10) }
        )
        let migrationOutcome = await ContentDraftStore(persistence: migrating).loadAsync(
            accountID: "account",
            target: first.target
        )
        XCTAssertEqual(migrationOutcome, .loaded(first))

        let state = try XCTUnwrap(stateFile.load())
        XCTAssertEqual(state.activeBackend, .swiftData)
        XCTAssertEqual(state.migrationStatus, .completed)
        XCTAssertEqual(state.receipt?.completedAt, Date(timeIntervalSinceReferenceDate: 10))
        XCTAssertEqual(destination.draft(accountID: "account", target: second.target), second)
        for name in sourceBlobNames {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent("content-draft-blobs", isDirectory: true)
                    .appendingPathComponent(name).path
            ))
        }

        let destinationOnly = makeDraft(threadID: 3, marker: 3)
        XCTAssertTrue(destination.save(destinationOnly))
        try corruptCatalogGenerations(in: directory)

        let resolved = try ContentDraftPersistenceFactory.resolveIOS17Backend(
            directoryURL: directory,
            swiftDataBackend: destination
        )
        XCTAssertEqual(
            resolved.draft(accountID: "account", target: destinationOnly.target),
            destinationOnly
        )
        XCTAssertEqual(
            try stateFile.load()?.receipt?.completedAt,
            Date(timeIntervalSinceReferenceDate: 10)
        )
    }

    @MainActor
    func testStateCommitFailureLeavesSourceActiveAndRetryClearsPartialDestination() async throws {
        let directory = try makeDirectory()
        let stateFile = try ContentDraftPersistenceFactory.makeStateFile(
            directoryURL: directory
        )
        try stateFile.replace(.activeFiles)
        let source = try FileContentDraftPersistenceBackend(directoryURL: directory)
        let draft = makeDraft(threadID: 1, marker: 1)
        XCTAssertTrue(source.save(draft))
        let destination = SwiftDataContentDraftPersistenceBackend(
            modelContainer: try makeContainer()
        )
        let failing = MigratingContentDraftPersistenceBackend(
            source: source,
            destination: destination,
            stateFile: stateFile,
            beforeStateCommit: { throw InjectedFailure.stateCommit }
        )

        let failedCommitOutcome = await failing.loadAsync(
            accountID: "account",
            target: draft.target
        )
        XCTAssertEqual(failedCommitOutcome, .loaded(draft))
        XCTAssertEqual(try stateFile.load(), ContentDraftPersistenceState.activeFiles)
        XCTAssertEqual(destination.draft(accountID: "account", target: draft.target), draft)

        let partialOnly = makeDraft(threadID: 9, marker: 9)
        XCTAssertTrue(destination.save(partialOnly))
        let retry = MigratingContentDraftPersistenceBackend(
            source: source,
            destination: destination,
            stateFile: stateFile
        )
        let retryOutcome = await retry.loadAsync(
            accountID: "account",
            target: draft.target
        )
        XCTAssertEqual(retryOutcome, .loaded(draft))
        XCTAssertNil(destination.draft(accountID: "account", target: partialOnly.target))
        XCTAssertEqual(try stateFile.load()?.activeBackend, .swiftData)
    }

    @MainActor
    func testCancelledWaiterDoesNotCancelSharedMigration() async throws {
        let directory = try makeDirectory()
        let stateFile = try ContentDraftPersistenceFactory.makeStateFile(
            directoryURL: directory
        )
        try stateFile.replace(.activeFiles)
        let source = try FileContentDraftPersistenceBackend(directoryURL: directory)
        let draft = makeDraft(threadID: 1, marker: 1)
        XCTAssertTrue(source.save(draft))
        let destination = SwiftDataContentDraftPersistenceBackend(
            modelContainer: try makeContainer()
        )
        let gate = MigrationGate()
        let migrating = MigratingContentDraftPersistenceBackend(
            source: source,
            destination: destination,
            stateFile: stateFile,
            beforeRecordRead: { _ in try await gate.pause() }
        )

        let task = Task { @MainActor in
            await migrating.loadAsync(accountID: "account", target: draft.target)
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        let cancelledOutcome = await task.value
        XCTAssertEqual(cancelledOutcome, .unavailable)
        XCTAssertEqual(try stateFile.load()?.activeBackend, .swiftData)
        XCTAssertEqual(destination.draft(accountID: "account", target: draft.target), draft)

        let subsequentOutcome = await migrating.loadAsync(
            accountID: "account",
            target: draft.target
        )
        XCTAssertEqual(subsequentOutcome, .loaded(draft))
    }

    @MainActor
    func testConcurrentResolversSerializeAndSecondDoesNotReplayAfterCommit() async throws {
        let directory = try makeDirectory()
        let stateFile = try ContentDraftPersistenceFactory.makeStateFile(
            directoryURL: directory
        )
        try stateFile.replace(.activeFiles)
        let source = try FileContentDraftPersistenceBackend(directoryURL: directory)
        let draft = makeDraft(threadID: 1, marker: 1)
        XCTAssertTrue(source.save(draft))
        let destination = SwiftDataContentDraftPersistenceBackend(
            modelContainer: try makeContainer()
        )
        let firstGate = MigrationGate()
        let secondReads = InvocationCounter()
        let first = MigratingContentDraftPersistenceBackend(
            source: source,
            destination: destination,
            stateFile: stateFile,
            beforeRecordRead: { _ in try await firstGate.pause() }
        )
        let second = MigratingContentDraftPersistenceBackend(
            source: source,
            destination: destination,
            stateFile: stateFile,
            beforeRecordRead: { _ in await secondReads.increment() }
        )

        let firstTask = Task { @MainActor in
            await first.loadAsync(accountID: "account", target: draft.target)
        }
        await firstGate.waitUntilEntered()
        let secondTask = Task { @MainActor in
            await second.loadAsync(accountID: "account", target: draft.target)
        }
        await firstGate.release()

        let firstOutcome = await firstTask.value
        let secondOutcome = await secondTask.value
        let secondReadCount = await secondReads.count
        XCTAssertEqual(firstOutcome, .loaded(draft))
        XCTAssertEqual(secondOutcome, .loaded(draft))
        XCTAssertEqual(secondReadCount, 0)
        XCTAssertEqual(try stateFile.load()?.activeBackend, .swiftData)
    }

    @MainActor
    func testMissingStateBesideFileCatalogFailsClosedInsteadOfChoosingEitherBackend() throws {
        let directory = try makeDirectory()
        let source = try FileContentDraftPersistenceBackend(directoryURL: directory)
        XCTAssertTrue(source.save(makeDraft(threadID: 1, marker: 1)))
        let destination = SwiftDataContentDraftPersistenceBackend(
            modelContainer: try makeContainer()
        )
        XCTAssertTrue(destination.save(makeDraft(threadID: 2, marker: 2)))

        XCTAssertThrowsError(try ContentDraftPersistenceFactory.resolveIOS17Backend(
            directoryURL: directory,
            swiftDataBackend: destination
        )) { error in
            XCTAssertEqual(error as? ContentDraftPersistenceStateError, .ambiguousBackends)
        }
    }

    @MainActor
    func testCorruptStateFailsClosedBeforeInspectingEitherBackend() throws {
        let directory = try makeDirectory()
        let stateFile = try ContentDraftPersistenceFactory.makeStateFile(
            directoryURL: directory
        )
        try stateFile.replace(.activeFiles)
        try corruptGenerations(stateFile)
        let destination = SwiftDataContentDraftPersistenceBackend(
            modelContainer: try makeContainer()
        )

        XCTAssertThrowsError(try ContentDraftPersistenceFactory.resolveIOS17Backend(
            directoryURL: directory,
            swiftDataBackend: destination
        ))
    }

    @MainActor
    func testCorruptFileCatalogWithoutStateCannotFallBackToEmptySwiftData() throws {
        let directory = try makeDirectory()
        let catalogURL = directory.appendingPathComponent("content-drafts-catalog.json")
        try Data("corrupt".utf8).write(to: catalogURL, options: .atomic)
        let destination = SwiftDataContentDraftPersistenceBackend(
            modelContainer: try makeContainer()
        )

        XCTAssertThrowsError(try ContentDraftPersistenceFactory.resolveIOS17Backend(
            directoryURL: directory,
            swiftDataBackend: destination
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(
                ContentDraftPersistenceFactory.stateFileName
            ).path
        ))
    }

    @MainActor
    func testCompletedStateWithUnavailableDestinationNeverFallsBackToRetainedSource() throws {
        let directory = try makeDirectory()
        let stateFile = try ContentDraftPersistenceFactory.makeStateFile(
            directoryURL: directory
        )
        try stateFile.replace(.migrated(
            sourceFingerprint: String(repeating: "a", count: 64),
            generationID: "11111111-1111-1111-1111-111111111111",
            completedAt: Date(timeIntervalSinceReferenceDate: 1)
        ))
        let source = try FileContentDraftPersistenceBackend(directoryURL: directory)
        let retainedOnly = makeDraft(threadID: 1, marker: 1)
        XCTAssertTrue(source.save(retainedOnly))
        let unavailableDestination = SwiftDataContentDraftPersistenceBackend(
            modelContainer: try makeContainer(),
            persistenceAvailability: .unavailable
        )

        XCTAssertThrowsError(try ContentDraftPersistenceFactory.resolveIOS17Backend(
            directoryURL: directory,
            swiftDataBackend: unavailableDestination
        ))
        XCTAssertEqual(source.draft(accountID: "account", target: retainedOnly.target), retainedOnly)
    }

    @MainActor
    func testFreshBootstrapAndLegitimateClearKeepDestinationMarkerAuthoritative() throws {
        let directory = try makeDirectory()
        let destination = SwiftDataContentDraftPersistenceBackend(
            modelContainer: try makeContainer()
        )
        let draft = makeDraft(threadID: 1, marker: 1)
        XCTAssertTrue(destination.save(draft))

        let resolved = try ContentDraftPersistenceFactory.resolveIOS17Backend(
            directoryURL: directory,
            swiftDataBackend: destination
        )
        XCTAssertEqual(resolved.draft(accountID: "account", target: draft.target), draft)
        let stateFile = try ContentDraftPersistenceFactory.makeStateFile(
            directoryURL: directory
        )
        let state = try XCTUnwrap(stateFile.load())
        XCTAssertEqual(state.activeBackend, .swiftData)
        XCTAssertEqual(state.migrationStatus, .notRequired)
        XCTAssertEqual(try destination.backendGenerationID(), state.destinationGenerationID)

        XCTAssertTrue(resolved.clear(accountID: "account"))
        XCTAssertNil(destination.draft(accountID: "account", target: draft.target))
        let afterLegitimateClear = try ContentDraftPersistenceFactory.resolveIOS17Backend(
            directoryURL: directory,
            swiftDataBackend: destination
        )
        XCTAssertNil(afterLegitimateClear.draft(accountID: "account", target: draft.target))
        XCTAssertEqual(try destination.backendGenerationID(), state.destinationGenerationID)
    }

    @MainActor
    func testActiveSwiftDataStateAdoptsCommittedGenerationWhenDatabaseWasRebuiltWithoutMarker() throws {
        let directory = try makeDirectory()
        let original = SwiftDataContentDraftPersistenceBackend(
            modelContainer: try makeContainer()
        )
        _ = try ContentDraftPersistenceFactory.resolveIOS17Backend(
            directoryURL: directory,
            swiftDataBackend: original
        )
        let committedGeneration = try XCTUnwrap(original.backendGenerationID())
        let rebuilt = SwiftDataContentDraftPersistenceBackend(
            modelContainer: try makeContainer()
        )

        XCTAssertNil(try rebuilt.backendGenerationID())
        let adopted = try ContentDraftPersistenceFactory.resolveIOS17Backend(
            directoryURL: directory,
            swiftDataBackend: rebuilt
        )

        // The state file is the backend-selection commit point and the marker is
        // only the store's copy of the same token: a database that lost its own
        // marker is claimed by the committed generation instead of refusing
        // every draft read for the rest of the install.
        XCTAssertTrue(adopted === rebuilt)
        XCTAssertEqual(try rebuilt.backendGenerationID(), committedGeneration)
    }

    @MainActor
    func testActiveSwiftDataStateAdoptsCommittedStateOverStaleMarkerGeneration() throws {
        let directory = try makeDirectory()
        let stateFile = try ContentDraftPersistenceFactory.makeStateFile(
            directoryURL: directory
        )
        let committedGeneration = "11111111-1111-1111-1111-111111111111"
        try stateFile.replace(.initialSwiftData(
            generationID: committedGeneration
        ))
        let destination = SwiftDataContentDraftPersistenceBackend(
            modelContainer: try makeContainer()
        )
        let staleGeneration = UUID().uuidString.lowercased()
        try destination.installNativeBackendMarker(generationID: staleGeneration)
        XCTAssertNotEqual(staleGeneration, committedGeneration)

        _ = try ContentDraftPersistenceFactory.resolveIOS17Backend(
            directoryURL: directory,
            swiftDataBackend: destination
        )

        XCTAssertEqual(try destination.backendGenerationID(), committedGeneration)
    }

    @MainActor
    func testNativeActivationPendingRetriesBeforeMarkerWrite() throws {
        let directory = try makeDirectory()
        let generationID = "11111111-1111-1111-1111-111111111111"
        let stateFile = try ContentDraftPersistenceFactory.makeStateFile(
            directoryURL: directory
        )
        try stateFile.replace(.nativeActivationPending(generationID: generationID))
        let destination = SwiftDataContentDraftPersistenceBackend(
            modelContainer: try makeContainer()
        )
        XCTAssertNil(try destination.backendGenerationID())

        _ = try ContentDraftPersistenceFactory.resolveIOS17Backend(
            directoryURL: directory,
            swiftDataBackend: destination
        )
        XCTAssertEqual(try destination.backendGenerationID(), generationID)
        let state = try XCTUnwrap(stateFile.load())
        XCTAssertEqual(state.activeBackend, .swiftData)
        XCTAssertEqual(state.destinationGenerationID, generationID)
    }

    @MainActor
    func testNativeActivationPendingRetriesAfterMarkerWrite() throws {
        let directory = try makeDirectory()
        let generationID = "22222222-2222-2222-2222-222222222222"
        let stateFile = try ContentDraftPersistenceFactory.makeStateFile(
            directoryURL: directory
        )
        try stateFile.replace(.nativeActivationPending(generationID: generationID))
        let destination = SwiftDataContentDraftPersistenceBackend(
            modelContainer: try makeContainer()
        )
        try destination.installNativeBackendMarker(generationID: generationID)

        _ = try ContentDraftPersistenceFactory.resolveIOS17Backend(
            directoryURL: directory,
            swiftDataBackend: destination
        )
        let state = try XCTUnwrap(stateFile.load())
        XCTAssertEqual(state.activeBackend, .swiftData)
        XCTAssertEqual(state.destinationGenerationID, generationID)
    }

    @MainActor
    func testMissingStateWithExistingDestinationMarkerReelectsBackendKeepingDrafts() throws {
        let directory = try makeDirectory()
        let destination = SwiftDataContentDraftPersistenceBackend(
            modelContainer: try makeContainer()
        )
        let staleGeneration = "33333333-3333-3333-3333-333333333333"
        try destination.installNativeBackendMarker(generationID: staleGeneration)
        let draft = makeDraft(threadID: 7, marker: 7)
        XCTAssertTrue(destination.save(draft))
        let stateFile = try ContentDraftPersistenceFactory.makeStateFile(
            directoryURL: directory
        )
        try stateFile.replace(.initialSwiftData(generationID: staleGeneration))
        try FileManager.default.removeItem(at: stateFile.fileURL)
        try FileManager.default.removeItem(at: stateFile.backupURL)

        let resolved = try ContentDraftPersistenceFactory.resolveIOS17Backend(
            directoryURL: directory,
            swiftDataBackend: destination
        )

        // The marker is only the store's copy of the backend token: with the
        // state file gone the election is redone over the leftover marker, and
        // the drafts already in the database stay readable.
        XCTAssertTrue(resolved === destination)
        XCTAssertNotEqual(try destination.backendGenerationID(), staleGeneration)
        XCTAssertEqual(resolved.draft(accountID: "account", target: draft.target), draft)
        XCTAssertEqual(try stateFile.load()?.activeBackend, .swiftData)
        XCTAssertEqual(
            try stateFile.load()?.destinationGenerationID,
            try destination.backendGenerationID()
        )
    }

    @MainActor
    func testTransientSwiftDataFailureOnFirstLaunchDoesNotElectEmptyFileBackend() throws {
        let directory = try makeDirectory()
        let container = try makeContainer()
        let available = SwiftDataContentDraftPersistenceBackend(modelContainer: container)
        let draft = makeDraft(threadID: 1, marker: 1)
        XCTAssertTrue(available.save(draft))
        let transientFallback = SwiftDataContentDraftPersistenceBackend(
            modelContainer: container,
            persistenceAvailability: .unavailable
        )

        XCTAssertThrowsError(try ContentDraftPersistenceFactory.resolveIOS17Backend(
            directoryURL: directory,
            swiftDataBackend: transientFallback
        ))
        let stateFile = try ContentDraftPersistenceFactory.makeStateFile(
            directoryURL: directory
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile.backupURL.path))

        let recovered = SwiftDataContentDraftPersistenceBackend(modelContainer: container)
        let resolved = try ContentDraftPersistenceFactory.resolveIOS17Backend(
            directoryURL: directory,
            swiftDataBackend: recovered
        )
        XCTAssertEqual(resolved.draft(accountID: "account", target: draft.target), draft)
        XCTAssertEqual(try stateFile.load()?.activeBackend, .swiftData)
    }
}
