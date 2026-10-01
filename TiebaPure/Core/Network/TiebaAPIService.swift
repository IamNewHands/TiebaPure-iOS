import Foundation

protocol TiebaAPIService {
    func validateLogin(cookies: BaiduCookies) async throws -> Account
    func personalizedThreads(account: Account?, page: Int, loadType: Int) async throws -> [ThreadSummary]
    func followedForums(account: Account) async throws -> [Forum]
    func forumThreads(
        account: Account?,
        forumName: String,
        page: Int,
        category: ForumThreadCategory
    ) async throws -> [ThreadSummary]
    func searchThreads(
        keyword: String,
        page: Int,
        sortType: Int,
        filterType: Int,
        forumName: String?,
        pageSize: Int
    ) async throws -> SearchResultsPage
    func resolveUser(named name: String) async throws -> UserSummary
    func threadPage(
        account: Account?,
        threadID: Int64,
        page: Int,
        forumID: Int64?,
        postID: UInt64?,
        seeLz: Bool,
        sortType: ThreadReplySort
    ) async throws -> ThreadPage
    func subposts(
        account: Account?,
        threadID: Int64,
        postID: UInt64,
        forumID: Int64,
        page: Int,
        subpostID: UInt64
    ) async throws -> [Subpost]
    func userProfile(account: Account?, user: UserSummary) async throws -> UserProfile
    func userThreads(account: Account?, userID: Int64, page: Int) async throws -> UserThreadsPage
    func updateOwnProfile(account: Account, request: UserProfileEditRequest) async throws
    func deleteOwnThread(account: Account, target: OwnThreadDeletionTarget) async throws
    func setUserFollowed(account: Account, user: UserSummary, followed: Bool) async throws
    func userRelationships(
        account: Account?,
        userID: Int64,
        kind: UserRelationshipKind,
        page: Int
    ) async throws -> UserRelationshipPage
    func forumMembership(account: Account, forum: Forum) async throws -> ForumMembership
    func setForumFollowed(account: Account, forum: Forum, followed: Bool) async throws -> ForumMembership
    func signForum(account: Account, forum: Forum) async throws -> ForumSignResult
    func followedForumStatuses(account: Account) async throws -> [FollowedForumStatus]
    func accountThreadFavorites(account: Account, page: Int) async throws -> AccountThreadFavoritesPage
    func setAccountThreadFavorite(
        account: Account,
        threadID: Int64,
        postID: UInt64,
        favorited: Bool
    ) async throws
    func messages(account: Account, kind: MessageKind, page: Int) async throws -> MessagesPage
    func setPostLiked(
        account: Account,
        threadID: Int64,
        postID: UInt64,
        objectType: TiebaLikeObjectType,
        liked: Bool
    ) async throws
    func submitContent(
        account: Account,
        request: ContentSubmissionRequest
    ) async throws -> ContentSubmissionReceipt
}

extension TiebaAPIService {
    /// Same shape as the other optional write operations: services that do not
    /// implement check-in (test doubles, offline stubs) reject it rather than
    /// having to carry a stub.
    func signForum(account: Account, forum: Forum) async throws -> ForumSignResult {
        throw UserProfileMutationError.unsupportedByService
    }

    /// Level and check-in state per followed forum is optional: services without
    /// the guide listing reject it rather than reporting a wrong level.
    func followedForumStatuses(account: Account) async throws -> [FollowedForumStatus] {
        throw UserProfileMutationError.unsupportedByService
    }

    func accountThreadFavorites(account: Account, page: Int) async throws -> AccountThreadFavoritesPage {
        throw UserProfileMutationError.unsupportedByService
    }

    func setAccountThreadFavorite(
        account: Account,
        threadID: Int64,
        postID: UInt64,
        favorited: Bool
    ) async throws {
        throw UserProfileMutationError.unsupportedByService
    }

    func updateOwnProfile(account: Account, request: UserProfileEditRequest) async throws {
        throw UserProfileMutationError.unsupportedByService
    }

    func deleteOwnThread(account: Account, target: OwnThreadDeletionTarget) async throws {
        throw UserProfileMutationError.unsupportedByService
    }

    func followedUsers(account: Account, page: Int) async throws -> FollowedUsersPage {
        guard let userID = Int64(account.uid), userID > 0 else {
            throw TiebaMutationError.invalidUserID
        }
        return try await userRelationships(
            account: account,
            userID: userID,
            kind: .following,
            page: page
        )
    }

    func forumThreads(account: Account?, forumName: String, page: Int) async throws -> [ThreadSummary] {
        try await forumThreads(
            account: account,
            forumName: forumName,
            page: page,
            category: .replyTime
        )
    }

    func searchThreads(
        keyword: String,
        page: Int,
        sortType: Int = 5,
        filterType: Int = 2,
        forumName: String? = nil,
        pageSize: Int = 30
    ) async throws -> SearchResultsPage {
        try await searchThreads(
            keyword: keyword,
            page: page,
            sortType: sortType,
            filterType: filterType,
            forumName: forumName,
            pageSize: pageSize
        )
    }

    func threadPage(
        account: Account?,
        threadID: Int64,
        page: Int,
        forumID: Int64? = nil,
        postID: UInt64? = nil,
        seeLz: Bool = false,
        sortType: ThreadReplySort = .ascending
    ) async throws -> ThreadPage {
        try await threadPage(
            account: account,
            threadID: threadID,
            page: page,
            forumID: forumID,
            postID: postID,
            seeLz: seeLz,
            sortType: sortType
        )
    }

    func subposts(
        account: Account?,
        threadID: Int64,
        postID: UInt64,
        forumID: Int64,
        page: Int,
        subpostID: UInt64 = 0
    ) async throws -> [Subpost] {
        try await subposts(
            account: account,
            threadID: threadID,
            postID: postID,
            forumID: forumID,
            page: page,
            subpostID: subpostID
        )
    }
}

extension TiebaAPI: TiebaAPIService {}
