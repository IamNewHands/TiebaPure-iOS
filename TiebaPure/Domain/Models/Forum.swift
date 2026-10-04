import Foundation

struct Forum: Identifiable, Equatable, Codable, Sendable {
    var id: Int64
    var name: String
    var displayName: String
    var avatarURL: URL?
    var memberCount: Int
    var threadCount: Int
}

/// The signed-in account's standing inside one followed forum.
///
/// The followed-forum guide endpoint reports the level, the check-in state and
/// the forum's avatar per row, so the hub can show them without one level
/// request per forum. Kept out of `Forum` itself: the forum list itself still
/// comes from the avatar-carrying endpoint, and a status that failed to load
/// must not invent a forum.
struct FollowedForumStatus: Equatable, Sendable, Identifiable {
    var forumID: Int64
    /// The account's membership level in this forum (0 when unreported).
    var level: Int
    /// Whether the account has already checked in today.
    var isSignedToday: Bool
    /// The forum's avatar. The guide payload carries it and the mapper used to
    /// discard it; the profile's followed-forum rows need it to show a real
    /// image instead of an initial.
    var avatarURL: URL? = nil

    var id: Int64 { forumID }
}

/// Forum avatars by forum ID, filled by the account-scoped endpoints that carry
/// one: `/c/f/forum/getforumlist` (full forum records) and
/// `/c/f/forum/forumGuide` (per-forum guide rows).
///
/// A forum avatar is content-addressed and signed, so it cannot be derived from
/// the forum's name — and `/c/u/user/profile`, the endpoint behind a profile's
/// 关注的吧 list, never returns it. Those rows do carry the forum ID, which is
/// enough to reuse an avatar another endpoint already delivered for the same
/// forum. Session-scoped on purpose: this is a display cache, and a stale entry
/// is no worse than the initial-letter fallback it replaces.
///
/// Deliberately not `@MainActor`: it is written from API layers that hop actors
/// and read from view bodies, so every access goes through the lock instead.
/// SwiftUI does not observe it — a reader copies `snapshot` into its own state.
final class ForumAvatarIndex: @unchecked Sendable {
    static let shared = ForumAvatarIndex()

    private let lock = NSLock()
    private var urlsByForumID: [Int64: URL] = [:]
    private var hasAttemptedFetch = false

    func url(for forumID: Int64) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return urlsByForumID[forumID]
    }

    /// Every known avatar, for a view to publish as its own state.
    var snapshot: [Int64: URL] {
        lock.lock()
        defer { lock.unlock() }
        return urlsByForumID
    }

    /// True only when the index actually holds at least one avatar.
    ///
    /// Deliberately not "an endpoint answered": a guide page whose rows all
    /// failed to parse would otherwise look loaded, and the full followed-forum
    /// list — which carries the same avatars in a different shape — would never
    /// be tried, leaving the profile on initial letters forever.
    var hasData: Bool {
        lock.lock()
        defer { lock.unlock() }
        return urlsByForumID.isEmpty == false
    }

    /// Whether a caller already tried the full-list fetch this session. It
    /// keeps a genuinely avatar-less account from refetching on every profile
    /// view while still retrying after a failed request.
    var needsFetch: Bool {
        lock.lock()
        defer { lock.unlock() }
        return urlsByForumID.isEmpty && hasAttemptedFetch == false
    }

    func markFetchAttempted() {
        lock.lock()
        defer { lock.unlock() }
        hasAttemptedFetch = true
    }

    @discardableResult
    func store(forums: [Forum]) -> Int {
        store(urls: forums.compactMap { forum in
            forum.avatarURL.map { (forum.id, $0) }
        })
    }

    @discardableResult
    func store(statuses: [FollowedForumStatus]) -> Int {
        store(urls: statuses.compactMap { status in
            status.avatarURL.map { (status.forumID, $0) }
        })
    }

    private func store(urls: [(Int64, URL)]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        for (forumID, url) in urls {
            urlsByForumID[forumID] = url
        }
        return urls.count
    }
}
