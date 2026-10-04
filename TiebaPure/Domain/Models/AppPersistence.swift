import Foundation
import SwiftData

// Single app-wide SwiftData container shared by every persisted store. Tests
// build their own container from `models` with an in-memory configuration.
@available(iOS 17.0, *)
enum AppModelContainer {
    struct Resolution {
        let container: ModelContainer
        let availability: PersistenceAvailability

        var isDurable: Bool {
            availability.canPersist
        }
    }

    static let models: [any PersistentModel.Type] = [
        ThreadFavoriteRecord.self,
        ThreadReadingPositionRecord.self,
        ThreadReadingPositionBackendMarkerRecord.self,
        BrowsingHistoryRecord.self,
        RecentForumRecord.self,
        SearchHistoryRecord.self,
        OrderedCollectionBackendMarkerRecord.self,
        ContentDraftRecord.self,
        ContentDraftBackendMarkerRecord.self
    ]

    private static let sharedResolution: Resolution = {
        let schema = Schema(models)
        do {
            return try resolve(
                persistent: {
                    try ModelContainer(
                        for: schema,
                        configurations: ModelConfiguration(schema: schema)
                    )
                },
                fallback: {
                    try ModelContainer(
                        for: schema,
                        configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                    )
                }
            )
        } catch {
            fatalError("ModelContainer creation failed: \(error)")
        }
    }()

    static let shared = sharedResolution.container
    static var sharedAvailability: PersistenceAvailability {
        sharedResolution.availability
    }

    /// Resolves a durable container first and degrades to an in-memory
    /// container only when opening the on-disk store fails. The durability bit
    /// is kept alongside the container so a fallback session can import legacy
    /// values for display without deleting their only durable copy.
    static func resolve(
        persistent: () throws -> ModelContainer,
        fallback: () throws -> ModelContainer
    ) throws -> Resolution {
        do {
            return Resolution(container: try persistent(), availability: .available)
        } catch {
            // The operation string carries the consequence as well as the
            // cause: this one line is what a user-exported diagnostic log shows
            // when local records stop surviving a relaunch and the draft store
            // refuses to open.
            PersistenceDiagnostics.report(
                error,
                operation: "本机数据库打不开，已回退内存库（本次运行不写盘，退出后浏览历史/草稿等本机记录不保留）"
            )
            return Resolution(container: try fallback(), availability: .unavailable)
        }
    }

    static func persistenceAvailability(for container: ModelContainer) -> PersistenceAvailability {
        persistenceAvailability(for: container, resolvedSharedContainer: sharedResolution)
    }

    /// Records where the local records actually live, once per launch.
    ///
    /// A store that opens but comes back empty and a store that never opened
    /// look the same from the outside — 浏览历史 is just empty. This pair of
    /// lines separates them from one exported log: it carries the durability
    /// bit, the on-disk store files with their sizes and timestamps, and the
    /// row count of every model including the three backend markers.
    @MainActor
    static func recordLaunchDiagnostics() {
        PersistenceDiagnostics.note(
            "启动自检：存储="
                + (sharedResolution.availability.canPersist
                    ? "可用"
                    : "不可用（已回退内存库，退出后本机记录不保留）")
                + "；\(storeFileSummary())"
        )
        let context = sharedResolution.container.mainContext
        let counts = [
            rowCount(ThreadFavoriteRecord.self, label: "收藏", in: context),
            rowCount(ThreadReadingPositionRecord.self, label: "阅读进度", in: context),
            rowCount(BrowsingHistoryRecord.self, label: "浏览历史", in: context),
            rowCount(RecentForumRecord.self, label: "最近吧", in: context),
            rowCount(SearchHistoryRecord.self, label: "搜索历史", in: context),
            rowCount(ContentDraftRecord.self, label: "草稿", in: context),
            rowCount(ThreadReadingPositionBackendMarkerRecord.self, label: "进度标记", in: context),
            rowCount(OrderedCollectionBackendMarkerRecord.self, label: "集合标记", in: context),
            rowCount(ContentDraftBackendMarkerRecord.self, label: "草稿标记", in: context)
        ]
        PersistenceDiagnostics.note("启动自检：本机记录数 " + counts.joined(separator: " "))
    }

    private static func rowCount<Model: PersistentModel>(
        _ type: Model.Type,
        label: String,
        in context: ModelContext
    ) -> String {
        do {
            return "\(label)=\(try context.fetchCount(FetchDescriptor<Model>()))"
        } catch {
            return "\(label)=读取失败(\(String(describing: error)))"
        }
    }

    /// The SwiftData default store sits in Application Support next to the file
    /// backends' JSON. Size and modification time tell a store that was
    /// replaced (fresh timestamp, near-empty file) apart from one that kept its
    /// rows, which no in-app screen can show.
    private static func storeFileSummary() -> String {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        var parts: [String] = []
        for configuration in sharedResolution.container.configurations {
            let url = configuration.url
            let name = "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
            guard let values = try? url.resourceValues(forKeys: keys),
                  let size = values.fileSize else {
                parts.append("\(name)=不存在")
                continue
            }
            parts.append("\(name)=\(size)B@\(timestamp(values.contentModificationDate))")
        }
        guard parts.isEmpty else { return parts.sorted().joined(separator: " ") }
        return "容器没有报告 store 路径"
    }

    private static func timestamp(_ date: Date?) -> String {
        guard let date else { return "无时间" }
        return storeTimestampFormatter.string(from: date)
    }

    private static let storeTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    static func persistenceAvailability(
        for container: ModelContainer,
        resolvedSharedContainer: Resolution
    ) -> PersistenceAvailability {
        guard container === resolvedSharedContainer.container else {
            // Explicitly injected containers are owned by their caller (tests
            // use this path) and are considered writable unless the store
            // initializer is given an unavailable override.
            return .available
        }
        return resolvedSharedContainer.availability
    }

    static func allowsLegacyCleanup(for container: ModelContainer) -> Bool {
        allowsLegacyCleanup(for: container, resolvedSharedContainer: sharedResolution)
    }

    static func allowsLegacyCleanup(
        for container: ModelContainer,
        resolvedSharedContainer: Resolution
    ) -> Bool {
        persistenceAvailability(
            for: container,
            resolvedSharedContainer: resolvedSharedContainer
        ).canPersist
    }
}

// Each store persists a full snapshot of its in-memory array; sortIndex
// preserves the array order across relaunches exactly as the legacy JSON
// encoding did.
@available(iOS 17.0, *)
protocol OrderedPersistentRecord: PersistentModel {
    var sortIndex: Int { get }
}

@available(iOS 17.0, *)
@MainActor
enum PersistedRecordStore {
    static func fetchOrdered<Record: OrderedPersistentRecord>(
        _ type: Record.Type,
        in context: ModelContext
    ) throws -> [Record] {
        let records = try context.fetch(FetchDescriptor<Record>())
        return records.sorted { $0.sortIndex < $1.sortIndex }
    }

    static func fetchAll<Record: PersistentModel>(
        _ type: Record.Type,
        in context: ModelContext
    ) throws -> [Record] {
        try context.fetch(FetchDescriptor<Record>())
    }

    static func replaceAll<Record: OrderedPersistentRecord>(
        _ type: Record.Type,
        with records: [Record],
        in context: ModelContext,
        beforeSave: () throws -> Void = {}
    ) throws {
        do {
            let existing = try context.fetch(FetchDescriptor<Record>())
            for record in existing {
                context.delete(record)
            }
            for record in records {
                context.insert(record)
            }
            try beforeSave()
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Updates one reading-position row in place and prunes only duplicates or
    /// rows beyond the retention limit. Scrolling no longer deletes and
    /// reinserts the entire 500-row table for every visible-floor change.
    static func upsertReadingPosition(
        _ position: ThreadReadingPosition,
        limit: Int,
        in context: ModelContext
    ) throws {
        let effectiveLimit = min(
            max(limit, 0),
            LocalThreadLibraryPolicy.maximumReadingPositions
        )
        var records = try context.fetch(FetchDescriptor<ThreadReadingPositionRecord>())
        guard effectiveLimit > 0 else {
            for record in records {
                context.delete(record)
            }
            try save(context)
            return
        }

        if let existing = records.first(where: { $0.threadID == position.threadID }) {
            existing.postIDBitPattern = Int64(bitPattern: position.postID)
            existing.floor = position.floor
            existing.updatedAt = position.updatedAt
        } else {
            let inserted = ThreadReadingPositionRecord(entry: position, sortIndex: 0)
            context.insert(inserted)
            records.append(inserted)
        }

        records.sort {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.threadID < $1.threadID
        }

        var seenThreadIDs = Set<Int64>()
        var retainedCount = 0
        for record in records {
            guard seenThreadIDs.insert(record.threadID).inserted,
                  retainedCount < effectiveLimit else {
                context.delete(record)
                continue
            }
            record.sortIndex = retainedCount
            retainedCount += 1
        }
        try save(context)
    }

    static func deleteReadingPosition(
        threadID: Int64,
        in context: ModelContext
    ) throws {
        let requestedThreadID = threadID
        let records = try context.fetch(FetchDescriptor<ThreadReadingPositionRecord>(
            predicate: #Predicate { record in
                record.threadID == requestedThreadID
            }
        ))
        for record in records {
            context.delete(record)
        }
        try save(context)
    }

    static func clearThreadLibrary(
        in context: ModelContext,
        beforeSave: () throws -> Void = {}
    ) throws {
        do {
            let favorites = try context.fetch(FetchDescriptor<ThreadFavoriteRecord>())
            let positions = try context.fetch(FetchDescriptor<ThreadReadingPositionRecord>())
            for favorite in favorites {
                context.delete(favorite)
            }
            for position in positions {
                context.delete(position)
            }
            try beforeSave()
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
    }

    private static func save(_ context: ModelContext) throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

/// Retired: thread collections live on the Baidu account now. The model stays
/// in the schema so stores written by older versions still open, and its rows
/// are deleted on first launch.
@available(iOS 17.0, *)
@Model
final class ThreadFavoriteRecord {
    var threadID: Int64
    var forumID: Int64?
    var title: String
    var authorDisplayName: String
    var forumDisplayName: String?
    var savedAt: Date
    var sortIndex: Int

    init(
        threadID: Int64 = 0,
        forumID: Int64? = nil,
        title: String = "",
        authorDisplayName: String = "",
        forumDisplayName: String? = nil,
        savedAt: Date = .distantPast,
        sortIndex: Int = 0
    ) {
        self.threadID = threadID
        self.forumID = forumID
        self.title = title
        self.authorDisplayName = authorDisplayName
        self.forumDisplayName = forumDisplayName
        self.savedAt = savedAt
        self.sortIndex = sortIndex
    }
}

@available(iOS 17.0, *)
extension ThreadFavoriteRecord: OrderedPersistentRecord {}

@available(iOS 17.0, *)
@Model
final class ThreadReadingPositionRecord {
    var threadID: Int64
    // UInt64 bit pattern; the backing store has no unsigned 64-bit column.
    var postIDBitPattern: Int64
    var floor: Int
    var updatedAt: Date
    var sortIndex: Int

    init(entry: ThreadReadingPosition, sortIndex: Int) {
        self.threadID = entry.threadID
        self.postIDBitPattern = Int64(bitPattern: entry.postID)
        self.floor = entry.floor
        self.updatedAt = entry.updatedAt
        self.sortIndex = sortIndex
    }

    var entry: ThreadReadingPosition {
        ThreadReadingPosition(
            threadID: threadID,
            postID: UInt64(bitPattern: postIDBitPattern),
            floor: floor,
            updatedAt: updatedAt
        )
    }
}

@available(iOS 17.0, *)
extension ThreadReadingPositionRecord: OrderedPersistentRecord {}

@available(iOS 17.0, *)
@Model
final class ThreadReadingPositionBackendMarkerRecord {
    var key: String
    var formatVersion: Int
    var generationID: String

    init(key: String, formatVersion: Int, generationID: String) {
        self.key = key
        self.formatVersion = formatVersion
        self.generationID = generationID
    }
}

@available(iOS 17.0, *)
@Model
final class BrowsingHistoryRecord {
    var threadID: Int64
    var forumID: Int64?
    var title: String
    var authorDisplayName: String
    var forumDisplayName: String?
    var visitedAt: Date
    var sortIndex: Int

    init(entry: BrowsingHistoryEntry, sortIndex: Int) {
        self.threadID = entry.threadID
        self.forumID = entry.forumID
        self.title = entry.title
        self.authorDisplayName = entry.authorDisplayName
        self.forumDisplayName = entry.forumDisplayName
        self.visitedAt = entry.visitedAt
        self.sortIndex = sortIndex
    }

    var entry: BrowsingHistoryEntry {
        BrowsingHistoryEntry(
            threadID: threadID,
            forumID: forumID,
            title: title,
            authorDisplayName: authorDisplayName,
            forumDisplayName: forumDisplayName,
            visitedAt: visitedAt
        )
    }
}

@available(iOS 17.0, *)
extension BrowsingHistoryRecord: OrderedPersistentRecord {}

@available(iOS 17.0, *)
@Model
final class RecentForumRecord {
    var name: String
    var displayName: String
    var avatarURL: URL?
    var updatedAt: Date
    var sortIndex: Int

    init(entry: RecentForum, sortIndex: Int) {
        self.name = entry.name
        self.displayName = entry.displayName
        self.avatarURL = entry.avatarURL
        self.updatedAt = entry.updatedAt
        self.sortIndex = sortIndex
    }

    var entry: RecentForum {
        RecentForum(
            name: name,
            displayName: displayName,
            avatarURL: avatarURL,
            updatedAt: updatedAt
        )
    }
}

@available(iOS 17.0, *)
extension RecentForumRecord: OrderedPersistentRecord {}

@available(iOS 17.0, *)
@Model
final class SearchHistoryRecord {
    var keyword: String
    var sortIndex: Int

    init(keyword: String, sortIndex: Int) {
        self.keyword = keyword
        self.sortIndex = sortIndex
    }
}

@available(iOS 17.0, *)
extension SearchHistoryRecord: OrderedPersistentRecord {}

@available(iOS 17.0, *)
@Model
final class ContentDraftRecord {
    var accountID: String
    var targetKey: String
    var targetData: Data
    var title: String
    var body: String
    @Attribute(.externalStorage) var imagesBlob: Data
    // Optional so existing stores can migrate without materializing external
    // attachment blobs. Legacy rows are backfilled off the main actor.
    var imagesByteCount: Int?
    var updatedAt: Date

    init(
        accountID: String,
        targetKey: String,
        targetData: Data,
        title: String,
        body: String,
        imagesBlob: Data,
        imagesByteCount: Int? = nil,
        updatedAt: Date
    ) {
        self.accountID = accountID
        self.targetKey = targetKey
        self.targetData = targetData
        self.title = title
        self.body = body
        self.imagesBlob = imagesBlob
        self.imagesByteCount = imagesByteCount ?? imagesBlob.count
        self.updatedAt = updatedAt
    }
}

@available(iOS 17.0, *)
@Model
final class ContentDraftBackendMarkerRecord {
    var key: String
    var formatVersion: Int
    var generationID: String

    init(key: String, formatVersion: Int, generationID: String) {
        self.key = key
        self.formatVersion = formatVersion
        self.generationID = generationID
    }
}
