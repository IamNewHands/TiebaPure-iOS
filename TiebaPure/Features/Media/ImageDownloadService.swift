import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

struct TiebaImageDownloadPayload: Sendable, Equatable {
    let data: Data
    let mimeType: String
    let fileName: String
}

enum TiebaImageDownloadError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case badStatus(Int)
    case invalidImageData
    case photoLibraryAccessDenied
    case photoLibraryWriteFailed
}

struct TiebaImageDownloadClient: Sendable {
    /// Each client owns a delegate-retained URLSession that is never
    /// invalidated; per-save instances therefore leak a session apiece.
    static let shared = TiebaImageDownloadClient()

    let session: URLSession
    let redirectScope: SecureRemoteRedirectScope

    init(
        session: URLSession = TiebaImageDownloadClient.makeSession(),
        redirectScope: SecureRemoteRedirectScope = .tiebaMediaHTTPS
    ) {
        self.session = session
        self.redirectScope = redirectScope
    }

    func download(from url: URL) async throws -> TiebaImageDownloadPayload {
        if url.isFileURL {
            return try await Task.detached(priority: .userInitiated) {
                guard SavedThreadMediaAuthorization.shared.allows(url) else {
                    throw TiebaImageDownloadError.invalidURL
                }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe, .uncached])
                guard data.isEmpty == false,
                      data.count <= TiebaImagePipeline.maximumImageBytes,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceGetCount(source) > 0,
                      TiebaImageDownloadPolicy.allows(source: source) else {
                    throw TiebaImageDownloadError.invalidImageData
                }
                let typeIdentifier = CGImageSourceGetType(source) as String?
                let mimeType = typeIdentifier.flatMap { UTType($0)?.preferredMIMEType }
                    ?? "image/jpeg"
                return TiebaImageDownloadPayload(
                    data: data,
                    mimeType: mimeType,
                    fileName: TiebaImageDownloadPolicy.fileName(
                        for: url,
                        mimeType: mimeType,
                        typeIdentifier: typeIdentifier
                    )
                )
            }.value
        }
        // Request the validated URL, not the caller's: validation may have
        // upgraded a legacy http source to https.
        guard let safeURL = TiebaURL.image(url.absoluteString),
              redirectScope.allows(safeURL) || Self.isSyntheticFixtureURL(safeURL) else {
            throw TiebaImageDownloadError.invalidURL
        }

        var request = TiebaImageRequestPolicy.request(for: safeURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await BoundedURLSession(session: session).data(
            for: request,
            maximumBytes: TiebaImagePipeline.maximumImageBytes,
            requiredMIMEPrefix: "image/"
        )
        guard let response = response as? HTTPURLResponse else {
            throw TiebaImageDownloadError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            throw TiebaImageDownloadError.badStatus(response.statusCode)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              TiebaImageDownloadPolicy.allows(source: source) else {
            throw TiebaImageDownloadError.invalidImageData
        }

        let mimeType = response.mimeType?.lowercased() ?? "image/jpeg"
        let typeIdentifier = CGImageSourceGetType(source) as String?
        return TiebaImageDownloadPayload(
            data: data,
            mimeType: mimeType,
            fileName: TiebaImageDownloadPolicy.fileName(
                for: url,
                mimeType: mimeType,
                typeIdentifier: typeIdentifier
            )
        )
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return SecureRemoteURLSession.make(
            configuration: configuration,
            redirectScope: .tiebaMediaHTTPS
        )
    }

    private static func isSyntheticFixtureURL(_ url: URL) -> Bool {
#if DEBUG
        TiebaImageSourcePolicy.isSyntheticSuccessURL(url)
#else
        false
#endif
    }
}

struct TiebaImageMetadataClient: Sendable {
    static let shared = TiebaImageMetadataClient()

    let session: URLSession
    let redirectScope: SecureRemoteRedirectScope

    init(
        session: URLSession = TiebaImageMetadataClient.makeSession(),
        redirectScope: SecureRemoteRedirectScope = .tiebaMediaHTTPS
    ) {
        self.session = session
        self.redirectScope = redirectScope
    }

    func contentLength(from url: URL) async throws -> Int64? {
        guard let safeURL = metadataURL(url) else { return nil }
#if DEBUG
        if TiebaImageSourcePolicy.isSyntheticSuccessURL(safeURL) {
            return Int64(TiebaImageSourcePolicy.syntheticOriginalByteCount)
        }
#endif
        guard let response = try await headResponse(for: safeURL) else { return nil }
        return TiebaImageMetadataPolicy.contentLength(from: response)
    }

    /// Whether the original file is an animated image.
    ///
    /// Tieba keeps the animated bytes of a 动图 at the original tier behind the
    /// same `.jpg` name the still CDN preview uses, so the URL cannot tell the
    /// two apart and only the stored file can. The CDN labels that file with its
    /// real media type, which makes a body-free HEAD the cheapest way to know
    /// whether downloading the original would buy an animation.
    func isAnimatedImage(at url: URL) async throws -> Bool {
        guard let safeURL = metadataURL(url) else { return false }
#if DEBUG
        if TiebaImageSourcePolicy.isSyntheticSuccessURL(safeURL) {
            return false
        }
#endif
        guard let response = try await headResponse(for: safeURL) else { return false }
        return TiebaImageMetadataPolicy.isAnimatedContentType(
            response.value(forHTTPHeaderField: "Content-Type")
        )
    }

    private func metadataURL(_ url: URL) -> URL? {
        guard let safeURL = TiebaURL.image(url.absoluteString),
              redirectScope.allows(safeURL) || Self.isSyntheticFixtureURL(safeURL) else {
            return nil
        }
        return safeURL
    }

    private func headResponse(for safeURL: URL) async throws -> HTTPURLResponse? {
        var headRequest = TiebaImageRequestPolicy.request(for: safeURL)
        headRequest.httpMethod = "HEAD"
        headRequest.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, rawHeadResponse) = try await BoundedURLSession(session: session).data(
            for: headRequest,
            maximumBytes: 1_024,
            requiredMIMEPrefix: "image/",
            enforcesDeclaredContentLength: false
        )
        guard let response = rawHeadResponse as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            return nil
        }
        return response
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        return SecureRemoteURLSession.make(
            configuration: configuration,
            redirectScope: .tiebaMediaHTTPS
        )
    }


    private static func isSyntheticFixtureURL(_ url: URL) -> Bool {
#if DEBUG
        TiebaImageSourcePolicy.isSyntheticSuccessURL(url)
#else
        false
#endif
    }
}

enum TiebaImageMetadataPolicy {
    /// `image/gif` is what the CDN reports for the stored animated original of a
    /// Tieba 动图; the still preview tier of the same picture reports
    /// `image/jpeg`. Parameters after the media type (e.g. `; charset=…`) do not
    /// change the verdict, and an unknown or missing type stays conservative:
    /// the caller then keeps the preview it already has.
    static func isAnimatedContentType(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        let mediaType = rawValue
            .components(separatedBy: ";")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mediaType == "image/gif"
    }

    static func contentLength(from response: HTTPURLResponse) -> Int64? {
        if let range = response.value(forHTTPHeaderField: "Content-Range") {
            return totalByteCount(fromContentRange: range)
        }
        guard response.statusCode != 206 else { return nil }
        let expected = response.expectedContentLength
        return expected > 0 ? expected : nil
    }

    static func totalByteCount(fromContentRange value: String) -> Int64? {
        let components = value.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isWhitespace }
        )
        guard components.count == 2,
              components[0].lowercased() == "bytes" else {
            return nil
        }
        let rangeAndTotal = components[1].split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard rangeAndTotal.count == 2,
              rangeAndTotal[1] != "*",
              let total = Int64(rangeAndTotal[1]),
              total > 0 else {
            return nil
        }
        let bounds = rangeAndTotal[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0,
              end >= start,
              total > end else {
            return nil
        }
        return total
    }
}

enum TiebaImageDownloadPolicy {
    static let maximumFileNameStemLength = 96
    static let maximumFileNameStemBytes = 180

    static func preferredURL(original: URL?, thumbnail: URL?) -> URL? {
        for candidate in [original, thumbnail].compactMap({ $0 }) {
            if let safeURL = TiebaRemoteMediaPolicy.url(candidate.absoluteString) {
                return safeURL
            }
        }
        return nil
    }

    static func allows(source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return false
        }
        return TiebaImageDecodePolicy.allows(width: width, height: height)
    }

    static func fileName(
        for url: URL,
        mimeType: String,
        typeIdentifier: String?
    ) -> String {
        let rawStem = url.deletingPathExtension().lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitizedStem = String(rawStem.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let stem = boundedStem(sanitizedStem)
        let resolvedStem = stem.isEmpty ? "TiebaPure-\(UUID().uuidString)" : stem
        return "\(resolvedStem).\(fileExtension(mimeType: mimeType, typeIdentifier: typeIdentifier))"
    }

    private static func boundedStem(_ value: String) -> String {
        var result = ""
        for character in value.prefix(maximumFileNameStemLength) {
            let next = String(character)
            guard result.utf8.count + next.utf8.count <= maximumFileNameStemBytes else { break }
            result.append(character)
        }
        return result
    }

    private static func fileExtension(mimeType: String, typeIdentifier: String?) -> String {
        if let typeIdentifier,
           let value = UTType(typeIdentifier)?.preferredFilenameExtension,
           value.isEmpty == false {
            return value.lowercased()
        }
        switch mimeType.lowercased() {
        case "image/gif": return "gif"
        case "image/png": return "png"
        case "image/heic", "image/heif": return "heic"
        case "image/webp": return "webp"
        default: return "jpg"
        }
    }
}

enum TiebaPhotoLibrarySaver {
    static func save(_ payload: TiebaImageDownloadPayload) async throws {
        let status = await authorizationStatus()
        guard status == .authorized || status == .limited else {
            throw TiebaImageDownloadError.photoLibraryAccessDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = payload.fileName
                request.addResource(with: .photo, data: payload.data, options: options)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? TiebaImageDownloadError.photoLibraryWriteFailed)
                }
            }
        }
    }

    private static func authorizationStatus() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}
