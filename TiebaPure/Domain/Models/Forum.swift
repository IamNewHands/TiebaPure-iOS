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
    private var hasLoaded = false

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

    /// Whether any endpoint has delivered avatars in this session. A failed or
    /// never-attempted load keeps this `false`, so the next reader retries.
    var needsLoad: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasLoaded == false
    }

    func store(forums: [Forum]) {
        lock.lock()
        defer { lock.unlock() }
        for forum in forums {
            guard let avatarURL = forum.avatarURL else { continue }
            urlsByForumID[forum.id] = avatarURL
        }
        hasLoaded = true
    }

    func store(statuses: [FollowedForumStatus]) {
        lock.lock()
        defer { lock.unlock() }
        for status in statuses {
            guard let avatarURL = status.avatarURL else { continue }
            urlsByForumID[status.forumID] = avatarURL
        }
        hasLoaded = true
    }
}
