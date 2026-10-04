import Foundation

enum UserContentVisibility: Equatable, Sendable {
    case visible
    case privateContent
}

enum UserProfileSex: Equatable, Sendable {
    case male
    case female
    case unspecified

    var symbolName: String {
        switch self {
        case .male:
            return "person.fill"
        case .female:
            return "person.fill"
        case .unspecified:
            return "person"
        }
    }

    var accessibilityText: String {
        switch self {
        case .male:
            return "男"
        case .female:
            return "女"
        case .unspecified:
            return "性别未公开"
        }
    }

    var profileMutationProtocolValue: Int? {
        switch self {
        case .unspecified:
            return nil
        case .male:
            return 1
        case .female:
            return 2
        }
    }
}

struct UserProfileEditRequest: Equatable, Sendable {
    var nickname: String
    var introduction: String
    var sex: UserProfileSex

    var normalizedNickname: String {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct OwnThreadDeletionTarget: Equatable, Hashable, Sendable {
    var forumID: Int64
    var forumName: String
    var threadID: Int64
    var firstPostID: UInt64
}

struct UserProfile: Equatable, Sendable {
    var user: UserSummary
    var isCurrentUser: Bool
    var isFollowed: Bool
    var tiebaID: String
    var tiebaAge: String
    var sex: UserProfileSex
    var location: String?
    var intro: String
    var backgroundURL: URL?
    var agreeCount: Int
    var followingCount: Int
    var followerCount: Int
    var threadCount: Int
    var followedForumCount: Int
    var followedForums: [Forum]
    var followedForumsVisibility: UserContentVisibility
}

struct UserThreadsPage: Equatable, Sendable {
    var threads: [ThreadSummary]
    var currentPage: Int
    var hasMore: Bool
    var visibility: UserContentVisibility
    var deletionTargetsByThreadID: [Int64: OwnThreadDeletionTarget] = [:]
}

/// One reply the signed-in account wrote, from the same profile feed with
/// `is_thread = 0` instead of `1`.
///
/// Identity is the reply's own post ID, not the thread ID: the account can
/// reply several times in one thread, and keying a list by thread would collapse
/// those rows into one.
struct OwnReply: Identifiable, Equatable, Hashable, Sendable {
    var id: UInt64
    var forumID: Int64
    var forumName: String
    var threadID: Int64
    /// The title of the thread the reply sits in.
    var threadTitle: String
    /// The reply's own text.
    var body: String
    /// True for a 楼中楼 reply. Its post ID is not a floor, so opening the
    /// thread at that ID has nothing to land on; those rows open the thread
    /// itself instead.
    var isSubpost: Bool = false
    var createdAt: Date? = nil
}

struct OwnRepliesPage: Equatable, Sendable {
    var replies: [OwnReply]
    var currentPage: Int
    var hasMore: Bool
    var visibility: UserContentVisibility
}

enum UserProfileManagementPolicy {
    static func canEdit(profile: UserProfile, account: Account?) -> Bool {
        guard profile.isCurrentUser, let account else { return false }
        if let accountID = Int64(account.uid), accountID > 0, profile.user.id > 0 {
            return accountID == profile.user.id
        }
        return account.name.isEmpty == false && account.name == profile.user.name
    }

    static func deletionTarget(
        profile: UserProfile?,
        account: Account?,
        threadID: Int64,
        targetsByThreadID: [Int64: OwnThreadDeletionTarget]
    ) -> OwnThreadDeletionTarget? {
        guard let profile,
              canEdit(profile: profile, account: account),
              let target = targetsByThreadID[threadID],
              target.threadID == threadID,
              target.forumID > 0,
              target.firstPostID > 0 else {
            return nil
        }
        return target
    }

    static func threadDetailDeletionTarget(
        account: Account?,
        threadID: Int64,
        page: ThreadPage?,
        explicitTarget: OwnThreadDeletionTarget?
    ) -> OwnThreadDeletionTarget? {
        guard let account,
              let accountID = Int64(account.uid),
              accountID > 0,
              threadID > 0,
              let page,
              page.thread.id == threadID,
              let mainPost = page.mainPost ?? page.posts.first(where: { $0.floor == 1 }),
              mainPost.id > 0,
              mainPost.author.id == accountID else {
            return nil
        }

        if let explicitTarget,
           explicitTarget.threadID == threadID,
           explicitTarget.forumID > 0,
           explicitTarget.firstPostID == mainPost.id,
           explicitTarget.forumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return explicitTarget
        }

        let forumName = page.forum.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard page.forum.id > 0, forumName.isEmpty == false else { return nil }
        return OwnThreadDeletionTarget(
            forumID: page.forum.id,
            forumName: forumName,
            threadID: threadID,
            firstPostID: mainPost.id
        )
    }

    static func updatedAccount(
        _ account: Account,
        applying request: UserProfileEditRequest
    ) -> Account {
        var updated = account
        updated.displayName = request.normalizedNickname
        return updated
    }

    static func updatedProfile(
        _ profile: UserProfile,
        applying request: UserProfileEditRequest
    ) -> UserProfile {
        var updated = profile
        updated.user.displayName = request.normalizedNickname
        updated.intro = request.introduction
        if request.sex != .unspecified {
            updated.sex = request.sex
        }
        return updated
    }

    static func profile(
        _ profile: UserProfile,
        confirms request: UserProfileEditRequest
    ) -> Bool {
        guard profile.user.displayNameResolved == request.normalizedNickname,
              profile.intro == request.introduction else {
            return false
        }
        return request.sex == .unspecified || profile.sex == request.sex
    }
}

enum OwnThreadDeletionDispatchPolicy {
    static func canSubmit(
        hasValidatedTarget: Bool,
        isSubmitting: Bool,
        hasUnconfirmedOutcome: Bool
    ) -> Bool {
        hasValidatedTarget && isSubmitting == false && hasUnconfirmedOutcome == false
    }
}

enum OwnThreadDeletionNavigationPolicy {
    static func shouldDismissAfterCompletion(isPageVisible: Bool) -> Bool {
        isPageVisible
    }
}

enum UserRelationshipKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case following
    case followers

    var navigationTitle: String {
        switch self {
        case .following: "关注"
        case .followers: "粉丝"
        }
    }
}

struct UserRelationshipPage: Equatable, Sendable {
    var users: [UserSummary]
    var currentPage: Int
    var totalCount: Int
    var hasMore: Bool
}

typealias FollowedUsersPage = UserRelationshipPage

struct ForumMembership: Equatable, Sendable {
    var forumID: Int64
    var isFollowed: Bool
}

enum UserProfilePrivacyPolicy {
    static func followedForumsVisibility(
        isCurrentUser: Bool,
        privacyValue: Int,
        declaredCount: Int,
        returnedCount: Int
    ) -> UserContentVisibility {
        if isCurrentUser || privacyValue == 1 || declaredCount == 0 || returnedCount > 0 {
            return .visible
        }
        return .privateContent
    }
}
