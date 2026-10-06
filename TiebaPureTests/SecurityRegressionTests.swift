import SwiftProtobuf
import XCTest
@testable import TiebaPure

final class SecurityRegressionTests: XCTestCase {
    override func tearDown() {
        SecurityURLProtocol.payload = Data()
        SecurityURLProtocol.chunks = nil
        SecurityURLProtocol.mimeType = "application/octet-stream"
        SecurityURLProtocol.delay = 0
        SecurityURLProtocol.chunkDelay = 0
        SecurityURLProtocol.declaredContentLength = nil
        SecurityURLProtocol.resetMetrics()
        super.tearDown()
    }

    func testKeychainUpdatesExistingItemWithoutDeleteFirst() async throws {
        let securityOperations = InMemoryKeychainSecurityOperations()
        let service = KeychainAccountStoreService(
            service: "dev.infinityf4p.tiebapure.tests.\(UUID().uuidString)",
            account: "update",
            securityOperations: securityOperations
        )
        try await service.saveData(Data("first".utf8))
        try await service.saveData(Data("second".utf8))
        let loaded = try await service.loadData()

        XCTAssertEqual(loaded, Data("second".utf8))
        XCTAssertEqual(securityOperations.calls, [.update, .add, .update, .copy])
        XCTAssertFalse(securityOperations.calls.contains(.delete))

        try await service.clearData()
        XCTAssertEqual(securityOperations.calls.last, .delete)
    }

    func testAccountEncodingDoesNotPersistCompleteCookieField() throws {
        let account = FixtureTiebaAPI.account
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(account), encoding: .utf8))
        XCTAssertFalse(json.contains("\"cookie\""))
        XCTAssertFalse(json.contains("Cookie:"))
    }

    @MainActor
    func testCancellationDuringAccountSaveRollsBackWithoutPublishingLogin() async throws {
        let service = ControlledSaveAccountStoreService()
        let store = AccountStore(service: service)
        var publishedAccounts: [Account] = []
        let observation = store.accountDidChange.compactMap { $0 }.sink {
            publishedAccounts.append($0)
        }

        let saveTask = Task {
            try await store.save(FixtureTiebaAPI.account)
        }
        for _ in 0..<200 {
            if await service.hasPendingSave() { break }
            await Task.yield()
        }
        let didStartSaving = await service.hasPendingSave()
        XCTAssertTrue(didStartSaving)

        saveTask.cancel()
        await service.finishPendingSave()
        do {
            try await saveTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }

        let persisted = try await store.load()
        XCTAssertNil(persisted)
        XCTAssertTrue(publishedAccounts.isEmpty)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testPublishedLoginRemainsSavedWhenSheetDismissalCancelsValidationTask() async throws {
        let store = AccountStore(service: MemoryAccountStoreService())
        var saveTask: Task<Void, Error>?
        let observation = store.accountDidChange.sink { account in
            if account != nil {
                saveTask?.cancel()
            }
        }

        saveTask = Task {
            try await store.save(FixtureTiebaAPI.account)
        }
        try await saveTask?.value

        let persistedAccount = try await store.load()
        XCTAssertEqual(persistedAccount, FixtureTiebaAPI.account)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testCancelledSaveNeverRestoresUnsafePreviousCredentials() async throws {
        var unsafeAccount = FixtureTiebaAPI.account
        unsafeAccount.stoken = "unsafe; INJECTED=true"
        let service = ControlledSaveAccountStoreService(
            data: try JSONEncoder().encode(unsafeAccount)
        )
        let store = AccountStore(service: service)

        let saveTask = Task {
            try await store.save(FixtureTiebaAPI.account)
        }
        for _ in 0..<200 {
            if await service.hasPendingSave() { break }
            await Task.yield()
        }
        let didStartSaving = await service.hasPendingSave()
        XCTAssertTrue(didStartSaving)

        saveTask.cancel()
        await service.finishPendingSave()
        do {
            try await saveTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }

        let remainingData = try await service.loadData()
        XCTAssertNil(remainingData)
    }

    func testBoundedResponseRejectsDeclaredOverflow() async throws {
        SecurityURLProtocol.payload = Data(repeating: 0x41, count: 9)
        SecurityURLProtocol.declaredContentLength = 9
        let loader = BoundedURLSession(session: Self.session())
        do {
            _ = try await loader.data(for: URLRequest(url: URL(string: "https://example.com/large")!), maximumBytes: 8)
            XCTFail("Expected response cap")
        } catch {
            XCTAssertEqual(error as? TiebaHTTPError, .responseTooLarge(limit: 8))
        }
    }

    func testBoundedResponseRejectsAccumulatedOverflowWithoutDeclaredLength() async throws {
        SecurityURLProtocol.payload = Data(repeating: 0x41, count: 64 * 1_024)
        SecurityURLProtocol.declaredContentLength = nil
        let loader = BoundedURLSession(session: Self.session())
        do {
            _ = try await loader.data(
                for: URLRequest(url: URL(string: "https://example.com/chunked")!),
                maximumBytes: 8
            )
            XCTFail("Expected streamed response cap")
        } catch {
            XCTAssertEqual(error as? TiebaHTTPError, .responseTooLarge(limit: 8))
        }
    }

    func testBoundedResponseReportsMonotonicProgressForChunkedResponse() async throws {
        let chunkSize = 64 * 1_024
        SecurityURLProtocol.chunks = [
            Data(repeating: 0x41, count: chunkSize),
            Data(repeating: 0x42, count: chunkSize),
            Data(repeating: 0x43, count: chunkSize)
        ]
        SecurityURLProtocol.declaredContentLength = chunkSize * 3
        SecurityURLProtocol.chunkDelay = 0.02
        let recorder = ProgressRecorder()
        let loader = BoundedURLSession(session: Self.session())

        let (data, _) = try await loader.data(
            for: URLRequest(url: URL(string: "https://example.com/progress")!),
            maximumBytes: chunkSize * 4,
            onProgress: { progress in
                await recorder.record(progress)
            }
        )

        let progress = await recorder.values()
        XCTAssertEqual(data.count, chunkSize * 3)
        XCTAssertEqual(progress.first, .init(receivedBytes: 0, expectedBytes: chunkSize * 3))
        XCTAssertEqual(progress.last, .init(receivedBytes: chunkSize * 3, expectedBytes: chunkSize * 3))
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy {
            $0.receivedBytes <= $1.receivedBytes
        })
        XCTAssertTrue(progress.allSatisfy { $0.expectedBytes == chunkSize * 3 })
    }

    func testBoundedResponseDoesNotReportProgressPastStreamedLimit() async throws {
        let chunkSize = 64 * 1_024
        SecurityURLProtocol.chunks = [
            Data(repeating: 0x41, count: chunkSize),
            Data(repeating: 0x42, count: chunkSize)
        ]
        SecurityURLProtocol.declaredContentLength = nil
        SecurityURLProtocol.chunkDelay = 0.02
        let recorder = ProgressRecorder()
        let loader = BoundedURLSession(session: Self.session())
        let limit = 100_000

        do {
            _ = try await loader.data(
                for: URLRequest(url: URL(string: "https://example.com/progress-overflow")!),
                maximumBytes: limit,
                onProgress: { progress in
                    await recorder.record(progress)
                }
            )
            XCTFail("Expected streamed response cap")
        } catch {
            XCTAssertEqual(error as? TiebaHTTPError, .responseTooLarge(limit: limit))
        }

        let progress = await recorder.values()
        XCTAssertEqual(progress.first?.receivedBytes, 0)
        XCTAssertTrue(progress.allSatisfy { $0.receivedBytes <= limit })
        XCTAssertEqual(progress.last?.receivedBytes, chunkSize)
    }

    func testBoundedResponseCancellationStopsFurtherProgressUpdates() async throws {
        let chunkSize = 64 * 1_024
        SecurityURLProtocol.chunks = [
            Data(repeating: 0x41, count: chunkSize),
            Data(repeating: 0x42, count: chunkSize),
            Data(repeating: 0x43, count: chunkSize)
        ]
        SecurityURLProtocol.declaredContentLength = chunkSize * 3
        SecurityURLProtocol.chunkDelay = 0.25
        let recorder = ProgressRecorder()
        let loader = BoundedURLSession(session: Self.session())
        let task = Task {
            try await loader.data(
                for: URLRequest(url: URL(string: "https://example.com/progress-cancel")!),
                maximumBytes: chunkSize * 4,
                onProgress: { progress in
                    await recorder.record(progress)
                }
            )
        }

        await recorder.waitForPositiveProgress()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }

        let progressAtCancellation = await recorder.values()
        try await Task.sleep(nanoseconds: 600_000_000)
        let progressAfterCancellation = await recorder.values()
        XCTAssertEqual(progressAfterCancellation, progressAtCancellation)
    }

    func testImageMIMEValidationRejectsNonImageResponse() async throws {
        SecurityURLProtocol.payload = Data("not an image".utf8)
        SecurityURLProtocol.mimeType = "text/html"
        let loader = BoundedURLSession(session: Self.session())
        do {
            _ = try await loader.data(
                for: URLRequest(url: URL(string: "https://example.com/image")!),
                maximumBytes: 100,
                requiredMIMEPrefix: "image/"
            )
            XCTFail("Expected MIME rejection")
        } catch {
            XCTAssertEqual(error as? TiebaHTTPError, .invalidMIMEType("text/html"))
        }
    }

    func testImageMetadataUsesBodyFreeHeadWithoutRangeFallback() async throws {
        SecurityURLProtocol.payload = Data()
        SecurityURLProtocol.mimeType = "image/jpeg"
        SecurityURLProtocol.declaredContentLength = 3_670_016
        let client = TiebaImageMetadataClient(
            session: Self.session(),
            redirectScope: .publicHTTPS
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/original.jpg"))

        let contentLength = try await client.contentLength(from: url)

        XCTAssertEqual(contentLength, 3_670_016)
        XCTAssertEqual(SecurityURLProtocol.startCount, 1)
        XCTAssertEqual(SecurityURLProtocol.lastRequestMethod, "HEAD")
        XCTAssertNil(SecurityURLProtocol.lastRangeHeader)
    }

    func testAnimatedImageProbeReadsTheContentTypeFromABodyFreeHead() async throws {
        SecurityURLProtocol.payload = Data()
        SecurityURLProtocol.mimeType = "image/gif"
        SecurityURLProtocol.declaredContentLength = 3_670_016
        let client = TiebaImageMetadataClient(
            session: Self.session(),
            redirectScope: .publicHTTPS
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/original.jpg"))

        let animated = try await client.isAnimatedImage(at: url)

        XCTAssertTrue(animated)
        XCTAssertEqual(SecurityURLProtocol.lastRequestMethod, "HEAD")
        XCTAssertNil(SecurityURLProtocol.lastRangeHeader)

        SecurityURLProtocol.mimeType = "image/jpeg"
        let still = try await client.isAnimatedImage(at: url)
        XCTAssertFalse(still)
    }

    func testImageDecodePolicyRejectsPixelBombDimensions() {
        XCTAssertTrue(TiebaImageDecodePolicy.allows(width: 4_096, height: 4_096))
        XCTAssertEqual(TiebaImageDecodePolicy.maximumPreviewDecodedPixelSize, 2_560)
        XCTAssertEqual(TiebaImageDecodePolicy.maximumPreviewDisplayScale, 3)
        XCTAssertEqual(
            TiebaImageDecodePolicy.previewTargetPixelSize(
                for: CGSize(width: 36, height: 36),
                displayScale: 3
            ),
            128
        )
        XCTAssertEqual(
            TiebaImageDecodePolicy.previewTargetPixelSize(
                for: CGSize(width: 180, height: 120),
                displayScale: 3
            ),
            640
        )
        XCTAssertEqual(
            TiebaImageDecodePolicy.previewTargetPixelSize(
                for: CGSize(width: 1_024, height: 768),
                displayScale: 3
            ),
            2_560
        )
        XCTAssertFalse(TiebaImageDecodePolicy.allows(width: 100_000, height: 1))
        XCTAssertFalse(TiebaImageDecodePolicy.allows(width: 20_000, height: 20_000))
        XCTAssertFalse(TiebaImageDecodePolicy.allows(width: Int.max, height: 2))
    }

    @MainActor
    func testImagePipelineDownsamplesEachRequestedPreviewTier() async throws {
        SecurityURLProtocol.payload = try XCTUnwrap(Self.largePNGData())
        SecurityURLProtocol.mimeType = "image/png"
        let pipeline = Self.imagePipeline()
        let url = try XCTUnwrap(URL(string: "https://example.com/large-preview.png"))

        let small = try await pipeline.image(from: [url], targetPixelSize: 128)
        let medium = try await pipeline.image(from: [url], targetPixelSize: 512)

        XCTAssertLessThanOrEqual(max(
            try XCTUnwrap(small.cgImage).width,
            try XCTUnwrap(small.cgImage).height
        ), 128)
        XCTAssertLessThanOrEqual(max(
            try XCTUnwrap(medium.cgImage).width,
            try XCTUnwrap(medium.cgImage).height
        ), 512)
        XCTAssertGreaterThan(
            max(try XCTUnwrap(medium.cgImage).width, try XCTUnwrap(medium.cgImage).height),
            max(try XCTUnwrap(small.cgImage).width, try XCTUnwrap(small.cgImage).height)
        )
        XCTAssertEqual(SecurityURLProtocol.startCount, 2)
    }

    func testImagePipelineCancelsDownloadAfterLastWaiterLeaves() async throws {
        SecurityURLProtocol.payload = Self.onePixelPNGData
        SecurityURLProtocol.mimeType = "image/png"
        SecurityURLProtocol.delay = 5
        let pipeline = Self.imagePipeline()
        let url = try XCTUnwrap(URL(string: "https://example.com/cancelled-preview.png"))
        let task = Task {
            try await pipeline.image(from: [url], targetPixelSize: 128)
        }

        try await Self.waitForImageRequestStart()
        task.cancel()
        try await Self.waitForImageRequestStop()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        XCTAssertEqual(SecurityURLProtocol.startCount, 1)
        XCTAssertEqual(SecurityURLProtocol.stopCount, 1)
    }

    @MainActor
    func testImagePipelineKeepsSharedDownloadUntilEveryWaiterLeaves() async throws {
        SecurityURLProtocol.payload = Self.onePixelPNGData
        SecurityURLProtocol.mimeType = "image/png"
        SecurityURLProtocol.delay = 1
        let pipeline = Self.imagePipeline()
        let url = try XCTUnwrap(URL(string: "https://example.com/shared-preview.png"))
        let first = Task {
            try await pipeline.image(from: [url], targetPixelSize: 128)
        }
        let second = Task {
            try await pipeline.image(from: [url], targetPixelSize: 128)
        }

        try await Self.waitForImageWaiterCount(2, pipeline: pipeline)
        first.cancel()
        let cancelled = expectation(description: "Cancelled waiter returns before shared response")
        Task {
            do {
                _ = try await first.value
                XCTFail("Cancelled waiter unexpectedly succeeded")
                cancelled.fulfill()
            } catch is CancellationError {
                cancelled.fulfill()
            } catch let error as URLError where error.code == .cancelled {
                cancelled.fulfill()
            } catch {
                XCTFail("Unexpected cancellation error: \(error)")
            }
        }

        await fulfillment(of: [cancelled], timeout: 0.4)
        XCTAssertEqual(SecurityURLProtocol.stopCount, 0)
        let remainingWaiters = await pipeline.inFlightWaiterCountForTesting()
        XCTAssertEqual(remainingWaiters, 1)

        let image = try await second.value
        XCTAssertNotNil(image.cgImage)
        XCTAssertEqual(SecurityURLProtocol.startCount, 1)
    }

    func testImageDownloadValidatesDataAndUsesDetectedFileType() async throws {
        SecurityURLProtocol.payload = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        SecurityURLProtocol.mimeType = "image/png"
        let client = TiebaImageDownloadClient(
            session: Self.session(),
            redirectScope: .publicHTTPS
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/original.jpg"))

        let payload = try await client.download(from: url)

        XCTAssertEqual(payload.data, SecurityURLProtocol.payload)
        XCTAssertEqual(payload.mimeType, "image/png")
        XCTAssertEqual(payload.fileName, "original.png")
    }

    func testImageDownloadUpgradesInsecureSourceAndStillRejectsPrivateTargets() async throws {
        SecurityURLProtocol.payload = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        SecurityURLProtocol.mimeType = "image/png"
        let client = TiebaImageDownloadClient(
            session: Self.session(),
            redirectScope: .publicHTTPS
        )
        let url = try XCTUnwrap(URL(string: "http://example.com/original.jpg"))

        // A legacy http source is upgraded to https instead of being dropped;
        // nothing is ever fetched over plain http.
        let payload = try await client.download(from: url)
        XCTAssertEqual(payload.data, SecurityURLProtocol.payload)
        XCTAssertEqual(SecurityURLProtocol.lastRequestURL?.scheme, "https")

        for rejected in ["http://127.0.0.1/original.jpg", "file:///tmp/original.jpg"] {
            let rejectedURL = try XCTUnwrap(URL(string: rejected))
            do {
                _ = try await client.download(from: rejectedURL)
                XCTFail("Expected rejection for \(rejected)")
            } catch {
                XCTAssertEqual(error as? TiebaImageDownloadError, .invalidURL)
            }
        }
    }

    func testVideoDownloadStreamsTrustedMP4ToLeaseAndReleaseDeletesFile() async throws {
        SecurityURLProtocol.payload = Data(repeating: 0x5a, count: 128 * 1_024)
        SecurityURLProtocol.mimeType = "video/mp4"
        let directory = try Self.makeVideoTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = TiebaVideoDownloadClient(
            configuration: Self.sessionConfiguration(),
            maximumBytes: 256 * 1_024,
            temporaryDirectory: directory
        )
        let source = try XCTUnwrap(URL(
            string: "https://tb-video.bdstatic.com/tieba-smallvideo/demo.mp4"
        ))

        let lease = try await client.download(from: source)

        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: lease.fileURL), SecurityURLProtocol.payload)
        lease.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.fileURL.path))
    }

    func testVideoDownloadRejectsDeclaredAndCumulativeOversizeAndCleansFiles() async throws {
        let source = try XCTUnwrap(URL(
            string: "https://tb-video.bdstatic.com/tieba-smallvideo/oversize.mp4"
        ))

        for usesDeclaredLength in [true, false] {
            SecurityURLProtocol.payload = Data(repeating: 0x4d, count: 9)
            SecurityURLProtocol.chunks = usesDeclaredLength
                ? nil
                : [Data(repeating: 0x4d, count: 4), Data(repeating: 0x4e, count: 5)]
            SecurityURLProtocol.chunkDelay = usesDeclaredLength ? 0 : 0.01
            SecurityURLProtocol.mimeType = "video/mp4"
            SecurityURLProtocol.declaredContentLength = usesDeclaredLength ? 9 : nil
            let directory = try Self.makeVideoTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = TiebaVideoDownloadClient(
                configuration: Self.sessionConfiguration(),
                maximumBytes: 8,
                temporaryDirectory: directory
            )

            do {
                _ = try await client.download(from: source)
                XCTFail("Expected video size rejection")
            } catch {
                XCTAssertEqual(
                    error as? TiebaVideoDownloadError,
                    .responseTooLarge(limit: 8)
                )
            }
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: directory.path),
                []
            )
            SecurityURLProtocol.chunks = nil
            SecurityURLProtocol.chunkDelay = 0
            SecurityURLProtocol.declaredContentLength = nil
        }
    }

    func testVideoDownloadRejectsNonVideoMIMEAndCleansFile() async throws {
        SecurityURLProtocol.payload = Data("not video".utf8)
        SecurityURLProtocol.mimeType = "text/html"
        let directory = try Self.makeVideoTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = TiebaVideoDownloadClient(
            configuration: Self.sessionConfiguration(),
            temporaryDirectory: directory
        )
        let source = try XCTUnwrap(URL(
            string: "https://tb-video.bdstatic.com/tieba-smallvideo/not-video.mp4"
        ))

        do {
            _ = try await client.download(from: source)
            XCTFail("Expected video MIME rejection")
        } catch {
            XCTAssertEqual(
                error as? TiebaVideoDownloadError,
                .invalidMIMEType("text/html")
            )
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testCancellingVideoDownloadStopsRequestAndCleansTemporaryFile() async throws {
        SecurityURLProtocol.payload = Data(repeating: 0x5a, count: 1_024)
        SecurityURLProtocol.mimeType = "video/mp4"
        SecurityURLProtocol.delay = 5
        let directory = try Self.makeVideoTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = TiebaVideoDownloadClient(
            configuration: Self.sessionConfiguration(),
            temporaryDirectory: directory
        )
        let source = try XCTUnwrap(URL(
            string: "https://tb-video.bdstatic.com/tieba-smallvideo/cancel.mp4"
        ))
        let task = Task {
            try await client.download(from: source)
        }

        try await Self.waitForImageRequestStart()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected video download cancellation")
        } catch is CancellationError {
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        try await Self.waitForImageRequestStop()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testRequestBuilderRejectsOverflowingRemoteIdentifiersAndPages() async throws {
        let api = TiebaAPI(client: TiebaHTTPClient(session: Self.session()))

        do {
            _ = try await api.threadPage(
                account: nil,
                threadID: 1,
                page: 1,
                postID: UInt64.max
            )
            XCTFail("Expected overflowing post identifier rejection")
        } catch {
            XCTAssertEqual(
                error as? TiebaRequestValidationError,
                .invalidIdentifier(UInt64.max)
            )
        }

        do {
            _ = try await api.personalizedThreads(account: nil, page: -1, loadType: 1)
            XCTFail("Expected invalid page rejection")
        } catch {
            XCTAssertEqual(error as? TiebaRequestValidationError, .invalidPage(-1))
        }
    }

    func testBoundedResponsePropagatesCancellation() async throws {
        SecurityURLProtocol.payload = Data("late".utf8)
        SecurityURLProtocol.delay = 2
        let loader = BoundedURLSession(session: Self.session())
        let task = Task {
            try await loader.data(
                for: URLRequest(url: URL(string: "https://example.com/slow")!),
                maximumBytes: 100
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            return
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
    }

    func testBusinessErrorsAndExpiredSessionAreDistinct() throws {
        XCTAssertNoThrow(try TiebaResponseValidator.validate(code: 0, message: ""))
        XCTAssertThrowsError(try TiebaResponseValidator.validate(code: 12, message: "业务错误")) {
            XCTAssertEqual($0 as? TiebaAPIError, .response(code: 12, message: "业务错误"))
        }
        XCTAssertThrowsError(
            try TiebaResponseValidator.validate(code: 4, message: "贴子可能已被删除")
        ) {
            XCTAssertEqual(
                $0 as? TiebaAPIError,
                .response(code: 4, message: "贴子可能已被删除")
            )
        }
        XCTAssertThrowsError(
            try TiebaResponseValidator.validate(code: 4, message: "登录已失效")
        ) {
            XCTAssertEqual(
                $0 as? TiebaAPIError,
                .sessionExpired(code: 4, message: "登录已失效")
            )
        }
        XCTAssertThrowsError(try TiebaResponseValidator.validate(code: 110001, message: "登录失效")) {
            XCTAssertEqual($0 as? TiebaAPIError, .sessionExpired(code: 110001, message: "登录失效"))
        }
    }

    func testForumFallbackOnlyAcceptsDecodeIncompatibility() {
        let decodingError = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "fixture"))
        XCTAssertTrue(TiebaAPI.shouldFallbackFromForumProtobuf(decodingError))
        XCTAssertTrue(TiebaAPI.shouldFallbackFromForumProtobuf(BinaryDecodingError.truncated))
        XCTAssertFalse(TiebaAPI.shouldFallbackFromForumProtobuf(URLError(.notConnectedToInternet)))
        XCTAssertFalse(TiebaAPI.shouldFallbackFromForumProtobuf(CancellationError()))
        XCTAssertFalse(TiebaAPI.shouldFallbackFromForumProtobuf(TiebaAPIError.response(code: 1, message: "业务错误")))
        XCTAssertFalse(TiebaAPI.shouldFallbackFromForumProtobuf(TiebaAPIError.emptyResponse))
    }

    @MainActor
    func testLogoutFailureKeepsStoredAccount() async throws {
        let store = AccountStore(service: MemoryAccountStoreService())
        try await store.save(FixtureTiebaAPI.account)
        let coordinator = LogoutCoordinator(accountStore: store, artifactCleaner: FailingArtifactCleaner())

        do {
            try await coordinator.logOut()
            XCTFail("Expected logout failure")
        } catch {
            let persisted = try await store.load()
            XCTAssertEqual(persisted, FixtureTiebaAPI.account)
        }
    }

    @MainActor
    func testCompleteLogoutClearsAccountAfterArtifacts() async throws {
        let store = AccountStore(service: MemoryAccountStoreService())
        try await store.save(FixtureTiebaAPI.account)
        let cleaner = RecordingArtifactCleaner()
        let coordinator = LogoutCoordinator(accountStore: store, artifactCleaner: cleaner)

        try await coordinator.logOut()
        let persisted = try await store.load()
        XCTAssertNil(persisted)
        XCTAssertTrue(cleaner.didClear)
    }

    private static func session() -> URLSession {
        URLSession(configuration: sessionConfiguration())
    }

    private static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SecurityURLProtocol.self]
        return configuration
    }

    private static func makeVideoTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TiebaPureVideoTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func imagePipeline() -> TiebaImagePipeline {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SecurityURLProtocol.self]
        configuration.urlCache = URLCache(
            memoryCapacity: 1 * 1_024 * 1_024,
            diskCapacity: 0,
            diskPath: nil
        )
        return TiebaImagePipeline(
            configuration: configuration,
            redirectScope: .publicHTTPS
        )
    }

    @MainActor
    private static func largePNGData() -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1_024, height: 768))
        return renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_024, height: 768))
        }.pngData()
    }

    private static let onePixelPNGData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    private static func waitForImageRequestStart() async throws {
        for _ in 0..<100 {
            if SecurityURLProtocol.startCount > 0 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for image request to start")
    }

    private static func waitForImageRequestStop() async throws {
        for _ in 0..<100 {
            if SecurityURLProtocol.stopCount > 0 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for image request cancellation")
    }

    private static func waitForImageWaiterCount(
        _ expectedCount: Int,
        pipeline: TiebaImagePipeline
    ) async throws {
        for _ in 0..<100 {
            if await pipeline.inFlightWaiterCountForTesting() == expectedCount { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(expectedCount) image waiters")
    }
}

private final class InMemoryKeychainSecurityOperations: KeychainSecurityOperating, @unchecked Sendable {
    enum Call: Equatable {
        case copy
        case update
        case add
        case delete
    }

    private let lock = NSLock()
    private var storedData: Data?
    private var recordedCalls: [Call] = []

    var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        lock.withLock {
            recordedCalls.append(.copy)
            guard let storedData else { return errSecItemNotFound }
            result?.pointee = storedData as CFData
            return errSecSuccess
        }
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        lock.withLock {
            recordedCalls.append(.update)
            guard storedData != nil else { return errSecItemNotFound }
            guard let data = (attributes as NSDictionary)[kSecValueData] as? Data else {
                return errSecParam
            }
            storedData = data
            return errSecSuccess
        }
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        lock.withLock {
            recordedCalls.append(.add)
            guard storedData == nil else { return errSecDuplicateItem }
            guard let data = (attributes as NSDictionary)[kSecValueData] as? Data else {
                return errSecParam
            }
            storedData = data
            return errSecSuccess
        }
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        lock.withLock {
            recordedCalls.append(.delete)
            let status: OSStatus = storedData == nil ? errSecItemNotFound : errSecSuccess
            storedData = nil
            return status
        }
    }
}

@MainActor
private struct FailingArtifactCleaner: SessionArtifactCleaning {
    func clear() async throws { throw URLError(.cannotRemoveFile) }
}

@MainActor
private final class RecordingArtifactCleaner: SessionArtifactCleaning {
    private(set) var didClear = false
    func clear() async throws { didClear = true }
}

private final class SecurityURLProtocol: URLProtocol {
    static var payload = Data()
    static var chunks: [Data]?
    static var mimeType = "application/octet-stream"
    static var delay: TimeInterval = 0
    static var chunkDelay: TimeInterval = 0
    static var declaredContentLength: Int?
    static var lastRequestURL: URL?
    private static let metricsLock = NSLock()
    private static var recordedStartCount = 0
    private static var recordedStopCount = 0
    private static var recordedLastRequestMethod: String?
    private static var recordedLastRangeHeader: String?
    private let stateLock = NSLock()
    private var workItems: [DispatchWorkItem] = []
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static var startCount: Int {
        metricsLock.withLock { recordedStartCount }
    }

    static var stopCount: Int {
        metricsLock.withLock { recordedStopCount }
    }

    static var lastRequestMethod: String? {
        metricsLock.withLock { recordedLastRequestMethod }
    }

    static var lastRangeHeader: String? {
        metricsLock.withLock { recordedLastRangeHeader }
    }

    static func resetMetrics() {
        metricsLock.withLock {
            recordedStartCount = 0
            recordedStopCount = 0
            recordedLastRequestMethod = nil
            recordedLastRangeHeader = nil
        }
    }

    override func startLoading() {
        Self.metricsLock.withLock {
            Self.recordedStartCount += 1
            Self.recordedLastRequestMethod = request.httpMethod
            Self.recordedLastRangeHeader = request.value(forHTTPHeaderField: "Range")
        }
        Self.lastRequestURL = request.url
        let payload = Self.payload
        let chunks = Self.chunks ?? [payload]
        let mimeType = Self.mimeType
        let declaredContentLength = Self.declaredContentLength
        let chunkDelay = Self.chunkDelay
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isActive, let url = self.request.url else { return }
            var headers = ["Content-Type": Self.mimeType]
            headers["Content-Type"] = mimeType
            if let declaredContentLength {
                headers["Content-Length"] = "\(declaredContentLength)"
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for (index, chunk) in chunks.enumerated() {
                let chunkItem = DispatchWorkItem { [weak self] in
                    guard let self, self.isActive else { return }
                    self.client?.urlProtocol(self, didLoad: chunk)
                    if index == chunks.indices.last {
                        self.client?.urlProtocolDidFinishLoading(self)
                    }
                }
                self.schedule(chunkItem, after: chunkDelay * Double(index))
            }
        }
        schedule(item, after: Self.delay)
    }

    override func stopLoading() {
        Self.metricsLock.withLock { Self.recordedStopCount += 1 }
        stateLock.lock()
        stopped = true
        let items = workItems
        workItems.removeAll()
        stateLock.unlock()
        items.forEach { $0.cancel() }
    }

    private var isActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped == false
    }

    private func schedule(_ item: DispatchWorkItem, after delay: TimeInterval) {
        stateLock.lock()
        let shouldSchedule = stopped == false
        if shouldSchedule {
            workItems.append(item)
        }
        stateLock.unlock()
        guard shouldSchedule else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
    }
}

private actor ProgressRecorder {
    private var progress: [BoundedURLSessionProgress] = []
    private var positiveProgressWaiters: [CheckedContinuation<Void, Never>] = []

    func record(_ value: BoundedURLSessionProgress) {
        progress.append(value)
        guard value.receivedBytes > 0 else { return }
        let waiters = positiveProgressWaiters
        positiveProgressWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func values() -> [BoundedURLSessionProgress] {
        progress
    }

    func waitForPositiveProgress() async {
        guard progress.contains(where: { $0.receivedBytes > 0 }) == false else { return }
        await withCheckedContinuation { continuation in
            positiveProgressWaiters.append(continuation)
        }
    }
}

private actor ControlledSaveAccountStoreService: AccountStoreService {
    private var data: Data?
    private var pendingSave: (data: Data, continuation: CheckedContinuation<Void, Never>)?

    init(data: Data? = nil) {
        self.data = data
    }

    func loadData() async throws -> Data? { data }

    func saveData(_ data: Data) async throws {
        await withCheckedContinuation { continuation in
            pendingSave = (data, continuation)
        }
        self.data = data
    }

    func clearData() async throws {
        data = nil
    }

    func hasPendingSave() -> Bool {
        pendingSave != nil
    }

    func finishPendingSave() {
        guard let pendingSave else { return }
        self.pendingSave = nil
        pendingSave.continuation.resume()
    }
}
