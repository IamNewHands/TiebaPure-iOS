import SwiftUI
import UIKit
import ImageIO

enum TiebaImageRequestPolicy {
    static let maximumRetryCount = 2

    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 20
        )
        request.setValue("tieba/12.52.1.0 skin/default", forHTTPHeaderField: "User-Agent")
        request.setValue("https://tieba.baidu.com/", forHTTPHeaderField: "Referer")
        request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return request
    }

    static func shouldRetry(statusCode: Int, attempt: Int) -> Bool {
        guard attempt < maximumRetryCount else { return false }
        return statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    static func shouldRetry(error: Error, attempt: Int) -> Bool {
        guard attempt < maximumRetryCount else { return false }
        let code = (error as? URLError)?.code
        return code == .timedOut
            || code == .networkConnectionLost
            || code == .notConnectedToInternet
            || code == .cannotConnectToHost
            || code == .cannotFindHost
    }

    static func retryDelayNanoseconds(after attempt: Int) -> UInt64 {
        UInt64(250_000_000 * max(attempt + 1, 1))
    }
}

enum TiebaImageSourcePolicy {
    private static let syntheticFailureHost = "fixture.invalid"
#if DEBUG
    private static let syntheticSuccessHost = "fixture-success.invalid"
    static let syntheticOriginalByteCount = 3_670_016
#endif

    static func urls(primary: URL?, fallback: URL? = nil) -> [URL] {
        var result: [URL] = []
        for candidate in [primary, fallback].compactMap({ $0 }) {
            let safeURL: URL
            if SavedThreadMediaAuthorization.shared.allows(candidate) {
                safeURL = candidate
            } else if let validated = TiebaURL.image(candidate.absoluteString) {
                safeURL = validated
            } else {
                continue
            }
            guard result.contains(safeURL) == false else { continue }
            result.append(safeURL)
        }
        return result
    }

    /// UI-test fixtures use this reserved host to exercise the accessible
    /// failure and retry states without consulting DNS or the network stack.
    static func isSyntheticFailureURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == syntheticFailureHost
    }

#if DEBUG
    /// Deterministic UI-test images are generated in memory and never consult
    /// DNS or the network stack.
    static func isSyntheticSuccessURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == syntheticSuccessHost
    }
#endif
}

enum TiebaImageDecodePolicy {
    static let maximumSourceDimension = 32_768
    static let maximumSourcePixels = 100_000_000
    static let maximumDecodedPixelSize = 4_096
    static let maximumPreviewDecodedPixelSize = 2_560
    static let maximumPreviewDisplayScale: CGFloat = 3
    private static let previewDecodeBuckets = [
        128, 256, 384, 512, 640, 768, 1_024, 1_280,
        1_536, 1_792, 2_048, 2_304, 2_560
    ]

    static func allows(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0,
              width <= maximumSourceDimension,
              height <= maximumSourceDimension else {
            return false
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow == false && pixels <= maximumSourcePixels
    }

    /// Decode targets are a downscale hint only: they never raise the global
    /// pixel ceiling, and non-positive requests fall back to it.
    static func decodeTargetPixelSize(_ requested: Int) -> Int {
        guard requested > 0 else { return maximumDecodedPixelSize }
        return min(requested, maximumDecodedPixelSize)
    }

    static func previewTargetPixelSize(
        for pointSize: CGSize,
        displayScale: CGFloat
    ) -> Int {
        let longestPointEdge = max(pointSize.width, pointSize.height)
        guard longestPointEdge.isFinite,
              longestPointEdge > 0,
              displayScale.isFinite,
              displayScale > 0 else {
            return 512
        }
        let previewScale = min(displayScale, maximumPreviewDisplayScale)
        let requiredPixels = Int(ceil(longestPointEdge * previewScale))
        return previewDecodeBuckets.first(where: { $0 >= requiredPixels })
            ?? maximumPreviewDecodedPixelSize
    }
}

enum TiebaAnimatedImageDecodePolicy {
    /// The decoded-pixel budget below is the memory guard for an animated
    /// image; this bound only rejects pathological frame counts whose
    /// per-frame overhead buys no usable animation. A real post 动图 can carry
    /// a few hundred frames (a 207-frame 240×240 GIF is normal on Tieba), and
    /// the previous 120-frame ceiling silently downgraded those posts to a
    /// still first frame even after the animated original had been downloaded.
    static let maximumFrameCount = 512
    static let maximumDecodedPixels = 24_000_000
    static let defaultFrameDuration = 0.1
    static let minimumFrameDuration = 0.02
    static let maximumFrameDuration = 10.0

    static func frameDuration(properties: [CFString: Any]) -> TimeInterval {
        guard let gifProperties = properties[kCGImagePropertyGIFDictionary]
                as? [CFString: Any] else {
            return defaultFrameDuration
        }
        let rawDuration = (gifProperties[kCGImagePropertyGIFUnclampedDelayTime]
            as? NSNumber)?.doubleValue
            ?? (gifProperties[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
            ?? defaultFrameDuration
        guard rawDuration.isFinite else { return defaultFrameDuration }
        return min(max(rawDuration, minimumFrameDuration), maximumFrameDuration)
    }
}

/// Tieba answers a 动图 with two tiers: the preview tier (`cdnSrc`, the
/// `w=720;q=60;g=0` CDN style) is a still JPEG re-encode of the first frame,
/// while the original tier (`originSrc`) keeps the real GIF bytes behind the
/// same `.jpg` name. The preview stays the right first request — it is about an
/// order of magnitude smaller and paints immediately — so an inline post image
/// keeps it and only replaces it once the original is known to be animated.
enum TiebaAnimatedImageUpgradePolicy {
    static func shouldProbeOriginal(
        previewIsAnimated: Bool,
        previewURL: URL?,
        originalURL: URL?
    ) -> Bool {
        guard previewIsAnimated == false,
              let previewURL,
              let originalURL,
              previewURL != originalURL else {
            return false
        }
        return true
    }
}

private enum TiebaImagePipelineError: Error {
    case invalidURL
    case invalidResponse
    case badStatus(Int)
    case invalidImageData
    case noSource
}

actor TiebaImagePipeline {
    static let shared = TiebaImagePipeline()
    static let maximumImageBytes = 30 * 1_024 * 1_024

    private struct DecodeRequest: Hashable {
        let url: URL
        let targetPixelSize: Int

        var cacheKey: NSString {
            "\(targetPixelSize)|\(url.absoluteString)" as NSString
        }
    }

    private struct InFlightRequest {
        let operationID: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<UIImage, Error>]
    }

    private final class WaiterLease: @unchecked Sendable {
        let id = UUID()

        private let lock = NSLock()
        private var cancelled = false

        func markCancelled() {
            lock.withLock { cancelled = true }
        }

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }
    }

    private let memoryCache = NSCache<NSString, UIImage>()
    private let urlCache: URLCache
    private let session: URLSession
    private let redirectScope: SecureRemoteRedirectScope
    private var inFlight: [DecodeRequest: InFlightRequest] = [:]

    init(
        configuration suppliedConfiguration: URLSessionConfiguration? = nil,
        redirectScope: SecureRemoteRedirectScope = .tiebaMediaHTTPS
    ) {
        let configuration = suppliedConfiguration ?? .default
        let urlCache = suppliedConfiguration?.urlCache ?? URLCache(
            memoryCapacity: 64 * 1_024 * 1_024,
            diskCapacity: 256 * 1_024 * 1_024,
            diskPath: "TiebaPureImages"
        )
        configuration.urlCache = urlCache
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        self.urlCache = urlCache
        self.redirectScope = redirectScope
        session = SecureRemoteURLSession.make(
            configuration: configuration,
            redirectScope: redirectScope
        )
        memoryCache.totalCostLimit = 96 * 1_024 * 1_024
        memoryCache.countLimit = 300
    }

    func clearCaches() {
        let pendingRequests = Array(inFlight.values)
        inFlight.removeAll()
        for request in pendingRequests {
            request.task.cancel()
            request.waiters.values.forEach {
                $0.resume(throwing: CancellationError())
            }
        }
        memoryCache.removeAllObjects()
        urlCache.removeAllCachedResponses()
    }

    /// Memory pressure should release decoded bitmaps without discarding the
    /// disk cache or cancelling requests that are still serving visible rows.
    func releaseDecodedImageCache() {
        memoryCache.removeAllObjects()
    }

    /// `targetPixelSize` caps the decoded bitmap's longest edge. Distinct
    /// targets cache independently, so a screen-sized decode and the
    /// full-resolution tier of the same URL can coexist.
    func image(
        from urls: [URL],
        targetPixelSize: Int = TiebaImageDecodePolicy.maximumDecodedPixelSize,
        onProgress: (@Sendable (BoundedURLSessionProgress) async -> Void)? = nil
    ) async throws -> UIImage {
        guard urls.isEmpty == false else { throw TiebaImagePipelineError.noSource }

        var latestError: Error = TiebaImagePipelineError.noSource
        for url in urls {
            try Task.checkCancellation()
            do {
                return try await image(
                    from: url,
                    targetPixelSize: targetPixelSize,
                    onProgress: onProgress
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                latestError = error
            }
        }
        throw latestError
    }

    private func image(
        from url: URL,
        targetPixelSize: Int,
        onProgress: (@Sendable (BoundedURLSessionProgress) async -> Void)?
    ) async throws -> UIImage {
        // Download the validated URL, not the caller's: validation may have
        // upgraded a legacy http source to https.
        let safeURL: URL
        if SavedThreadMediaAuthorization.shared.allows(url) {
            safeURL = url
        } else if let validated = TiebaURL.image(url.absoluteString),
                  redirectScope.allows(validated) || Self.isSyntheticFixtureURL(validated) {
            safeURL = validated
        } else {
            throw TiebaImagePipelineError.invalidURL
        }
        guard TiebaImageSourcePolicy.isSyntheticFailureURL(url) == false else {
            throw TiebaImagePipelineError.invalidImageData
        }
        let request = DecodeRequest(
            url: safeURL,
            targetPixelSize: TiebaImageDecodePolicy.decodeTargetPixelSize(targetPixelSize)
        )
        if let cached = memoryCache.object(forKey: request.cacheKey) {
            await onProgress?(BoundedURLSessionProgress(receivedBytes: 1, expectedBytes: 1))
            return cached
        }
#if DEBUG
        if TiebaImageSourcePolicy.isSyntheticSuccessURL(url) {
            await onProgress?(BoundedURLSessionProgress(
                receivedBytes: 0,
                expectedBytes: TiebaImageSourcePolicy.syntheticOriginalByteCount
            ))
            if ProcessInfo.processInfo.arguments.contains("UITEST_IMAGE_PROGRESS_DELAY") {
                // Drive a deterministic, visibly filling progress surface.
                // Production requests continue to report real streamed bytes.
                for step in 1...5 {
                    try await Task.sleep(nanoseconds: 400_000_000)
                    await onProgress?(BoundedURLSessionProgress(
                        receivedBytes: TiebaImageSourcePolicy.syntheticOriginalByteCount * step / 5,
                        expectedBytes: TiebaImageSourcePolicy.syntheticOriginalByteCount
                    ))
                }
            } else {
                await Task.yield()
                await onProgress?(BoundedURLSessionProgress(
                    receivedBytes: TiebaImageSourcePolicy.syntheticOriginalByteCount,
                    expectedBytes: TiebaImageSourcePolicy.syntheticOriginalByteCount
                ))
            }
            let image = Self.syntheticFixtureImage(for: url)
            let cost = Self.decodedImageCost(image)
            memoryCache.setObject(image, forKey: request.cacheKey, cost: cost)
            return image
        }
#endif
        if let onProgress {
            let image = try await Self.download(
                request: request,
                session: session,
                onProgress: onProgress
            )
            try Task.checkCancellation()
            let cost = Self.decodedImageCost(image)
            memoryCache.setObject(image, forKey: request.cacheKey, cost: cost)
            return image
        }
        return try await waitForSharedImage(request)
    }

    private static func isSyntheticFixtureURL(_ url: URL) -> Bool {
#if DEBUG
        TiebaImageSourcePolicy.isSyntheticSuccessURL(url)
            || TiebaImageSourcePolicy.isSyntheticFailureURL(url)
#else
        false
#endif
    }

    private func waitForSharedImage(_ request: DecodeRequest) async throws -> UIImage {
        let lease = WaiterLease()
        return try await withTaskCancellationHandler {
            let image = try await withCheckedThrowingContinuation { continuation in
                registerWaiter(
                    continuation,
                    lease: lease,
                    for: request
                )
            }
            try Task.checkCancellation()
            return image
        } onCancel: {
            lease.markCancelled()
            Task {
                await self.cancelWaiter(lease, for: request)
            }
        }
    }

    private func registerWaiter(
        _ continuation: CheckedContinuation<UIImage, Error>,
        lease: WaiterLease,
        for request: DecodeRequest
    ) {
        guard lease.isCancelled == false else {
            continuation.resume(throwing: CancellationError())
            return
        }
        if var requestState = inFlight[request] {
            requestState.waiters[lease.id] = continuation
            inFlight[request] = requestState
            return
        }

        let operationID = UUID()
        let session = session
        let task = Task {
            let result: Result<UIImage, Error>
            do {
                result = .success(try await Self.download(
                    request: request,
                    session: session,
                    onProgress: nil
                ))
            } catch {
                result = .failure(error)
            }
            self.completeSharedRequest(
                request,
                operationID: operationID,
                result: result
            )
        }
        inFlight[request] = InFlightRequest(
            operationID: operationID,
            task: task,
            waiters: [lease.id: continuation]
        )
    }

    private func cancelWaiter(_ lease: WaiterLease, for request: DecodeRequest) {
        guard var requestState = inFlight[request],
              let continuation = requestState.waiters.removeValue(forKey: lease.id) else {
            return
        }
        continuation.resume(throwing: CancellationError())
        guard requestState.waiters.isEmpty else {
            inFlight[request] = requestState
            return
        }
        inFlight[request] = nil
        requestState.task.cancel()
    }

    private func completeSharedRequest(
        _ request: DecodeRequest,
        operationID: UUID,
        result: Result<UIImage, Error>
    ) {
        guard let requestState = inFlight[request],
              requestState.operationID == operationID else {
            return
        }
        inFlight[request] = nil

        switch result {
        case let .success(image):
            let cost = Self.decodedImageCost(image)
            memoryCache.setObject(image, forKey: request.cacheKey, cost: cost)
            requestState.waiters.values.forEach { $0.resume(returning: image) }
        case let .failure(error):
            requestState.waiters.values.forEach { $0.resume(throwing: error) }
        }
    }

#if DEBUG
    func inFlightWaiterCountForTesting() -> Int {
        inFlight.values.reduce(0) { $0 + $1.waiters.count }
    }
#endif

    private static func download(
        request: DecodeRequest,
        session: URLSession,
        onProgress: (@Sendable (BoundedURLSessionProgress) async -> Void)?
    ) async throws -> UIImage {
        if request.url.isFileURL {
            guard SavedThreadMediaAuthorization.shared.allows(request.url) else {
                throw TiebaImagePipelineError.invalidURL
            }
            let data = try Data(contentsOf: request.url, options: [.mappedIfSafe, .uncached])
            guard data.isEmpty == false,
                  data.count <= maximumImageBytes,
                  let image = decodedImage(
                    from: data,
                    targetPixelSize: request.targetPixelSize
                  ) else {
                throw TiebaImagePipelineError.invalidImageData
            }
            await onProgress?(BoundedURLSessionProgress(
                receivedBytes: data.count,
                expectedBytes: data.count
            ))
            return image
        }
        var attempt = 0
        while true {
            do {
                let (data, response) = try await BoundedURLSession(session: session).data(
                    for: TiebaImageRequestPolicy.request(for: request.url),
                    maximumBytes: maximumImageBytes,
                    requiredMIMEPrefix: "image/",
                    onProgress: onProgress
                )
                guard let response = response as? HTTPURLResponse else {
                    throw TiebaImagePipelineError.invalidResponse
                }
                guard (200...299).contains(response.statusCode) else {
                    if TiebaImageRequestPolicy.shouldRetry(statusCode: response.statusCode, attempt: attempt) {
                        try await Task.sleep(
                            nanoseconds: TiebaImageRequestPolicy.retryDelayNanoseconds(after: attempt)
                        )
                        attempt += 1
                        continue
                    }
                    throw TiebaImagePipelineError.badStatus(response.statusCode)
                }
                guard let image = decodedImage(
                    from: data,
                    targetPixelSize: request.targetPixelSize
                ) else {
                    throw TiebaImagePipelineError.invalidImageData
                }
                return image
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                guard TiebaImageRequestPolicy.shouldRetry(error: error, attempt: attempt) else {
                    throw error
                }
                try await Task.sleep(
                    nanoseconds: TiebaImageRequestPolicy.retryDelayNanoseconds(after: attempt)
                )
                attempt += 1
            }
        }
    }

#if DEBUG
    private static func syntheticFixtureImage(for url: URL) -> UIImage {
        let size = url.lastPathComponent.contains("lowres-thumbnail")
            ? CGSize(width: 80, height: 320)
            : CGSize(width: 320, height: 1_280)
        // Thumbnail/original fixture URLs represent the same underlying
        // picture. Seeding them independently made the hero animation morph
        // between unrelated colors and could either mimic or conceal a real
        // transition drift in pixel tests.
        let fixtureIdentity = url.absoluteString
            .replacingOccurrences(of: "-thumbnail.", with: ".")
            .replacingOccurrences(of: "-original.", with: ".")
        let seed = fixtureIdentity.utf8.reduce(UInt32(2_166_136_261)) { partial, byte in
            (partial ^ UInt32(byte)) &* 16_777_619
        }
        let hue = CGFloat(seed % 360) / 360
        let accentHue = CGFloat((seed / 360 + 113) % 360) / 360
        return UIGraphicsImageRenderer(size: size).image { context in
            let bounds = CGRect(origin: .zero, size: size)
            context.cgContext.setFillColor(UIColor(
                hue: hue,
                saturation: 0.72,
                brightness: 0.82,
                alpha: 1
            ).cgColor)
            context.cgContext.fill(bounds)
            context.cgContext.setFillColor(UIColor(
                hue: accentHue,
                saturation: 0.78,
                brightness: 0.96,
                alpha: 0.82
            ).cgColor)
            context.cgContext.fill(CGRect(x: 0, y: size.height * 0.45, width: size.width, height: size.height * 0.55))

            let stripeWidth = CGFloat(12 + Int(seed % 20))
            context.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.72).cgColor)
            context.cgContext.fill(CGRect(
                x: CGFloat(Int(seed / 7) % 72),
                y: 0,
                width: stripeWidth,
                height: size.height
            ))
        }
    }
#endif

    static func decodedImage(from data: Data, targetPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              TiebaImageDecodePolicy.allows(width: width, height: height) else {
            return nil
        }
        if let animatedImage = decodedAnimatedImage(
            source: source,
            targetPixelSize: targetPixelSize
        ) {
            return animatedImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: TiebaImageDecodePolicy.decodeTargetPixelSize(targetPixelSize),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    static func decodedImageCost(_ image: UIImage) -> Int {
        let frames = image.images ?? [image]
        return frames.reduce(into: 0) { total, frame in
            let width = frame.cgImage?.width ?? Int(frame.size.width * frame.scale)
            let height = frame.cgImage?.height ?? Int(frame.size.height * frame.scale)
            let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
            let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
            guard pixelOverflow == false, byteOverflow == false,
                  total <= Int.max - bytes else {
                total = Int.max
                return
            }
            total += bytes
        }
    }

    private static func decodedAnimatedImage(
        source: CGImageSource,
        targetPixelSize: Int
    ) -> UIImage? {
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1,
              frameCount <= TiebaAnimatedImageDecodePolicy.maximumFrameCount else {
            return nil
        }
        let maximumFramePixelSize = TiebaImageDecodePolicy.decodeTargetPixelSize(
            targetPixelSize
        )
        let baseOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        var frames: [UIImage] = []
        frames.reserveCapacity(frameCount)
        var duration: TimeInterval = 0
        var decodedPixels = 0

        for index in 0..<frameCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                index,
                nil
            ) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  TiebaImageDecodePolicy.allows(width: width, height: height) else {
                return nil
            }
            // A frame is never decoded larger than its own pixel size. Tieba
            // serves small 动图 (240×240 ones are common) whose frames would
            // otherwise be scaled up to the display target once per frame,
            // multiplying the pixel budget by the frame count for no detail.
            var options = baseOptions
            options[kCGImageSourceThumbnailMaxPixelSize] = min(
                maximumFramePixelSize,
                max(width, height)
            )
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                index,
                options as CFDictionary
            ) else {
                return nil
            }
            let (framePixels, overflow) = cgImage.width.multipliedReportingOverflow(
                by: cgImage.height
            )
            guard overflow == false,
                  framePixels <= TiebaAnimatedImageDecodePolicy.maximumDecodedPixels - decodedPixels else {
                return nil
            }
            decodedPixels += framePixels
            duration += TiebaAnimatedImageDecodePolicy.frameDuration(properties: properties)
            frames.append(UIImage(cgImage: cgImage))
        }
        return UIImage.animatedImage(with: frames, duration: duration)
    }
}

private struct TiebaAnimatedUIImageView: UIViewRepresentable {
    let image: UIImage
    let contentMode: ContentMode

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.clipsToBounds = true
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
        imageView.contentMode = contentMode == .fill ? .scaleAspectFill : .scaleAspectFit
        imageView.image = image
        imageView.startAnimating()
    }

    static func dismantleUIView(_ imageView: UIImageView, coordinator: Void) {
        imageView.stopAnimating()
        imageView.image = nil
    }
}

@MainActor
private final class TiebaRemoteImageModel: ObservableObject {
    enum Phase {
        case empty
        case loading
        case success(UIImage)
        case failure
    }

    @Published private(set) var phase: Phase = .empty
    private var sourceKey = ""
    private var loadID: UUID?
    private var task: Task<UIImage, Error>?
    /// True while the current source still owes the animated-original download.
    /// A load cancelled mid-upgrade keeps the still preview, so the next
    /// appearance has to finish the upgrade instead of returning early and
    /// leaving the 动图 frozen.
    private var awaitsAnimatedUpgrade = false

    deinit {
        task?.cancel()
    }

    func load(
        urls: [URL],
        targetPixelSize: Int,
        prefersAnimatedOriginal: Bool = false,
        force: Bool = false
    ) async {
        let key = Self.sourceKey(urls: urls, targetPixelSize: targetPixelSize)
        let sourceChanged = key != sourceKey
        if sourceChanged {
            awaitsAnimatedUpgrade = false
        }
        let resumesInterruptedLoad: Bool
        if case .loading = phase {
            resumesInterruptedLoad = task == nil
        } else {
            resumesInterruptedLoad = false
        }
        let resumesInterruptedUpgrade: Bool
        if case let .success(image) = phase {
            resumesInterruptedUpgrade = awaitsAnimatedUpgrade
                && task == nil
                && image.images?.isEmpty != false
        } else {
            resumesInterruptedUpgrade = false
        }
        guard force
            || sourceChanged
            || isEmpty
            || isFailed
            || resumesInterruptedLoad
            || resumesInterruptedUpgrade else { return }
        sourceKey = key

        if resumesInterruptedUpgrade, case let .success(image) = phase {
            await upgradeToAnimatedOriginal(
                preview: image,
                urls: urls,
                targetPixelSize: targetPixelSize,
                isEnabled: prefersAnimatedOriginal
            )
            return
        }

        task?.cancel()

        guard urls.isEmpty == false else {
            phase = .failure
            return
        }

        phase = .loading
        let requestKey = key
        let requestID = UUID()
        loadID = requestID
        let loadTask = Task {
            try await TiebaImagePipeline.shared.image(
                from: urls,
                targetPixelSize: targetPixelSize
            )
        }
        task = loadTask

        do {
            let image = try await withTaskCancellationHandler {
                try await loadTask.value
            } onCancel: {
                loadTask.cancel()
            }
            guard Task.isCancelled == false,
                  sourceKey == requestKey,
                  loadID == requestID else { return }
            task = nil
            loadID = nil
            phase = .success(image)
            await upgradeToAnimatedOriginal(
                preview: image,
                urls: urls,
                targetPixelSize: targetPixelSize,
                isEnabled: prefersAnimatedOriginal
            )
        } catch is CancellationError {
            guard sourceKey == requestKey, loadID == requestID else { return }
            task = nil
            loadID = nil
            phase = .empty
        } catch {
            guard Task.isCancelled == false,
                  sourceKey == requestKey,
                  loadID == requestID else { return }
            task = nil
            loadID = nil
            phase = .failure
        }
    }

    /// Replaces a still preview with the animated original when the CDN reports
    /// that the original really is an animation. The preview has already been
    /// published, so this only ever swaps in a better bitmap: a probe that
    /// fails, a cancelled download, or a still original all leave the preview
    /// on screen.
    private func upgradeToAnimatedOriginal(
        preview: UIImage,
        urls: [URL],
        targetPixelSize: Int,
        isEnabled: Bool
    ) async {
        guard isEnabled,
              let original = urls.dropFirst().first,
              TiebaAnimatedImageUpgradePolicy.shouldProbeOriginal(
                  previewIsAnimated: preview.images?.isEmpty == false,
                  previewURL: urls.first,
                  originalURL: original
              ) else {
            awaitsAnimatedUpgrade = false
            return
        }

        let requestKey = sourceKey
        let requestID = UUID()
        loadID = requestID
        awaitsAnimatedUpgrade = true

        // A failed probe is not a verdict, so the flag stays set and a later
        // appearance retries instead of freezing the preview.
        guard let isAnimated = try? await TiebaImageMetadataClient.shared.isAnimatedImage(
            at: original
        ) else {
            return
        }
        guard isAnimated else {
            awaitsAnimatedUpgrade = false
            return
        }

        guard let animated = try? await TiebaImagePipeline.shared.image(
            from: [original],
            targetPixelSize: targetPixelSize
        ),
              animated.images?.isEmpty == false,
              Task.isCancelled == false,
              sourceKey == requestKey,
              loadID == requestID else {
            return
        }
        awaitsAnimatedUpgrade = false
        loadID = nil
        phase = .success(animated)
    }

    func suspendAutomaticLoad(urls: [URL], targetPixelSize: Int) {
        let key = Self.sourceKey(urls: urls, targetPixelSize: targetPixelSize)
        if sourceKey != key {
            task?.cancel()
            task = nil
            loadID = nil
            sourceKey = key
            phase = .empty
            return
        }
        guard case .loading = phase else { return }
        task?.cancel()
        task = nil
        loadID = nil
        phase = .empty
    }

    func cancelActiveLoad(publishesPhaseChange: Bool = true) {
        task?.cancel()
        task = nil
        loadID = nil
        if publishesPhaseChange, case .loading = phase {
            phase = .empty
        }
    }

    func represents(urls: [URL], targetPixelSize: Int) -> Bool {
        sourceKey == Self.sourceKey(urls: urls, targetPixelSize: targetPixelSize)
    }

    private static func sourceKey(urls: [URL], targetPixelSize: Int) -> String {
        "\(TiebaImageDecodePolicy.decodeTargetPixelSize(targetPixelSize))|"
            + urls.map(\.absoluteString).joined(separator: "|")
    }

    private var isFailed: Bool {
        if case .failure = phase { return true }
        return false
    }

    private var isEmpty: Bool {
        if case .empty = phase { return true }
        return false
    }

    var loadState: TiebaRemoteImageLoadState {
        switch phase {
        case .empty:
            return .empty
        case .loading:
            return .loading
        case .success:
            return .success
        case .failure:
            return .failure
        }
    }
}

enum TiebaRemoteImageLoadState: Equatable, Sendable {
    case empty
    case loading
    case success
    case failure
}

struct TiebaRemoteImage: View {
    let urls: [URL]
    var targetPixelSize: Int
    var contentMode: ContentMode = .fill
    var showsProgress = false
    var retryTrigger = 0
    var showsRetryButton = true
    var showsResolvedImage = true
    var loadsAutomatically = true
    /// Opt-in for surfaces that render a post image at reading width. The
    /// still CDN preview paints first either way; with this on, an image whose
    /// original is animated is replaced by the animation once the CDN confirms
    /// it, instead of staying on the flattened first frame.
    var prefersAnimatedOriginal = false
    var onLoadStateChange: ((TiebaRemoteImageLoadState) -> Void)?
    var onImageResolved: ((UIImage) -> Void)?
    var onImageLayoutResolved: ((UIImage, CGRect) -> Void)?
    var onDebugImageObserverResolved: ((UIView, UIImage) -> Void)?

    @StateObject private var model = TiebaRemoteImageModel()

    init(
        primaryURL: URL?,
        fallbackURL: URL? = nil,
        targetPixelSize: Int = TiebaImageDecodePolicy.maximumPreviewDecodedPixelSize,
        contentMode: ContentMode = .fill,
        showsProgress: Bool = false,
        retryTrigger: Int = 0,
        showsRetryButton: Bool = true,
        showsResolvedImage: Bool = true,
        loadsAutomatically: Bool = true,
        prefersAnimatedOriginal: Bool = false,
        onLoadStateChange: ((TiebaRemoteImageLoadState) -> Void)? = nil,
        onImageResolved: ((UIImage) -> Void)? = nil,
        onImageLayoutResolved: ((UIImage, CGRect) -> Void)? = nil,
        onDebugImageObserverResolved: ((UIView, UIImage) -> Void)? = nil
    ) {
        urls = TiebaImageSourcePolicy.urls(primary: primaryURL, fallback: fallbackURL)
        self.targetPixelSize = TiebaImageDecodePolicy.decodeTargetPixelSize(targetPixelSize)
        self.contentMode = contentMode
        self.showsProgress = showsProgress
        self.retryTrigger = retryTrigger
        self.showsRetryButton = showsRetryButton
        self.showsResolvedImage = showsResolvedImage
        self.loadsAutomatically = loadsAutomatically
        self.prefersAnimatedOriginal = prefersAnimatedOriginal
        self.onLoadStateChange = onLoadStateChange
        self.onImageResolved = onImageResolved
        self.onImageLayoutResolved = onImageLayoutResolved
        self.onDebugImageObserverResolved = onDebugImageObserverResolved
    }

    var body: some View {
        Group {
            switch model.phase {
            case let .success(image):
                if model.represents(urls: urls, targetPixelSize: targetPixelSize) {
                    if showsResolvedImage {
                        Group {
                            if image.images?.isEmpty == false {
                                TiebaAnimatedUIImageView(
                                    image: image,
                                    contentMode: contentMode
                                )
                            } else {
                                Image(uiImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: contentMode)
                            }
                        }
                            .background {
                                if onImageLayoutResolved != nil || activeDebugImageObserver != nil {
                                    TiebaResolvedImageFrameReader(
                                        image: image,
                                        onLayout: onImageLayoutResolved,
                                        onObserver: activeDebugImageObserver
                                    )
                                }
                            }
                    } else {
                        // Transition thumbnails are rendered by their registered
                        // UIKit source view. Keep this loader in the hierarchy so
                        // it can resolve/retry the image without drawing a second
                        // bitmap underneath the native zoom source.
                        Color.clear
                    }
                } else if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Color.clear
                }
            case .empty:
                if showsProgress, loadsAutomatically {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Color.clear
                }
            case .loading:
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Color.clear
                }
            case .failure:
                if showsRetryButton {
                    Button {
                        Task {
                            await model.load(
                                urls: urls,
                                targetPixelSize: targetPixelSize,
                                prefersAnimatedOriginal: prefersAnimatedOriginal,
                                force: true
                            )
                        }
                    } label: {
                        retryLabel
                    }
                    .accessibilityLabel("图片加载失败")
                    .accessibilityHint("点按重新加载图片")
                } else {
                    retryLabel
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(targetPixelSize)#\(urls.map(\.absoluteString).joined(separator: "|"))#\(retryTrigger)#\(loadsAutomatically)") {
            guard loadsAutomatically else {
                model.suspendAutomaticLoad(urls: urls, targetPixelSize: targetPixelSize)
                return
            }
            await model.load(
                urls: urls,
                targetPixelSize: targetPixelSize,
                prefersAnimatedOriginal: prefersAnimatedOriginal,
                force: retryTrigger > 0
            )
        }
        .onDisappear {
            // A recycled row only needs to release its network lease. Keeping
            // the loading phase avoids a redundant ObservableObject publish
            // and transition-anchor invalidation while the scroll is moving.
            model.cancelActiveLoad(publishesPhaseChange: false)
        }
        .onReceive(model.$phase) { phase in
            guard case let .success(image) = phase,
                  model.represents(urls: urls, targetPixelSize: targetPixelSize) else {
                return
            }
            onImageResolved?(image)
        }
        .onChange(of: model.loadState) { state in
            onLoadStateChange?(state)
        }
        .onAppear {
            onLoadStateChange?(model.loadState)
        }
    }

    private var retryLabel: some View {
        Label("图片加载失败，点按重试", systemImage: "arrow.clockwise")
            .labelStyle(.iconOnly)
            .font(.system(size: 24))
            .foregroundStyle(.secondary)
            .minTouchTarget()
            .contentShape(Rectangle())
    }

    private var activeDebugImageObserver: ((UIView, UIImage) -> Void)? {
#if DEBUG
        onDebugImageObserverResolved
#else
        nil
#endif
    }
}

#if DEBUG
struct RemoteImageReuseUITestHost: View {
    @State private var selectedSource = "A"
    @State private var resolvedSource = ""
    @State private var manualAuthorization: String?

    private var usesManualLoading: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_REMOTE_IMAGE_REUSE_MANUAL")
    }

    private var sourceURL: URL? {
        URL(string: selectedSource == "A"
            ? "https://fixture-success.invalid/reuse-a.png"
            : "https://fixture-success.invalid/reuse-b.png")
    }

    private var sourceIdentity: String {
        sourceURL?.absoluteString ?? selectedSource
    }

    private var allowsLoading: Bool {
        usesManualLoading == false || manualAuthorization == sourceIdentity
    }

    var body: some View {
        VStack(spacing: 20) {
            TiebaRemoteImage(
                primaryURL: sourceURL,
                contentMode: .fill,
                showsProgress: true,
                loadsAutomatically: allowsLoading,
                onLoadStateChange: { state in
                    if state == .success {
                        resolvedSource = selectedSource
                    }
                }
            )
            .frame(width: 160, height: 260)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("remote-image-reuse-surface")
            .accessibilityLabel("复用图片 \(selectedSource)")

            Text(stateText)
                .accessibilityIdentifier("remote-image-reuse-state")

            if usesManualLoading {
                Button("加载当前图片") {
                    manualAuthorization = sourceIdentity
                }
                .disabled(resolvedSource == selectedSource)
                .accessibilityIdentifier("remote-image-reuse-load")
            }

            Button("切换到图片 B") {
                selectedSource = "B"
                resolvedSource = ""
            }
            .disabled(selectedSource == "B")
            .accessibilityIdentifier("remote-image-reuse-switch")
        }
        .padding()
    }

    private var stateText: String {
        if resolvedSource.isEmpty == false {
            return "已加载 \(resolvedSource)"
        }
        return allowsLoading ? "正在加载" : "等待加载 \(selectedSource)"
    }
}
#endif

private struct TiebaResolvedImageFrameReader: UIViewRepresentable {
    let image: UIImage
    let onLayout: ((UIImage, CGRect) -> Void)?
    let onObserver: ((UIView, UIImage) -> Void)?

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.configure(image: image, onLayout: onLayout, onObserver: onObserver)
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        uiView.configure(image: image, onLayout: onLayout, onObserver: onObserver)
        uiView.reportFrameIfPossible(force: true)
    }

    final class ObserverView: UIView {
        private var image: UIImage?
        private var onLayout: ((UIImage, CGRect) -> Void)?
        private var onObserver: ((UIView, UIImage) -> Void)?
        private var lastReportedFrame: CGRect?

        func configure(
            image: UIImage,
            onLayout: ((UIImage, CGRect) -> Void)?,
            onObserver: ((UIView, UIImage) -> Void)?
        ) {
            if self.image !== image {
                lastReportedFrame = nil
            }
            self.image = image
            self.onLayout = onLayout
            self.onObserver = onObserver
            onObserver?(self, image)
            setNeedsLayout()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportFrameIfPossible(force: true)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            reportFrameIfPossible()
        }

        func reportFrameIfPossible(force: Bool = false) {
            guard let image,
                  let window,
                  bounds.width >= 2,
                  bounds.height >= 2 else {
                return
            }
            let frameInWindow = convert(bounds, to: window)
            guard frameInWindow.minX.isFinite,
                  frameInWindow.minY.isFinite,
                  frameInWindow.width.isFinite,
                  frameInWindow.height.isFinite else {
                return
            }
            if force == false,
               let lastReportedFrame,
               Self.framesMatch(lastReportedFrame, frameInWindow) {
                return
            }
            lastReportedFrame = frameInWindow
            onLayout?(image, frameInWindow)
        }

        private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            let tolerance: CGFloat = 0.25
            return abs(lhs.minX - rhs.minX) <= tolerance
                && abs(lhs.minY - rhs.minY) <= tolerance
                && abs(lhs.width - rhs.width) <= tolerance
                && abs(lhs.height - rhs.height) <= tolerance
        }
    }
}

/// The badge letter for a value that has no image at all.
///
/// `/c/u/user/profile` answers a user's followed forums with only a name and an
/// id per row, so that column has no picture to load and every row would repeat
/// the same anonymous silhouette. Callers that know a name pass its first
/// character here instead.
enum AvatarInitialPolicy {
    static func initial(from candidates: String...) -> String? {
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = trimmed.first else { continue }
            return String(first).uppercased()
        }
        return nil
    }
}

/// Stable color for a badge letter: the same name always lands on the same
/// swatch, so a list reads as a fixed set of badges instead of a column that
/// recolors itself on every redraw.
enum AvatarInitialPalette {
    static let colors: [Color] = [
        Color(red: 0.29, green: 0.56, blue: 0.89),
        Color(red: 0.90, green: 0.49, blue: 0.27),
        Color(red: 0.30, green: 0.64, blue: 0.45),
        Color(red: 0.60, green: 0.43, blue: 0.83),
        Color(red: 0.84, green: 0.40, blue: 0.52),
        Color(red: 0.28, green: 0.61, blue: 0.74)
    ]

    static func color(for seed: String?) -> Color {
        colors[index(for: seed ?? "", count: colors.count)]
    }

    static func index(for seed: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt32 = 2_166_136_261
        for scalar in seed.unicodeScalars {
            hash = (hash ^ scalar.value) &* 16_777_619
        }
        return Int(hash % UInt32(count))
    }
}

struct AvatarView: View {
    @Environment(\.displayScale) private var displayScale

    let url: URL?
    let title: String?
    let size: CGFloat
    let fallbackInitial: String?

    init(
        url: URL?,
        title: String? = nil,
        size: CGFloat = TiebaPureTheme.AvatarSize.medium,
        fallbackInitial: String? = nil
    ) {
        self.url = url
        self.title = title
        self.size = size
        let trimmed = fallbackInitial?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fallbackInitial = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(TiebaPureTheme.ColorToken.readerTertiarySurface)

            if let url {
                TiebaRemoteImage(
                    primaryURL: url,
                    targetPixelSize: TiebaImageDecodePolicy.previewTargetPixelSize(
                        for: CGSize(width: size, height: size),
                        displayScale: displayScale
                    ),
                    contentMode: .fill,
                    showsProgress: false,
                    showsRetryButton: false
                )
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(title.map { "\($0)头像" } ?? "头像")
    }

    private var placeholder: some View {
        ZStack {
            if let fallbackInitial {
                Circle()
                    .fill(AvatarInitialPalette.color(for: title ?? fallbackInitial))
                Text(fallbackInitial)
                    .font(.system(size: max(13, size * 0.42), weight: .semibold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 2)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: max(13, size * 0.42), weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }
}
