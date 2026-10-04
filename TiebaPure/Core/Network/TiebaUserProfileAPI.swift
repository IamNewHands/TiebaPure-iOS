import CoreFoundation
import Foundation

struct UserProfileRequestContext {
    var request: Tiebapure_Profile_UserProfileRequest
    var isCurrentUser: Bool
}

enum UserProfileRequestFactory {
    static let ownThreadDeleteClientVersion = "12.25.1.0"
    /// The mini/subapp client version the JSON reply feed answers to.
    static let ownPostClientVersion = "7.2.0.0"
    /// Category for the reply feed's own entries in 设置 → 诊断日志.
    static let replyFeedLogCategory = "本人回帖"

    static func profileRequest(
        account: Account?,
        user: UserSummary,
        requestBuilder: TiebaRequestBuilder
    ) -> UserProfileRequestContext {
        let currentUserID = account.flatMap { Int64($0.uid) }
        let isCurrentUser = currentUserID != nil && currentUserID == user.id

        var data = Tiebapure_Profile_UserProfileRequestData()
        if let currentUserID {
            data.uid = currentUserID
        }
        if isCurrentUser == false {
            if user.id != 0 {
                data.friendUid = user.id
            } else {
                data.friendUidPortrait = user.portrait
            }
        }
        data.needPostCount = 1
        data.isGuest = isCurrentUser ? 0 : 1
        data.pn = 1
        data.rn = 20
        data.hasPlist_p = 1
        data.common = requestBuilder.common(account: account)
        data.scrW = UInt32(clamping: requestBuilder.screenWidth)
        data.scrH = UInt32(clamping: requestBuilder.screenHeight)
        data.qType = 0
        data.scrDip = requestBuilder.screenScale
        data.isFromUsercenter = 1
        data.page = 1

        var request = Tiebapure_Profile_UserProfileRequest()
        request.data = data
        return UserProfileRequestContext(request: request, isCurrentUser: isCurrentUser)
    }

    static func threadsRequest(
        account: Account?,
        userID: Int64,
        page: Int,
        requestBuilder: TiebaRequestBuilder
    ) throws -> Tiebapure_Profile_UserThreadsRequest {
        let requestedPage = try TiebaRequestValuePolicy.unsignedPage(page)
        var data = Tiebapure_Profile_UserThreadsRequestData()
        data.uid = userID
        data.rn = 20
        data.isThread = 1
        data.needContent = 1
        data.pn = requestedPage
        data.common = requestBuilder.common(account: account)
        data.scrW = Int32(clamping: requestBuilder.screenWidth)
        data.scrH = Int32(clamping: requestBuilder.screenHeight)
        data.scrDip = requestBuilder.screenScale
        data.qType = 1
        data.isViewCard = 1

        var request = Tiebapure_Profile_UserThreadsRequest()
        request.data = data
        return request
    }

    static func followFields(
        account: Account,
        user: UserSummary,
        tbs: String? = nil
    ) throws -> [String: String] {
        let portrait = user.portrait.trimmingCharacters(in: .whitespacesAndNewlines)
        guard portrait.isEmpty == false else {
            throw UserProfileAPIError.missingPortrait
        }
        let resolvedTBS = (tbs ?? account.tbs).trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedTBS.isEmpty == false else {
            throw UserProfileAPIError.missingTBS
        }

        return [
            "BDUSS": account.bduss,
            "portrait": portrait,
            "tbs": resolvedTBS
        ]
    }

    static func profileEditFields(
        account: Account,
        request: UserProfileEditRequest
    ) throws -> [String: String] {
        let nickname = request.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nickname.isEmpty == false else {
            throw UserProfileMutationError.missingNickname
        }
        var fields = [
            "BDUSS": account.bduss,
            "intro": request.introduction,
            "nick_name": nickname
        ]
        // The profile endpoint accepts 1/2 for male/female, but a submitted 0
        // may be normalized to male. Omit the field to preserve an unset value.
        if let sex = request.sex.profileMutationProtocolValue {
            fields["sex"] = "\(sex)"
        }
        return fields
    }

    static func deleteThreadFields(
        account: Account,
        tbs: String,
        target: OwnThreadDeletionTarget,
        requestBuilder: TiebaRequestBuilder,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> [String: String] {
        try validateDeletionTarget(target)
        let resolvedTBS = tbs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedTBS.isEmpty == false else {
            throw UserProfileAPIError.missingTBS
        }
        var fields = requestBuilder.officialCommonFields(
            bduss: account.bduss,
            baiduID: account.baiduID,
            clientVersion: ownThreadDeleteClientVersion,
            timestamp: timestamp
        )
        fields.merge([
            "delete_my_thread": "1",
            "fid": "\(target.forumID)",
            "is_frs_mask": "0",
            "is_vipdel": "0",
            "src": "1",
            "tbs": resolvedTBS,
            "word": target.forumName.trimmingCharacters(in: .whitespacesAndNewlines),
            "z": "\(target.threadID)"
        ], uniquingKeysWith: { _, new in new })
        return fields
    }

    static func validateDeletionTarget(_ target: OwnThreadDeletionTarget) throws {
        guard target.forumID > 0 else {
            throw UserProfileMutationError.invalidForumID
        }
        guard target.forumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw UserProfileMutationError.invalidForumName
        }
        guard target.threadID > 0 else {
            throw UserProfileMutationError.invalidThreadID
        }
        guard target.firstPostID > 0 else {
            throw UserProfileMutationError.invalidFirstPostID
        }
    }

    /// Fields for deleting one of the account's own replies.
    ///
    /// The endpoint is the post twin of `delthread`: the same signed common
    /// fields, but the reply's own post ID in `pid` (`z` stays the thread) and
    /// `delete_my_post = 1` to declare that the author is deleting their own
    /// reply rather than a moderator removing someone else's.
    static func deletePostFields(
        account: Account,
        tbs: String,
        reply: OwnReply,
        requestBuilder: TiebaRequestBuilder,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> [String: String] {
        try validateReplyDeletionTarget(reply)
        let resolvedTBS = tbs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedTBS.isEmpty == false else {
            throw UserProfileAPIError.missingTBS
        }
        var fields = requestBuilder.officialCommonFields(
            bduss: account.bduss,
            baiduID: account.baiduID,
            clientVersion: ownThreadDeleteClientVersion,
            timestamp: timestamp
        )
        fields.merge([
            "delete_my_post": "1",
            "fid": "\(reply.forumID)",
            "is_vipdel": "0",
            "isfloor": "0",
            "pid": "\(reply.id)",
            "src": "1",
            "tbs": resolvedTBS,
            "word": reply.forumName.trimmingCharacters(in: .whitespacesAndNewlines),
            "z": "\(reply.threadID)"
        ], uniquingKeysWith: { _, new in new })
        return fields
    }

    static func validateReplyDeletionTarget(_ reply: OwnReply) throws {
        guard reply.forumID > 0 else {
            throw UserProfileMutationError.invalidForumID
        }
        guard reply.forumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw UserProfileMutationError.invalidForumName
        }
        guard reply.threadID > 0 else {
            throw UserProfileMutationError.invalidThreadID
        }
        guard reply.id > 0 else {
            throw UserProfileMutationError.invalidReplyID
        }
    }
}

enum UserProfileAPIError: Error, Equatable, CustomStringConvertible {
    case missingProfile
    case missingUserIdentifier
    case missingPortrait
    case missingTBS

    var description: String {
        switch self {
        case .missingProfile:
            return "贴吧没有返回可用的用户资料。"
        case .missingUserIdentifier:
            return "缺少用户 ID，无法加载用户帖子。"
        case .missingPortrait:
            return "缺少用户标识，无法修改关注状态。"
        case .missingTBS:
            return "登录状态不完整，请重新登录后再试。"
        }
    }
}

enum UserProfileMutationError: Error, Equatable, CustomStringConvertible {
    case missingNickname
    case invalidForumID
    case invalidForumName
    case invalidThreadID
    case invalidFirstPostID
    case invalidReplyID
    case outcomeUnknown
    case unsupportedByService

    var description: String {
        switch self {
        case .missingNickname:
            return "昵称不能为空。"
        case .invalidForumID:
            return "贴吧 ID 无效，无法删除主题。"
        case .invalidForumName:
            return "贴吧名称无效，无法删除主题。"
        case .invalidThreadID:
            return "主题 ID 无效，无法删除主题。"
        case .invalidFirstPostID:
            return "缺少主题首帖 ID，无法确认删除目标。"
        case .invalidReplyID:
            return "缺少回复 ID，无法删除这条回复。"
        case .outcomeUnknown:
            return "请求已经发出，但未能确认贴吧是否处理成功。请刷新后再决定是否重试。"
        case .unsupportedByService:
            return "当前数据服务不支持该操作。"
        }
    }
}

typealias UserFollowResponseDTO = TiebaMutationResponseDTO

extension TiebaAPI {
    func userProfile(account: Account?, user: UserSummary) async throws -> UserProfile {
        let context = UserProfileRequestFactory.profileRequest(
            account: account,
            user: user,
            requestBuilder: requestBuilder
        )
        let multipart = try requestBuilder.multipart(
            protobuf: context.request,
            account: account,
            includeSToken: false
        )
        let response = try await client.postProtobuf(
            .userProfile,
            body: multipart.body,
            contentType: multipart.contentType,
            headers: ["X-BD-DATA-TYPE": "protobuf"],
            as: Tiebapure_Profile_UserProfileResponse.self
        )
        try TiebaResponseValidator.validate(
            code: Int(response.error.errorCode),
            message: response.error.userMsg.isEmpty ? response.error.errorMsg : response.error.userMsg
        )
        guard response.hasData, response.data.hasUser else {
            throw UserProfileAPIError.missingProfile
        }
        return UserProfileMapper.profile(
            from: response.data.user,
            fallback: user,
            isCurrentUser: context.isCurrentUser
        )
    }

    func userThreads(account: Account?, userID: Int64, page: Int) async throws -> UserThreadsPage {
        guard userID > 0 else { throw UserProfileAPIError.missingUserIdentifier }
        let request = try UserProfileRequestFactory.threadsRequest(
            account: account,
            userID: userID,
            page: page,
            requestBuilder: requestBuilder
        )
        let multipart = try requestBuilder.multipart(
            protobuf: request,
            account: account,
            includeSToken: true
        )
        let response = try await client.postProtobuf(
            .userThreads,
            body: multipart.body,
            contentType: multipart.contentType,
            headers: ["X-BD-DATA-TYPE": "protobuf"],
            as: Tiebapure_Profile_UserThreadsResponse.self
        )
        try TiebaResponseValidator.validate(
            code: Int(response.error.errorCode),
            message: response.error.userMsg.isEmpty ? response.error.errorMsg : response.error.userMsg
        )
        return UserProfileMapper.threadsPage(from: response, page: page)
    }

    /// The account's own replies (本人回帖).
    ///
    /// Same path as `userThreads`, but the JSON/mini form with `is_thread = 0`:
    /// the reply list lives in `post_list[].content[]`, which the committed
    /// protobuf schema has no field for, so the protobuf form can only ever
    /// report thread-level rows. An empty `post_list` with `error_code = 0` is a
    /// server-side answer, not a decode failure, so it is logged as such.
    func userReplies(account: Account?, userID: Int64, page: Int) async throws -> OwnRepliesPage {
        guard userID > 0 else { throw UserProfileAPIError.missingUserIdentifier }
        let requestedPage = try TiebaRequestValuePolicy.unsignedPage(page)
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        var fields = requestBuilder.officialCommonFields(
            bduss: account?.bduss,
            baiduID: account?.baiduID,
            clientVersion: UserProfileRequestFactory.ownPostClientVersion,
            timestamp: timestamp
        )
        fields.merge([
            "is_thread": "0",
            "need_content": "1",
            "pn": "\(requestedPage)",
            "rn": "20",
            "subapp_type": "mini",
            "uid": "\(userID)"
        ], uniquingKeysWith: { _, new in new })

        let response = try await client.postForm(
            .userPosts,
            fields: fields,
            headers: requestBuilder.officialHeaders(
                baiduID: account?.baiduID,
                clientVersion: UserProfileRequestFactory.ownPostClientVersion,
                timestamp: timestamp
            ),
            signingSecret: "tiebaclient!!!",
            as: UserPostFeedDTO.self
        )
        try TiebaResponseValidator.validate(
            code: response.errorCode,
            message: response.errorMessage
        )
        let repliesPage = UserProfileMapper.ownRepliesPage(from: response, page: page)
        if repliesPage.replies.isEmpty {
            await AppLog.shared.record(
                .warning,
                UserProfileRequestFactory.replyFeedLogCategory,
                "第\(requestedPage)页 error_code=0 但 post_list 里没有任何回复"
                    + "（主题行 \(response.threads.count) 条）：接口可能不再返回本人回帖，见该页原始结构"
            )
        } else {
            await AppLog.shared.record(
                .info,
                UserProfileRequestFactory.replyFeedLogCategory,
                "第\(requestedPage)页 主题行 \(response.threads.count) 条 回复 \(repliesPage.replies.count) 条"
            )
        }
        return repliesPage
    }

    func updateOwnProfile(account: Account, request: UserProfileEditRequest) async throws {
        let fields = try UserProfileRequestFactory.profileEditFields(
            account: account,
            request: request
        )
        let response = try await sendFinalUserProfileMutation(
            endpoint: .modifyProfile,
            fields: fields
        )
        try TiebaResponseValidator.validate(
            code: response.errorCode,
            message: response.errorMessage
        )
    }

    func deleteOwnThread(account: Account, target: OwnThreadDeletionTarget) async throws {
        try Task.checkCancellation()
        try UserProfileRequestFactory.validateDeletionTarget(target)
        let tbs = try await refreshedClientTBS(for: account)
        try Task.checkCancellation()
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let fields = try UserProfileRequestFactory.deleteThreadFields(
            account: account,
            tbs: tbs,
            target: target,
            requestBuilder: requestBuilder,
            timestamp: timestamp
        )
        let response = try await sendFinalUserProfileMutation(
            endpoint: .deleteOwnThread,
            fields: fields,
            headers: requestBuilder.officialHeaders(
                baiduID: account.baiduID,
                clientVersion: UserProfileRequestFactory.ownThreadDeleteClientVersion,
                timestamp: timestamp
            )
        )
        try TiebaResponseValidator.validate(
            code: response.errorCode,
            message: response.errorMessage
        )
    }

    /// Deletes one of the account's own replies.
    ///
    /// The reply's own post ID is the target, and the thread ID is only context:
    /// deleting the thread's first post here would remove the whole thread, so a
    /// reply whose own ID is missing is refused before the request is built.
    func deleteOwnReply(account: Account, reply: OwnReply) async throws {
        try Task.checkCancellation()
        try UserProfileRequestFactory.validateReplyDeletionTarget(reply)
        let tbs = try await refreshedClientTBS(for: account)
        try Task.checkCancellation()
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let fields = try UserProfileRequestFactory.deletePostFields(
            account: account,
            tbs: tbs,
            reply: reply,
            requestBuilder: requestBuilder,
            timestamp: timestamp
        )
        let response = try await sendFinalUserProfileMutation(
            endpoint: .deleteOwnPost,
            fields: fields,
            headers: requestBuilder.officialHeaders(
                baiduID: account.baiduID,
                clientVersion: UserProfileRequestFactory.ownThreadDeleteClientVersion,
                timestamp: timestamp
            )
        )
        try TiebaResponseValidator.validate(
            code: response.errorCode,
            message: response.errorMessage
        )
    }

    func setUserFollowed(account: Account, user: UserSummary, followed: Bool) async throws {
        let tbs = try await refreshedClientTBS(for: account)
        try Task.checkCancellation()
        let fields = try UserProfileRequestFactory.followFields(
            account: account,
            user: user,
            tbs: tbs
        )
        let endpoint: TiebaEndpoint = followed ? .followUser : .unfollowUser
        let response = try await client.postForm(
            endpoint,
            fields: fields,
            headers: ["User-Agent": "tieba/\(TiebaClientVersion.v22.rawValue)"],
            signingSecret: "tiebaclient!!!",
            as: UserFollowResponseDTO.self
        )
        try TiebaResponseValidator.validate(code: response.errorCode, message: response.errorMessage)
    }

    private func sendFinalUserProfileMutation(
        endpoint: TiebaEndpoint,
        fields: [String: String],
        headers: [String: String] = ["User-Agent": "tieba/\(TiebaClientVersion.v22.rawValue)"]
    ) async throws -> StrictUserProfileMutationResponse {
        try Task.checkCancellation()
        do {
            let data = try await client.postFormData(
                endpoint,
                fields: fields,
                headers: headers,
                signingSecret: "tiebaclient!!!"
            )
            return try strictUserProfileMutationResponse(from: data)
        } catch {
            // Once the final POST is dispatched, losing its response cannot
            // prove that Tieba did not apply the mutation. Keep this distinct
            // from a preflight failure so callers never retry automatically.
            throw UserProfileMutationError.outcomeUnknown
        }
    }
}

private struct StrictUserProfileMutationResponse {
    var errorCode: Int
    var errorMessage: String
}

/// JSONDecoder accepts integral floating-point tokens such as `0.0` when
/// decoding an Int. Inspect the raw JSON instead, then reconcile every known
/// status alias before treating an already-dispatched mutation as successful.
private func strictUserProfileMutationResponse(
    from data: Data
) throws -> StrictUserProfileMutationResponse {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw UserProfileMutationError.outcomeUnknown
    }

    var containers = [object]
    if let nestedData = object["data"] {
        guard let nestedData = nestedData as? [String: Any] else {
            throw UserProfileMutationError.outcomeUnknown
        }
        containers.append(nestedData)
    }
    var errorString: String?
    if let nestedError = object["error"], nestedError is NSNull == false {
        if let nestedError = nestedError as? [String: Any] {
            containers.append(nestedError)
        } else if let nestedError = nestedError as? String {
            errorString = nestedError
        } else {
            throw UserProfileMutationError.outcomeUnknown
        }
    }

    let integerKeys: Set<String> = [
        "result", "error_code", "err_code", "errno", "error_no", "no"
    ]
    var statusValues: [Int] = []
    for container in containers {
        for key in integerKeys {
            guard let value = container[key] else { continue }
            statusValues.append(try strictUserProfileMutationInteger(value))
        }
    }

    guard let status = statusValues.first,
          statusValues.allSatisfy({ $0 == status }) else {
        throw UserProfileMutationError.outcomeUnknown
    }

    let normalizedErrorString = errorString?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if status == 0, normalizedErrorString?.isEmpty == false {
        throw UserProfileMutationError.outcomeUnknown
    }

    let messageKeys = ["error_msg", "err_msg", "errmsg", "user_msg", "message", "msg"]
    let message = containers.lazy
        .flatMap { container in
            messageKeys.compactMap { key -> String? in
                guard let value = container[key] as? String else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        .first
        ?? normalizedErrorString
        ?? ""
    return StrictUserProfileMutationResponse(
        errorCode: status,
        errorMessage: message
    )
}

private func strictUserProfileMutationInteger(_ value: Any) throws -> Int {
    if let value = value as? String {
        guard let integer = Int(value) else {
            throw UserProfileMutationError.outcomeUnknown
        }
        return integer
    }
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID() else {
        throw UserProfileMutationError.outcomeUnknown
    }
    switch String(cString: number.objCType) {
    case "c", "s", "i", "l", "q", "C", "S", "I", "L", "Q":
        guard let integer = Int(number.stringValue) else {
            throw UserProfileMutationError.outcomeUnknown
        }
        return integer
    default:
        throw UserProfileMutationError.outcomeUnknown
    }
}

/// The JSON (mini/subapp) shape of `/c/u/feed/userpost`.
///
/// One `post_list` row per thread, with the account's own replies nested under
/// `content`: the protobuf shape has a field for the thread but none for those
/// replies, which is why this feed is read as JSON.
struct UserPostFeedDTO: Decodable {
    struct ContentDTO: Decodable {
        var text: String

        enum CodingKeys: String, CodingKey {
            case text
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = container.flexibleString(forKey: .text)
        }
    }

    struct ReplyDTO: Decodable {
        var postID: UInt64
        var createTime: Int
        var contents: [ContentDTO]

        enum CodingKeys: String, CodingKey {
            case postID = "post_id"
            case createTime = "create_time"
            case contents = "post_content"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            postID = container.flexibleUInt64(forKey: .postID)
            createTime = container.flexibleIntValue(forKey: .createTime)
            contents = (try? container.decodeIfPresent([ContentDTO].self, forKey: .contents)) ?? []
        }
    }

    struct ThreadDTO: Decodable {
        var forumID: Int64
        var threadID: Int64
        var forumName: String
        var title: String
        var replies: [ReplyDTO]

        enum CodingKeys: String, CodingKey {
            case forumID = "forum_id"
            case threadID = "thread_id"
            case forumName = "forum_name"
            case title
            case replies = "content"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            forumID = container.flexibleInt64(forKey: .forumID)
            threadID = container.flexibleInt64(forKey: .threadID)
            forumName = container.flexibleString(forKey: .forumName)
            title = container.flexibleString(forKey: .title)
            replies = (try? container.decodeIfPresent([ReplyDTO].self, forKey: .replies)) ?? []
        }
    }

    var errorCode: Int
    var errorMessage: String
    var hidePost: Int
    var threads: [ThreadDTO]

    enum CodingKeys: String, CodingKey {
        case threads = "post_list"
        case errorCode = "error_code"
        case errorMessage = "error_msg"
        case hidePost = "hide_post"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threads = (try? container.decodeIfPresent([ThreadDTO].self, forKey: .threads)) ?? []
        errorCode = Int(container.flexibleString(forKey: .errorCode)) ?? 0
        errorMessage = container.flexibleString(forKey: .errorMessage)
        hidePost = container.flexibleIntValue(forKey: .hidePost)
    }
}

private extension KeyedDecodingContainer {
    func flexibleString(forKey key: Key) -> String {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            // `error_code: 0.0` is a status, not a decimal: keep the integral
            // value so a fractional spelling cannot read as success.
            return value == value.rounded() ? String(Int(value)) : String(value)
        }
        return ""
    }

    func flexibleIntValue(forKey key: Key) -> Int {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return Int(clamping: value) }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value ? 1 : 0 }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int(value) ?? 0 }
        return 0
    }

    func flexibleInt64(forKey key: Key) -> Int64 {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return Int64(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int64(value) ?? 0 }
        return 0
    }

    func flexibleUInt64(forKey key: Key) -> UInt64 {
        if let value = try? decodeIfPresent(UInt64.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key), value > 0 { return UInt64(value) }
        if let value = try? decodeIfPresent(Int.self, forKey: key), value > 0 { return UInt64(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return UInt64(value) ?? 0 }
        return 0
    }
}
