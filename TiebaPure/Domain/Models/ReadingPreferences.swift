import CoreGraphics
import CoreText
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ReaderFontSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case standard
    case large
    case extraLarge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small:
            return "较小"
        case .standard:
            return "标准"
        case .large:
            return "较大"
        case .extraLarge:
            return "特大"
        }
    }

    var shortTitle: String {
        switch self {
        case .small:
            return "小"
        case .standard:
            return "标准"
        case .large:
            return "大"
        case .extraLarge:
            return "特大"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small:
            return 0.90
        case .standard:
            return 1
        case .large:
            return 1.12
        case .extraLarge:
            return 1.25
        }
    }
}

struct ReaderFontFamily: RawRepresentable, Equatable, Hashable, Identifiable, Sendable {
    static let system = ReaderFontFamily(validatedRawValue: "system")
    static let serif = ReaderFontFamily(validatedRawValue: "serif")
    static let rounded = ReaderFontFamily(validatedRawValue: "rounded")
    static let monospaced = ReaderFontFamily(validatedRawValue: "monospaced")
    static let builtInChoices = [system, serif, rounded, monospaced]

    let rawValue: String
    var id: String { rawValue }

    init?(rawValue: String) {
        if Self.builtInRawValues.contains(rawValue) {
            self.rawValue = rawValue
            return
        }
        guard rawValue.hasPrefix(Self.importedPrefix),
              let postScriptName = Self.normalizedImportedPostScriptName(
                String(rawValue.dropFirst(Self.importedPrefix.count))
              ),
              rawValue == Self.importedPrefix + postScriptName else {
            return nil
        }
        self.rawValue = rawValue
    }

    static func imported(postScriptName: String) -> ReaderFontFamily? {
        guard let normalized = normalizedImportedPostScriptName(postScriptName) else { return nil }
        return ReaderFontFamily(validatedRawValue: importedPrefix + normalized)
    }

    var importedPostScriptName: String? {
        guard rawValue.hasPrefix(Self.importedPrefix) else { return nil }
        return String(rawValue.dropFirst(Self.importedPrefix.count))
    }

    var title: String {
        switch self {
        case .system: return "系统默认"
        case .serif: return "衬线（西文）"
        case .rounded: return "圆体（西文）"
        case .monospaced: return "等宽（西文）"
        default: return importedPostScriptName ?? "自定义字体"
        }
    }

    fileprivate var systemDesign: UIFontDescriptor.SystemDesign? {
        switch self {
        case .serif: return .serif
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        default: return nil
        }
    }

    private init(validatedRawValue: String) {
        rawValue = validatedRawValue
    }

    private static let importedPrefix = "imported:"
    private static let builtInRawValues: Set<String> = ["system", "serif", "rounded", "monospaced"]

    private static func normalizedImportedPostScriptName(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false,
              normalized.utf8.count <= 512,
              normalized.unicodeScalars.allSatisfy({
                  CharacterSet.controlCharacters.contains($0) == false
              }) else {
            return nil
        }
        return normalized
    }
}

enum ReaderLineSpacing: String, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case relaxed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact:
            return "紧凑"
        case .standard:
            return "标准"
        case .relaxed:
            return "宽松"
        }
    }

    fileprivate var multiplier: CGFloat {
        switch self {
        case .compact:
            return 0.75
        case .standard:
            return 1
        case .relaxed:
            return 1.5
        }
    }
}

enum ReaderMediaLoadingPolicy: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case dataSaving
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "自动加载"
        case .dataSaving:
            return "节省流量"
        case .manual:
            return "手动加载"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "自动加载媒体，失败时尝试备用地址"
        case .dataSaving:
            return "自动加载预览，不额外请求备用原图"
        case .manual:
            return "仅在点击后加载媒体"
        }
    }
}

struct ReadingPreferences: Equatable, Sendable {
    var fontSize: ReaderFontSize
    var fontFamily: ReaderFontFamily = .system
    var lineSpacing: ReaderLineSpacing
    var defaultReplySort: ThreadReplySort
    var mediaLoading: ReaderMediaLoadingPolicy

    static let `default` = ReadingPreferences(
        fontSize: .standard,
        fontFamily: .system,
        lineSpacing: .standard,
        defaultReplySort: .hot,
        mediaLoading: .automatic
    )
}

enum ReaderTextContext: Equatable, Sendable {
    case body
    case subpost
    /// A heading is set larger than the body it introduces, so it needs its own
    /// leading. Reusing the body's gap under a 22pt semibold 标题 leaves the two
    /// heading lines visibly tighter than every reply below them.
    case title
}

enum ReaderTypographyPolicy {
    static func font(
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        fontSize: ReaderFontSize,
        fontFamily: ReaderFontFamily = .system,
        compatibleWith traitCollection: UITraitCollection? = nil
    ) -> UIFont {
        let referenceTraits = UITraitCollection(preferredContentSizeCategory: .large)
        let referenceFont = UIFont.preferredFont(
            forTextStyle: textStyle,
            compatibleWith: referenceTraits
        )
        let pointSize = referenceFont.pointSize * fontSize.scale
        let preferredFont: UIFont
        if let postScriptName = fontFamily.importedPostScriptName,
           let imported = UIFont(name: postScriptName, size: pointSize) {
            let weightedDescriptor = imported.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: weight]
            ])
            preferredFont = UIFont(descriptor: weightedDescriptor, size: pointSize)
        } else {
            let weightedDescriptor = referenceFont.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: weight]
            ])
            let designedDescriptor = fontFamily.systemDesign
                .flatMap { weightedDescriptor.withDesign($0) } ?? weightedDescriptor
            preferredFont = UIFont(descriptor: designedDescriptor, size: pointSize)
        }
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(
            for: preferredFont,
            compatibleWith: traitCollection
        )
    }

    static func lineSpacing(
        _ preference: ReaderLineSpacing,
        context: ReaderTextContext
    ) -> CGFloat {
        let standardSpacing: CGFloat
        switch context {
        case .body:
            standardSpacing = 6
        case .subpost:
            standardSpacing = 2
        case .title:
            standardSpacing = 6
        }
        return standardSpacing * preference.multiplier
    }
}

struct ReaderMediaRequestPolicy: Equatable, Sendable {
    let loadsAutomatically: Bool
    let allowsFallback: Bool

    func allowsLoading(
        sourceIdentity: String,
        manualAuthorization: String?
    ) -> Bool {
        loadsAutomatically || manualAuthorization == sourceIdentity
    }

    func allowsFallback(
        sourceIdentity: String,
        explicitAuthorization: String?
    ) -> Bool {
        allowsFallback || explicitAuthorization == sourceIdentity
    }

    static func resolve(_ preference: ReaderMediaLoadingPolicy) -> ReaderMediaRequestPolicy {
        switch preference {
        case .automatic:
            return ReaderMediaRequestPolicy(loadsAutomatically: true, allowsFallback: true)
        case .dataSaving:
            return ReaderMediaRequestPolicy(loadsAutomatically: true, allowsFallback: false)
        case .manual:
            return ReaderMediaRequestPolicy(loadsAutomatically: false, allowsFallback: true)
        }
    }
}

struct ReaderImageRequestSources: Equatable, Sendable {
    let primaryURL: URL?
    let fallbackURL: URL?
}

enum ReaderImageRequestSourcePolicy {
    static func resolve(
        previewURL: URL?,
        originalURL: URL?,
        requestPolicy: ReaderMediaRequestPolicy,
        sourceIdentity: String,
        explicitOriginalAuthorization: String?
    ) -> ReaderImageRequestSources {
        if explicitOriginalAuthorization == sourceIdentity,
           let originalURL {
            return ReaderImageRequestSources(
                primaryURL: originalURL,
                fallbackURL: nil
            )
        }
        return ReaderImageRequestSources(
            primaryURL: previewURL ?? originalURL,
            fallbackURL: requestPolicy.allowsFallback ? originalURL : nil
        )
    }
}

enum ReaderMediaActivationPolicy {
    static func blocksWhileLoading(
        requestPolicy: ReaderMediaRequestPolicy
    ) -> Bool {
        requestPolicy.loadsAutomatically == false
    }
}

enum ThreadInitialReplySortPolicy {
    static func resolve(
        defaultReplySort: ThreadReplySort,
        initialPostID: UInt64?
    ) -> ThreadReplySort {
        // Server-side post-ID paging is deterministic only in floor order.
        // Search results and deep links therefore take precedence over the
        // user's default for newly opened threads.
        initialPostID == nil ? defaultReplySort : .ascending
    }
}

@MainActor
final class ReadingPreferencesStore: ObservableObject {
    struct StorageKeys: Equatable, Sendable {
        var fontSize: String
        var fontFamily: String = "dev.infinityf4p.tiebapure.reader.font-family"
        var lineSpacing: String
        var defaultReplySort: String
        var mediaLoading: String

        static let live = StorageKeys(
            fontSize: "dev.infinityf4p.tiebapure.reader.font-size",
            fontFamily: "dev.infinityf4p.tiebapure.reader.font-family",
            lineSpacing: "dev.infinityf4p.tiebapure.reader.line-spacing",
            defaultReplySort: "dev.infinityf4p.tiebapure.reader.default-reply-sort",
            mediaLoading: "dev.infinityf4p.tiebapure.reader.media-loading"
        )
    }

    @Published private(set) var preferences: ReadingPreferences

    private let defaults: UserDefaults
    private let keys: StorageKeys

    init(defaults: UserDefaults = .standard, keys: StorageKeys = .live) {
        self.defaults = defaults
        self.keys = keys

        let fontSize = Self.readStringValue(
            ReaderFontSize.self,
            defaultValue: ReadingPreferences.default.fontSize,
            defaults: defaults,
            key: keys.fontSize
        )
        let lineSpacing = Self.readStringValue(
            ReaderLineSpacing.self,
            defaultValue: ReadingPreferences.default.lineSpacing,
            defaults: defaults,
            key: keys.lineSpacing
        )
        let fontFamily = Self.readStringValue(
            ReaderFontFamily.self,
            defaultValue: ReadingPreferences.default.fontFamily,
            defaults: defaults,
            key: keys.fontFamily
        )
        let defaultReplySort = Self.readReplySort(defaults: defaults, key: keys.defaultReplySort)
        let mediaLoading = Self.readStringValue(
            ReaderMediaLoadingPolicy.self,
            defaultValue: ReadingPreferences.default.mediaLoading,
            defaults: defaults,
            key: keys.mediaLoading
        )
        preferences = ReadingPreferences(
            fontSize: fontSize,
            fontFamily: fontFamily,
            lineSpacing: lineSpacing,
            defaultReplySort: defaultReplySort,
            mediaLoading: mediaLoading
        )
    }

    func update(_ preferences: ReadingPreferences) {
        persist(preferences.fontSize, defaultValue: ReadingPreferences.default.fontSize, key: keys.fontSize)
        persist(preferences.fontFamily, defaultValue: ReadingPreferences.default.fontFamily, key: keys.fontFamily)
        persist(preferences.lineSpacing, defaultValue: ReadingPreferences.default.lineSpacing, key: keys.lineSpacing)
        persist(preferences.defaultReplySort, defaultValue: ReadingPreferences.default.defaultReplySort, key: keys.defaultReplySort)
        persist(preferences.mediaLoading, defaultValue: ReadingPreferences.default.mediaLoading, key: keys.mediaLoading)
        self.preferences = preferences
    }

    func select(fontSize: ReaderFontSize) {
        guard preferences.fontSize != fontSize else { return }
        var updated = preferences
        updated.fontSize = fontSize
        persist(fontSize, defaultValue: ReadingPreferences.default.fontSize, key: keys.fontSize)
        preferences = updated
    }

    func select(fontFamily: ReaderFontFamily) {
        guard preferences.fontFamily != fontFamily else { return }
        var updated = preferences
        updated.fontFamily = fontFamily
        persist(fontFamily, defaultValue: ReadingPreferences.default.fontFamily, key: keys.fontFamily)
        preferences = updated
        InlineContentTextMeasurementCache.drain()
    }

    func reconcileAvailableImportedFonts(_ fonts: [ImportedReaderFont]) {
        guard let postScriptName = preferences.fontFamily.importedPostScriptName,
              fonts.contains(where: { $0.postScriptName == postScriptName }) == false else {
            return
        }
        select(fontFamily: .system)
    }

    func select(lineSpacing: ReaderLineSpacing) {
        guard preferences.lineSpacing != lineSpacing else { return }
        var updated = preferences
        updated.lineSpacing = lineSpacing
        persist(lineSpacing, defaultValue: ReadingPreferences.default.lineSpacing, key: keys.lineSpacing)
        preferences = updated
    }

    func select(defaultReplySort: ThreadReplySort) {
        guard preferences.defaultReplySort != defaultReplySort else { return }
        var updated = preferences
        updated.defaultReplySort = defaultReplySort
        persist(
            defaultReplySort,
            defaultValue: ReadingPreferences.default.defaultReplySort,
            key: keys.defaultReplySort
        )
        preferences = updated
    }

    func select(mediaLoading: ReaderMediaLoadingPolicy) {
        guard preferences.mediaLoading != mediaLoading else { return }
        var updated = preferences
        updated.mediaLoading = mediaLoading
        persist(
            mediaLoading,
            defaultValue: ReadingPreferences.default.mediaLoading,
            key: keys.mediaLoading
        )
        preferences = updated
    }

    func reset() {
        defaults.removeObject(forKey: keys.fontSize)
        defaults.removeObject(forKey: keys.fontFamily)
        defaults.removeObject(forKey: keys.lineSpacing)
        defaults.removeObject(forKey: keys.defaultReplySort)
        defaults.removeObject(forKey: keys.mediaLoading)
        preferences = .default
    }

    static func live() -> ReadingPreferencesStore {
        let store = ReadingPreferencesStore()

#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("UITEST_RESET_READING_PREFERENCES") {
            store.reset()
        }
        if arguments.contains("UITEST_READING_REPLY_SORT_DESCENDING") {
            store.select(defaultReplySort: .descending)
        }
        if arguments.contains("UITEST_READING_MEDIA_MANUAL") {
            store.select(mediaLoading: .manual)
        } else if arguments.contains("UITEST_READING_MEDIA_DATA_SAVING") {
            store.select(mediaLoading: .dataSaving)
        }
#endif

        return store
    }

    private static func readStringValue<Value: RawRepresentable>(
        _ type: Value.Type,
        defaultValue: Value,
        defaults: UserDefaults,
        key: String
    ) -> Value where Value.RawValue == String {
        guard let storedObject = defaults.object(forKey: key) else { return defaultValue }
        guard let rawValue = storedObject as? String,
              let value = Value(rawValue: rawValue) else {
            defaults.removeObject(forKey: key)
            return defaultValue
        }
        return value
    }

    private static func readReplySort(defaults: UserDefaults, key: String) -> ThreadReplySort {
        guard let storedObject = defaults.object(forKey: key) else {
            return ReadingPreferences.default.defaultReplySort
        }
        guard let number = storedObject as? NSNumber,
              let value = ThreadReplySort(rawValue: number.intValue) else {
            defaults.removeObject(forKey: key)
            return ReadingPreferences.default.defaultReplySort
        }
        return value
    }

    private func persist<Value: RawRepresentable & Equatable>(
        _ value: Value,
        defaultValue: Value,
        key: String
    ) where Value.RawValue == String {
        if value == defaultValue {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(value.rawValue, forKey: key)
        }
    }

    private func persist(
        _ value: ThreadReplySort,
        defaultValue: ThreadReplySort,
        key: String
    ) {
        if value == defaultValue {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(value.rawValue, forKey: key)
        }
    }
}

struct ImportedReaderFont: Identifiable, Equatable, Codable, Sendable {
    var postScriptName: String
    var displayName: String
    var fileName: String
    var sha256: String
    var importedAt: Date

    var id: String { postScriptName }
    var family: ReaderFontFamily? { .imported(postScriptName: postScriptName) }
}

enum ReaderFontImportPolicy {
    static let supportedFileExtensions = ["ttf", "otf"]

    static var allowedContentTypes: [UTType] {
        let contentTypes = supportedFileExtensions.compactMap {
            UTType(filenameExtension: $0, conformingTo: .data)
        }
        return contentTypes.isEmpty ? [.data] : contentTypes
    }

    static func supports(fileExtension: String) -> Bool {
        supportedFileExtensions.contains(fileExtension.lowercased())
    }
}

enum ReaderFontStoreError: LocalizedError, Equatable {
    case persistenceUnavailable
    case unsupportedFile
    case fileTooLarge
    case tooManyFonts
    case invalidFont
    case nameConflict
    case registrationFailed

    var errorDescription: String? {
        switch self {
        case .persistenceUnavailable:
            return "自定义字体存储暂不可用。"
        case .unsupportedFile:
            return "请选择 TTF 或 OTF 字体文件。"
        case .fileTooLarge:
            return "字体文件超过 20 MB，未导入。"
        case .tooManyFonts:
            return "最多导入 20 个字体，请先删除不再使用的字体。"
        case .invalidFont:
            return "无法识别这个字体文件。"
        case .nameConflict:
            return "已存在同名但内容不同的字体，请先删除旧字体。"
        case .registrationFailed:
            return "字体注册失败，未更改阅读设置。"
        }
    }
}

struct PreparedReaderFontImport: Sendable {
    var data: Data
    var fileExtension: String
    var postScriptName: String
    var displayName: String
    var sha256: String
}

@MainActor
final class ReaderFontStore: ObservableObject {
    static let shared = ReaderFontStore()
    nonisolated static let maximumFontByteCount = 20 * 1_024 * 1_024
    nonisolated static let maximumImportedFonts = 20

    @Published private(set) var entries: [ImportedReaderFont] = []
    @Published private(set) var persistenceError: String?
    @Published private(set) var isReady = false

    private let fileManager: FileManager
    private var catalogFile: SecureCodableFile<[ImportedReaderFont]>?
    private var directoryURL: URL?
    private var isImporting = false

    init(
        baseDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        do {
            let location = try SecurePersistenceLocation.applicationSupport(
                fileManager: fileManager,
                baseDirectoryURL: baseDirectoryURL
            )
            let directoryURL = location.directoryURL
                .appendingPathComponent("reader-fonts", isDirectory: true)
            let catalogFile = try SecureCodableFile<[ImportedReaderFont]>(
                directoryURL: directoryURL,
                fileName: "fonts.json",
                fileManager: fileManager,
                maximumByteCount: 512 * 1_024
            )
            self.directoryURL = directoryURL
            self.catalogFile = catalogFile
            var knownPostScriptNames = Set<String>()
            let candidates = (try catalogFile.load() ?? [])
                .sorted { $0.importedAt < $1.importedAt }
                .filter { knownPostScriptNames.insert($0.postScriptName).inserted }
                .prefix(Self.maximumImportedFonts)
            Task { [weak self] in
                await self?.loadStoredFonts(Array(candidates), directoryURL: directoryURL)
            }
        } catch {
            persistenceError = error.localizedDescription
            isReady = true
        }
    }

    @discardableResult
    func importFont(
        from sourceURL: URL,
        importedAt: Date = Date()
    ) async throws -> ImportedReaderFont {
        let prepared = try await Task.detached(priority: .userInitiated) {
            try Self.prepareImport(from: sourceURL)
        }.value
        return try await importFont(prepared, importedAt: importedAt)
    }

    nonisolated static func prepareImport(from sourceURL: URL) throws -> PreparedReaderFontImport {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard ReaderFontImportPolicy.supports(fileExtension: fileExtension) else {
            throw ReaderFontStoreError.unsupportedFile
        }

        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let values = try sourceURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ReaderFontStoreError.invalidFont
        }
        if let fileSize = values.fileSize, fileSize > maximumFontByteCount {
            throw ReaderFontStoreError.fileTooLarge
        }
        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe, .uncached])
        guard data.isEmpty == false, data.count <= maximumFontByteCount else {
            throw data.count > maximumFontByteCount
                ? ReaderFontStoreError.fileTooLarge
                : ReaderFontStoreError.invalidFont
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let font = CGFont(provider),
              let postScriptName = font.postScriptName as String?,
              ReaderFontFamily.imported(postScriptName: postScriptName) != nil else {
            throw ReaderFontStoreError.invalidFont
        }
        return PreparedReaderFontImport(
            data: data,
            fileExtension: fileExtension,
            postScriptName: postScriptName,
            displayName: (font.fullName as String?) ?? postScriptName,
            sha256: SecurePersistenceDigest.sha256(data)
        )
    }

    @discardableResult
    func importFont(
        _ prepared: PreparedReaderFontImport,
        importedAt: Date = Date()
    ) async throws -> ImportedReaderFont {
        guard isReady, isImporting == false,
              let directoryURL, let catalogFile else {
            throw ReaderFontStoreError.persistenceUnavailable
        }
        guard ReaderFontImportPolicy.supports(fileExtension: prepared.fileExtension),
              prepared.data.isEmpty == false,
              prepared.data.count <= Self.maximumFontByteCount,
              prepared.sha256.utf8.count == 64,
              prepared.sha256.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }),
              ReaderFontFamily.imported(postScriptName: prepared.postScriptName) != nil else {
            throw ReaderFontStoreError.invalidFont
        }
        if let existing = entries.first(where: { $0.postScriptName == prepared.postScriptName }) {
            guard existing.sha256 == prepared.sha256 else {
                throw ReaderFontStoreError.nameConflict
            }
            return existing
        }
        guard entries.count < Self.maximumImportedFonts else {
            throw ReaderFontStoreError.tooManyFonts
        }

        isImporting = true
        defer { isImporting = false }
        let fileName = "\(prepared.sha256).\(prepared.fileExtension)"
        let destinationURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        let destinationExisted = fileManager.fileExists(atPath: destinationURL.path)
        let fileManager = self.fileManager
        let displayName: String
        do {
            displayName = try await Task.detached(priority: .userInitiated) {
                guard prepared.sha256 == SecurePersistenceDigest.sha256(prepared.data),
                      let provider = CGDataProvider(data: prepared.data as CFData),
                      let font = CGFont(provider),
                      font.postScriptName as String? == prepared.postScriptName else {
                    throw ReaderFontStoreError.invalidFont
                }
                try prepared.data.write(to: destinationURL, options: [.atomic])
                try fileManager.setAttributes(
                    Self.protectedFileAttributes,
                    ofItemAtPath: destinationURL.path
                )
                return (font.fullName as String?) ?? prepared.postScriptName
            }.value
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
        guard registerFont(at: destinationURL, postScriptName: prepared.postScriptName),
              UIFont(name: prepared.postScriptName, size: 17) != nil else {
            CTFontManagerUnregisterFontsForURL(destinationURL as CFURL, .process, nil)
            try? fileManager.removeItem(at: destinationURL)
            throw ReaderFontStoreError.registrationFailed
        }

        let imported = ImportedReaderFont(
            postScriptName: prepared.postScriptName,
            displayName: displayName,
            fileName: fileName,
            sha256: prepared.sha256,
            importedAt: importedAt
        )
        do {
            var updated = entries.filter { $0.sha256 != prepared.sha256 }
            updated.append(imported)
            updated.sort { $0.importedAt < $1.importedAt }
            try catalogFile.replace(updated)
            entries = updated
            persistenceError = nil
            return imported
        } catch {
            CTFontManagerUnregisterFontsForURL(destinationURL as CFURL, .process, nil)
            if destinationExisted == false { try? fileManager.removeItem(at: destinationURL) }
            persistenceError = error.localizedDescription
            throw error
        }
    }

    func remove(_ font: ImportedReaderFont) throws {
        guard isReady, isImporting == false,
              let directoryURL, let catalogFile else {
            throw ReaderFontStoreError.persistenceUnavailable
        }
        let updated = entries.filter { $0.id != font.id }
        try catalogFile.replace(updated)
        entries = updated
        let fileURL = directoryURL.appendingPathComponent(font.fileName, isDirectory: false)
        CTFontManagerUnregisterFontsForURL(fileURL as CFURL, .process, nil)
        try? fileManager.removeItem(at: fileURL)
        persistenceError = nil
    }

    func entry(for family: ReaderFontFamily) -> ImportedReaderFont? {
        guard let postScriptName = family.importedPostScriptName else { return nil }
        return entries.first { $0.postScriptName == postScriptName }
    }

    private func loadStoredFonts(
        _ candidates: [ImportedReaderFont],
        directoryURL: URL
    ) async {
        let validated = await Task.detached(priority: .utility) {
            candidates.filter { Self.isStoredFontValid($0, directoryURL: directoryURL) }
        }.value
        entries = validated.compactMap { font in
            let fileURL = directoryURL.appendingPathComponent(font.fileName, isDirectory: false)
            guard registerFont(at: fileURL, postScriptName: font.postScriptName),
                  UIFont(name: font.postScriptName, size: 17) != nil else {
                CTFontManagerUnregisterFontsForURL(fileURL as CFURL, .process, nil)
                return nil
            }
            return font
        }
        let loadedEntries = entries
        let catalogFile = self.catalogFile
        let fileManager = self.fileManager
        do {
            try await Task.detached(priority: .utility) {
                if loadedEntries != candidates {
                    try catalogFile?.replace(loadedEntries)
                }
                let referenced = Set(loadedEntries.map(\.fileName))
                let children = try fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey
                    ],
                    options: []
                )
                for child in children {
                    let fileExtension = child.pathExtension.lowercased()
                    guard ["ttf", "otf"].contains(fileExtension),
                          referenced.contains(child.lastPathComponent) == false else { continue }
                    let values = try child.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey
                    ])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    try fileManager.removeItem(at: child)
                }
            }.value
        } catch {
            persistenceError = error.localizedDescription
        }
        if loadedEntries.count != candidates.count, persistenceError == nil {
            persistenceError = ReaderFontStoreError.registrationFailed.localizedDescription
        }
        isReady = true
    }

    nonisolated private static func isStoredFontValid(
        _ font: ImportedReaderFont,
        directoryURL: URL
    ) -> Bool {
        let fileExtension = (font.fileName as NSString).pathExtension.lowercased()
        guard ["ttf", "otf"].contains(fileExtension),
              font.fileName == "\(font.sha256).\(fileExtension)",
              font.sha256.utf8.count == 64,
              font.sha256.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }),
              ReaderFontFamily.imported(postScriptName: font.postScriptName) != nil else { return false }
        let fileURL = directoryURL.appendingPathComponent(font.fileName, isDirectory: false)
        guard let values = try? fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0,
              (values.fileSize ?? 0) <= Self.maximumFontByteCount,
              let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe, .uncached]),
              SecurePersistenceDigest.sha256(data) == font.sha256,
              let provider = CGDataProvider(data: data as CFData),
              let storedFont = CGFont(provider),
              storedFont.postScriptName as String? == font.postScriptName else { return false }
        return true
    }

    private func registerFont(at url: URL, postScriptName: String) -> Bool {
        if UIFont(name: postScriptName, size: 17) != nil { return true }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        return registered || UIFont(name: postScriptName, size: 17) != nil
    }

    nonisolated private static var protectedFileAttributes: [FileAttributeKey: Any] {
        var attributes: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: Int16(0o600))
        ]
#if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
#endif
        return attributes
    }
}

private struct ReadingPreferencesEnvironmentKey: EnvironmentKey {
    static let defaultValue = ReadingPreferences.default
}

extension EnvironmentValues {
    var readingPreferences: ReadingPreferences {
        get { self[ReadingPreferencesEnvironmentKey.self] }
        set { self[ReadingPreferencesEnvironmentKey.self] = newValue }
    }
}
