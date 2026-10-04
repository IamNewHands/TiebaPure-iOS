import Foundation
import XCTest
@testable import TiebaPure

final class UserProfileMutationTests: XCTestCase {
    func testLiveReadExactThreadDetail() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TIEBAPURE_RUN_LIVE_ACCOUNT_DELETE"] == "1" else {
            throw XCTSkip("真实账号帖子详情预检仅在显式启用时运行。")
        }
        guard let threadIDText = environment["TIEBAPURE_LIVE_DELETE_THREAD_ID"],
              let threadID = Int64(threadIDText),
              threadID > 0 else {
            XCTFail("真实账号帖子详情预检缺少精确主题 ID。")
            return
        }
        let forumID = environment["TIEBAPURE_LIVE_DELETE_FORUM_ID"]
            .flatMap(Int64.init)

        let accountStore = AccountStore(service: KeychainAccountStoreService())
        let loadedAccount = try await accountStore.load()
        let account = try XCTUnwrap(loadedAccount)
        let api = Self.makeLiveAPI()

        do {
            let page = try await api.threadPage(
                account: account,
                threadID: threadID,
                page: 1,
                forumID: forumID
            )
            XCTAssertEqual(page.thread.id, threadID)
        } catch {
            XCTFail("精确帖子详情读取失败：\(String(reflecting: error))")
        }
    }

    func testLiveReadExactOwnThreadVisibility() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TIEBAPURE_RUN_LIVE_ACCOUNT_DELETE"] == "1" else {
            throw XCTSkip("真实账号删除预检仅在显式启用时运行。")
        }
        guard let threadIDText = environment["TIEBAPURE_LIVE_DELETE_THREAD_ID"],
              let threadID = Int64(threadIDText),
              threadID > 0 else {
            XCTFail("真实账号删除预检缺少精确主题 ID。")
            return
        }

        let accountStore = AccountStore(service: KeychainAccountStoreService())
        let loadedAccount = try await accountStore.load()
        let account = try XCTUnwrap(loadedAccount)
        let userID = try XCTUnwrap(Int64(account.uid))
        let api = Self.makeLiveAPI()

        var visibleTarget: OwnThreadDeletionTarget?
        for page in 1...3 where visibleTarget == nil {
            let result = try await api.userThreads(
                account: account,
                userID: userID,
                page: page
            )
            visibleTarget = result.deletionTargetsByThreadID[threadID]
        }

        XCTAssertNotNil(
            visibleTarget,
            "精确目标不在当前账号最近三页发帖中，禁止继续删除。"
        )
    }

    func testLiveDeleteExactOwnThread() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TIEBAPURE_RUN_LIVE_ACCOUNT_DELETE"] == "1" else {
            throw XCTSkip("真实账号删除测试仅在显式启用时运行。")
        }
        let forumName = (environment["TIEBAPURE_LIVE_DELETE_FORUM_NAME"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let forumIDText = environment["TIEBAPURE_LIVE_DELETE_FORUM_ID"],
              let forumID = Int64(forumIDText),
              forumID > 0,
              forumName.isEmpty == false,
              let threadIDText = environment["TIEBAPURE_LIVE_DELETE_THREAD_ID"],
              let threadID = Int64(threadIDText),
              threadID > 0,
              let firstPostIDText = environment["TIEBAPURE_LIVE_DELETE_FIRST_POST_ID"],
              let firstPostID = UInt64(firstPostIDText),
              firstPostID > 0 else {
            XCTFail("真实账号删除测试缺少完整的精确目标。")
            return
        }

        let accountStore = AccountStore(service: KeychainAccountStoreService())
        let loadedAccount = try await accountStore.load()
        let account = try XCTUnwrap(loadedAccount)
        let api = Self.makeLiveAPI()

        try await api.deleteOwnThread(
            account: account,
            target: OwnThreadDeletionTarget(
                forumID: forumID,
                forumName: forumName,
                threadID: threadID,
                firstPostID: firstPostID
            )
        )
    }

    func testLiveUpdateOwnProfileWithCurrentValues() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TIEBAPURE_RUN_LIVE_PROFILE_UPDATE"] == "1" else {
            throw XCTSkip("真实账号资料原值回写仅在显式启用时运行。")
        }

        let accountStore = AccountStore(service: KeychainAccountStoreService())
        let loadedAccount = try await accountStore.load()
        let account = try XCTUnwrap(loadedAccount)
        let accountUserID = try XCTUnwrap(
            Int64(account.uid).flatMap { $0 > 0 ? $0 : nil }
        )

        let currentUser = UserSummary(
            id: accountUserID,
            name: account.name,
            displayName: account.displayName,
            portrait: account.portrait
        )
        let api = Self.makeLiveAPI()
        let profileBeforeUpdate = try await api.userProfile(
            account: account,
            user: currentUser
        )
        guard profileBeforeUpdate.isCurrentUser,
              profileBeforeUpdate.user.id == accountUserID,
              UserProfileManagementPolicy.canEdit(
                  profile: profileBeforeUpdate,
                  account: account
              ) else {
            XCTFail("资料响应不属于当前账号，禁止发送原值回写请求。")
            return
        }

        let unchangedRequest = UserProfileEditRequest(
            nickname: profileBeforeUpdate.user.displayName,
            introduction: profileBeforeUpdate.intro,
            sex: profileBeforeUpdate.sex
        )
        guard unchangedRequest.normalizedNickname.isEmpty == false else {
            XCTFail("当前资料缺少昵称，禁止发送原值回写请求。")
            return
        }

        try await api.updateOwnProfile(
            account: account,
            request: unchangedRequest
        )

        let profileAfterUpdate = try await api.userProfile(
            account: account,
            user: currentUser
        )
        XCTAssertTrue(profileAfterUpdate.isCurrentUser)
        XCTAssertEqual(profileAfterUpdate.user.id, accountUserID)
        XCTAssertEqual(
            profileAfterUpdate.user.displayName,
            profileBeforeUpdate.user.displayName
        )
        XCTAssertEqual(profileAfterUpdate.intro, profileBeforeUpdate.intro)
        XCTAssertEqual(profileAfterUpdate.sex, profileBeforeUpdate.sex)
    }

    private static func makeLiveAPI() -> TiebaAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return TiebaAPI(client: TiebaHTTPClient(session: SecureRemoteURLSession.make(
            configuration: configuration,
            redirectScope: .baiduHTTPS
        )))
    }

    func testProfileEditFactoryMatchesPinnedAiotiebaShape() throws {
        let fields = try UserProfileRequestFactory.profileEditFields(
            account: Self.account,
            request: UserProfileEditRequest(
                nickname: "  新昵称  ",
                introduction: "  第一行\n第二行  ",
                sex: .female
            )
        )

        XCTAssertEqual(fields, [
            "BDUSS": "fixture-bduss",
            "intro": "  第一行\n第二行  ",
            "nick_name": "新昵称",
            "sex": "2"
        ])
        XCTAssertEqual(TiebaEndpoint.modifyProfile.url.host, "tiebac.baidu.com")
        XCTAssertEqual(TiebaEndpoint.modifyProfile.url.path, "/c/c/profile/modify")
    }

    func testProfileEditFactoryOmitsUnsetSexToPreserveServerValue() throws {
        let fields = try UserProfileRequestFactory.profileEditFields(
            account: Self.account,
            request: UserProfileEditRequest(
                nickname: "夹具账号",
                introduction: "保持简介",
                sex: .unspecified
            )
        )

        XCTAssertEqual(fields, [
            "BDUSS": "fixture-bduss",
            "intro": "保持简介",
            "nick_name": "夹具账号"
        ])
        XCTAssertNil(fields["sex"])
    }

    func testDeleteFactoryRequiresCompleteTargetAndMatchesOfficialV12Shape() throws {
        let fields = try UserProfileRequestFactory.deleteThreadFields(
            account: Self.account,
            tbs: "  fresh-tbs  ",
            target: Self.deletionTarget,
            requestBuilder: Self.requestBuilder,
            timestamp: 1_234
        )

        var expected = Self.requestBuilder.officialCommonFields(
            bduss: Self.account.bduss,
            baiduID: Self.account.baiduID,
            clientVersion: UserProfileRequestFactory.ownThreadDeleteClientVersion,
            timestamp: 1_234
        )
        expected.merge([
            "delete_my_thread": "1",
            "fid": "73",
            "is_frs_mask": "0",
            "is_vipdel": "0",
            "src": "1",
            "tbs": "fresh-tbs",
            "word": "夹具",
            "z": "1001"
        ], uniquingKeysWith: { _, new in new })
        XCTAssertEqual(fields, expected)
        XCTAssertNil(fields["post_id"])
        XCTAssertNil(fields["delete_my_post"])
        XCTAssertEqual(fields["_client_version"], "12.25.1.0")
        XCTAssertEqual(TiebaEndpoint.deleteOwnThread.url.host, "c.tieba.baidu.com")
        XCTAssertEqual(TiebaEndpoint.deleteOwnThread.url.path, "/c/c/bawu/delthread")

        let invalidTargets: [(OwnThreadDeletionTarget, UserProfileMutationError)] = [
            (OwnThreadDeletionTarget(forumID: 0, forumName: "夹具", threadID: 1001, firstPostID: 2001), .invalidForumID),
            (OwnThreadDeletionTarget(forumID: 73, forumName: "  ", threadID: 1001, firstPostID: 2001), .invalidForumName),
            (OwnThreadDeletionTarget(forumID: 73, forumName: "夹具", threadID: 0, firstPostID: 2001), .invalidThreadID),
            (OwnThreadDeletionTarget(forumID: 73, forumName: "夹具", threadID: 1001, firstPostID: 0), .invalidFirstPostID)
        ]
        for (target, expected) in invalidTargets {
            XCTAssertThrowsError(
                try UserProfileRequestFactory.deleteThreadFields(
                    account: Self.account,
                    tbs: "fresh-tbs",
                    target: target,
                    requestBuilder: Self.requestBuilder
                )
            ) { error in
                XCTAssertEqual(error as? UserProfileMutationError, expected)
            }
        }
    }

    func testUserThreadMapperKeepsFirstPostIDForExplicitDeletion() {
        var item = Tiebapure_Profile_UserThreadItem()
        item.forumID = 73
        item.threadID = 1001
        item.postID = 2001
        item.forumName = "夹具"
        item.title = "本人主题"
        item.userID = 42
        item.userName = "fixture"
        item.nameShow = "夹具账号"

        var data = Tiebapure_Profile_UserThreadsResponseData()
        data.postList = [item]
        var response = Tiebapure_Profile_UserThreadsResponse()
        response.data = data

        let page = UserProfileMapper.threadsPage(from: response, page: 1)

        XCTAssertEqual(page.threads.map(\.id), [1001])
        XCTAssertEqual(page.deletionTargetsByThreadID[1001], Self.deletionTarget)

        item.postID = 0
        data.postList = [item]
        response.data = data
        let incompletePage = UserProfileMapper.threadsPage(from: response, page: 1)
        XCTAssertEqual(incompletePage.threads.map(\.id), [1001])
        XCTAssertNil(incompletePage.deletionTargetsByThreadID[1001])
    }

    func testProfileEditSendsOneSignedRequestWithNoExtraFields() async throws {
        let harness = makeAPI(mode: .success)
        defer { ProfileMutationURLProtocol.remove(id: harness.id) }

        try await harness.api.updateOwnProfile(
            account: Self.account,
            request: UserProfileEditRequest(
                nickname: "新昵称",
                introduction: "新简介",
                sex: .male
            )
        )

        let records = ProfileMutationURLProtocol.records(id: harness.id)
        XCTAssertEqual(records.map(\.path), ["/c/c/profile/modify"])
        let request = try XCTUnwrap(records.first)
        let fields = try Self.formFields(request.body)
        XCTAssertEqual(
            Set(fields.keys),
            Set(["BDUSS", "intro", "nick_name", "sex", "sign"])
        )
        XCTAssertEqual(fields["BDUSS"], "fixture-bduss")
        XCTAssertEqual(fields["intro"], "新简介")
        XCTAssertEqual(fields["nick_name"], "新昵称")
        XCTAssertEqual(fields["sex"], "1")
        XCTAssertNotNil(fields["sign"])
        XCTAssertEqual(request.host, "tiebac.baidu.com")
        XCTAssertEqual(request.userAgent, "tieba/\(TiebaClientVersion.v22.rawValue)")
    }

    func testProfileBusinessAndSessionErrorsRemainSpecificAndAreNotRetried() async {
        let cases: [(ProfileMutationStubMode, TiebaAPIError)] = [
            (.businessError, .response(code: 220034, message: "tbs校验失败")),
            (.sessionExpired, .sessionExpired(code: 110001, message: "登录已失效"))
        ]

        for (mode, expected) in cases {
            let harness = makeAPI(mode: mode)
            do {
                try await harness.api.updateOwnProfile(
                    account: Self.account,
                    request: Self.profileEditRequest
                )
                XCTFail("Expected a typed profile mutation error")
            } catch let error as TiebaAPIError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(ProfileMutationURLProtocol.count(
                path: "/c/c/profile/modify",
                id: harness.id
            ), 1)
            ProfileMutationURLProtocol.remove(id: harness.id)
        }
    }

    func testProfileMalformedStatusTypesHaveUnknownOutcomeWithoutRetry() async {
        for payload in Self.malformedMutationResponses {
            let harness = makeAPI(mode: .finalResponse(Data(payload.utf8)))
            do {
                try await harness.api.updateOwnProfile(
                    account: Self.account,
                    request: Self.profileEditRequest
                )
                XCTFail("Expected unknown profile mutation outcome for \(payload)")
            } catch let error as UserProfileMutationError {
                XCTAssertEqual(error, .outcomeUnknown, payload)
            } catch {
                XCTFail("Unexpected error for \(payload): \(error)")
            }
            XCTAssertEqual(ProfileMutationURLProtocol.count(
                path: "/c/c/profile/modify",
                id: harness.id
            ), 1, payload)
            ProfileMutationURLProtocol.remove(id: harness.id)
        }
    }

    func testProfileNestedFailureAliasesRemainSpecificAndAreNotRetried() async {
        let cases: [(String, TiebaAPIError)] = [
            (
                #"{"data":{"err_code":220034,"err_msg":"tbs校验失败"}}"#,
                .response(code: 220034, message: "tbs校验失败")
            ),
            (
                #"{"error":{"errno":"110001","errmsg":"登录已失效"}}"#,
                .sessionExpired(code: 110001, message: "登录已失效")
            )
        ]

        for (payload, expected) in cases {
            let harness = makeAPI(mode: .finalResponse(Data(payload.utf8)))
            do {
                try await harness.api.updateOwnProfile(
                    account: Self.account,
                    request: Self.profileEditRequest
                )
                XCTFail("Expected a nested profile mutation error")
            } catch let error as TiebaAPIError {
                XCTAssertEqual(error, expected, payload)
            } catch {
                XCTFail("Unexpected error for \(payload): \(error)")
            }
            XCTAssertEqual(ProfileMutationURLProtocol.count(
                path: "/c/c/profile/modify",
                id: harness.id
            ), 1, payload)
            ProfileMutationURLProtocol.remove(id: harness.id)
        }
    }

    func testProfileConflictingStatusAliasesHaveUnknownOutcomeWithoutRetry() async {
        let payloads = [
            #"{"error_code":0,"data":{"err_code":220034,"err_msg":"tbs校验失败"}}"#,
            #"{"result":0,"error":{"errno":110001,"errmsg":"登录已失效"}}"#,
            #"{"error_code":7,"err_code":8,"error_msg":"状态冲突"}"#,
            #"{"error_code":0,"error":"请求失败"}"#
        ]

        for payload in payloads {
            let harness = makeAPI(mode: .finalResponse(Data(payload.utf8)))
            do {
                try await harness.api.updateOwnProfile(
                    account: Self.account,
                    request: Self.profileEditRequest
                )
                XCTFail("Expected unknown profile mutation outcome for \(payload)")
            } catch let error as UserProfileMutationError {
                XCTAssertEqual(error, .outcomeUnknown, payload)
            } catch {
                XCTFail("Unexpected error for \(payload): \(error)")
            }
            XCTAssertEqual(ProfileMutationURLProtocol.count(
                path: "/c/c/profile/modify",
                id: harness.id
            ), 1, payload)
            ProfileMutationURLProtocol.remove(id: harness.id)
        }
    }

    func testDeleteRefreshesTBSThenSendsExactlyOneFinalMutation() async throws {
        let harness = makeAPI(mode: .success)
        defer { ProfileMutationURLProtocol.remove(id: harness.id) }

        try await harness.api.deleteOwnThread(
            account: Self.account,
            target: Self.deletionTarget
        )

        let records = ProfileMutationURLProtocol.records(id: harness.id)
        XCTAssertEqual(records.map(\.path), ["/c/s/login", "/c/c/bawu/delthread"])
        let request = try XCTUnwrap(records.last)
        let fields = try Self.formFields(request.body)
        XCTAssertEqual(
            Set(fields.keys),
            Set(Self.requestBuilder.officialCommonFields(
                bduss: Self.account.bduss,
                baiduID: Self.account.baiduID,
                clientVersion: UserProfileRequestFactory.ownThreadDeleteClientVersion
            ).keys)
                .union(["delete_my_thread", "fid", "is_frs_mask", "is_vipdel", "sign", "src", "tbs", "word", "z"])
        )
        XCTAssertEqual(fields["_client_version"], "12.25.1.0")
        XCTAssertEqual(fields["from"], "tieba")
        XCTAssertEqual(fields["delete_my_thread"], "1")
        XCTAssertEqual(fields["is_frs_mask"], "0")
        XCTAssertEqual(fields["fid"], "73")
        XCTAssertEqual(fields["is_vipdel"], "0")
        XCTAssertEqual(fields["src"], "1")
        XCTAssertEqual(fields["tbs"], "fresh-tbs")
        XCTAssertEqual(fields["word"], "夹具")
        XCTAssertEqual(fields["z"], "1001")
        XCTAssertNil(fields["post_id"])
        XCTAssertNil(fields["delete_my_post"])
        XCTAssertEqual(request.userAgent, "bdtb for Android 12.25.1.0")
        XCTAssertEqual(request.host, "c.tieba.baidu.com")
        XCTAssertEqual(fields["sign"], fields["sign"]?.uppercased())
        XCTAssertTrue(request.cookie?.contains("BAIDUID=fixture-baiduid") == true)
        XCTAssertEqual(ProfileMutationURLProtocol.count(
            path: "/c/c/bawu/delthread",
            id: harness.id
        ), 1)
    }

    func testDeleteReplyFieldsTargetTheReplyNotTheThread() throws {
        let fields = try UserProfileRequestFactory.deletePostFields(
            account: Self.account,
            tbs: "  fresh-tbs  ",
            reply: Self.reply,
            requestBuilder: Self.requestBuilder,
            timestamp: 1_234
        )

        var expected = Self.requestBuilder.officialCommonFields(
            bduss: Self.account.bduss,
            baiduID: Self.account.baiduID,
            clientVersion: UserProfileRequestFactory.ownThreadDeleteClientVersion,
            timestamp: 1_234
        )
        expected.merge([
            "delete_my_post": "1",
            "fid": "73",
            "is_vipdel": "0",
            "isfloor": "0",
            "pid": "2001",
            "src": "1",
            "tbs": "fresh-tbs",
            "word": "夹具",
            "z": "1001"
        ], uniquingKeysWith: { _, new in new })
        XCTAssertEqual(fields, expected)
        XCTAssertNil(
            fields["delete_my_thread"],
            "删一条回复不能带上删主题的标记，否则会连主题一起删掉"
        )
        XCTAssertEqual(TiebaEndpoint.deleteOwnPost.url.host, "c.tieba.baidu.com")
        XCTAssertEqual(TiebaEndpoint.deleteOwnPost.url.path, "/c/c/bawu/delpost")

        let invalidTargets: [(OwnReply, UserProfileMutationError)] = [
            (OwnReply(id: 2001, forumID: 0, forumName: "夹具", threadID: 1001, threadTitle: "标题", body: "内容"), .invalidForumID),
            (OwnReply(id: 2001, forumID: 73, forumName: "  ", threadID: 1001, threadTitle: "标题", body: "内容"), .invalidForumName),
            (OwnReply(id: 2001, forumID: 73, forumName: "夹具", threadID: 0, threadTitle: "标题", body: "内容"), .invalidThreadID),
            (OwnReply(id: 0, forumID: 73, forumName: "夹具", threadID: 1001, threadTitle: "标题", body: "内容"), .invalidReplyID)
        ]
        for (reply, expectedError) in invalidTargets {
            XCTAssertThrowsError(
                try UserProfileRequestFactory.deletePostFields(
                    account: Self.account,
                    tbs: "fresh-tbs",
                    reply: reply,
                    requestBuilder: Self.requestBuilder,
                    timestamp: 1_234
                )
            ) { error in
                XCTAssertEqual(error as? UserProfileMutationError, expectedError)
            }
        }
    }

    func testReplyFeedMapsNestedRepliesIntoRows() throws {
        let feed = try JSONDecoder().decode(
            UserPostFeedDTO.self,
            from: Data(Self.replyFeedJSON.utf8)
        )

        let page = UserProfileMapper.ownRepliesPage(from: feed, page: 2)

        XCTAssertEqual(page.currentPage, 2)
        XCTAssertEqual(page.replies.count, 2, "一行主题里嵌着的两条回复都要摊出来")
        XCTAssertEqual(page.replies[0].id, 2001)
        XCTAssertEqual(page.replies[0].forumID, 73)
        XCTAssertEqual(page.replies[0].forumName, "夹具")
        XCTAssertEqual(page.replies[0].threadID, 1001)
        XCTAssertEqual(page.replies[0].threadTitle, "回复：夹具标题")
        XCTAssertEqual(page.replies[0].body, "第一条回复", "多段文字要拼成一条正文")
        XCTAssertEqual(
            page.replies[0].createdAt,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(page.replies[1].id, 2002, "字符串形式的回复 ID 也要解出来")
        XCTAssertNil(page.replies[1].createdAt, "时间戳为 0 时不能编出一个日期")
        XCTAssertEqual(page.replies[1].body, "［非文字内容］", "纯图片回复不能显示成空行")
        XCTAssertFalse(page.replies[0].isSubpost, "post_type=0 是楼层回复，可以定位到楼")
        XCTAssertTrue(page.replies[1].isSubpost, "post_type=1 是楼中楼，没有对应的楼层可跳")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.visibility, .visible)
    }

    func testUserRepliesFetchesTheJSONReplyFeed() async throws {
        let harness = makeAPI(mode: .success)
        defer { ProfileMutationURLProtocol.remove(id: harness.id) }

        let page = try await harness.api.userReplies(
            account: Self.account,
            userID: 42,
            page: 1
        )

        let records = ProfileMutationURLProtocol.records(id: harness.id)
        XCTAssertEqual(records.map(\.path), ["/c/u/feed/userpost"])
        let request = try XCTUnwrap(records.last)
        let fields = try Self.formFields(request.body)
        XCTAssertEqual(fields["is_thread"], "0", "回帖和主题共用同一个接口，靠这个字段切换")
        XCTAssertEqual(fields["need_content"], "1")
        XCTAssertEqual(fields["uid"], "42")
        XCTAssertEqual(fields["pn"], "1")
        XCTAssertEqual(fields["subapp_type"], "mini")
        XCTAssertEqual(fields["_client_version"], UserProfileRequestFactory.ownPostClientVersion)
        XCTAssertNotNil(fields["sign"], "表单接口必须签名")
        XCTAssertEqual(request.host, "c.tieba.baidu.com")
        XCTAssertEqual(page.replies.count, 2)
        XCTAssertEqual(page.replies[0].body, "第一条回复")
    }

    func testDeleteOwnReplyRefreshesTBSThenPostsToDelpost() async throws {
        let harness = makeAPI(mode: .success)
        defer { ProfileMutationURLProtocol.remove(id: harness.id) }

        try await harness.api.deleteOwnReply(account: Self.account, reply: Self.reply)

        let records = ProfileMutationURLProtocol.records(id: harness.id)
        XCTAssertEqual(
            records.map(\.path),
            ["/c/s/login", "/c/c/bawu/delpost"],
            "先取一次 tbs，然后只发一次删除请求"
        )
        let request = try XCTUnwrap(records.last)
        let fields = try Self.formFields(request.body)
        XCTAssertEqual(fields["pid"], "2001", "要删的是这条回复自己的 post id")
        XCTAssertEqual(fields["z"], "1001")
        XCTAssertEqual(fields["delete_my_post"], "1")
        XCTAssertEqual(fields["isfloor"], "0")
        XCTAssertNil(fields["delete_my_thread"])
        XCTAssertEqual(
            ProfileMutationURLProtocol.count(path: "/c/c/bawu/delpost", id: harness.id),
            1,
            "已发出的删除请求不能自动重试"
        )
    }

    func testDeleteBusinessErrorRemainsSpecificAndIsNotRetried() async {
        let harness = makeAPI(mode: .businessError)
        defer { ProfileMutationURLProtocol.remove(id: harness.id) }

        do {
            try await harness.api.deleteOwnThread(
                account: Self.account,
                target: Self.deletionTarget
            )
            XCTFail("Expected business error")
        } catch let error as TiebaAPIError {
            XCTAssertEqual(error, .response(code: 220034, message: "tbs校验失败"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(ProfileMutationURLProtocol.count(
            path: "/c/c/bawu/delthread",
            id: harness.id
        ), 1)
    }

    func testDeleteSessionErrorRemainsSessionExpiredAndIsNotRetried() async {
        let harness = makeAPI(mode: .sessionExpired)
        defer { ProfileMutationURLProtocol.remove(id: harness.id) }

        do {
            try await harness.api.deleteOwnThread(
                account: Self.account,
                target: Self.deletionTarget
            )
            XCTFail("Expected session-expired error")
        } catch let error as TiebaAPIError {
            XCTAssertEqual(
                error,
                .sessionExpired(code: 110001, message: "登录已失效")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(ProfileMutationURLProtocol.count(
            path: "/c/c/bawu/delthread",
            id: harness.id
        ), 1)
    }

    func testIncompleteDeletionTargetStopsBeforeTBSRefresh() async {
        let harness = makeAPI(mode: .success)
        defer { ProfileMutationURLProtocol.remove(id: harness.id) }

        do {
            try await harness.api.deleteOwnThread(
                account: Self.account,
                target: OwnThreadDeletionTarget(
                    forumID: 73,
                    forumName: "夹具",
                    threadID: 1001,
                    firstPostID: 0
                )
            )
            XCTFail("Expected an incomplete target error")
        } catch let error as UserProfileMutationError {
            XCTAssertEqual(error, .invalidFirstPostID)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(ProfileMutationURLProtocol.records(id: harness.id).isEmpty)
    }

    func testDeleteTransportAndDecodeFailuresHaveUnknownOutcomeWithoutRetry() async {
        for mode in [ProfileMutationStubMode.transportFailure, .decodeFailure] {
            let harness = makeAPI(mode: mode)
            defer { ProfileMutationURLProtocol.remove(id: harness.id) }

            do {
                try await harness.api.deleteOwnThread(
                    account: Self.account,
                    target: Self.deletionTarget
                )
                XCTFail("Expected unknown outcome")
            } catch let error as UserProfileMutationError {
                XCTAssertEqual(error, .outcomeUnknown)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(ProfileMutationURLProtocol.count(
                path: "/c/c/bawu/delthread",
                id: harness.id
            ), 1)
        }
    }

    func testDeleteMalformedStatusTypesHaveUnknownOutcomeWithoutRetry() async {
        for payload in Self.malformedMutationResponses {
            let harness = makeAPI(mode: .finalResponse(Data(payload.utf8)))
            do {
                try await harness.api.deleteOwnThread(
                    account: Self.account,
                    target: Self.deletionTarget
                )
                XCTFail("Expected unknown deletion outcome for \(payload)")
            } catch let error as UserProfileMutationError {
                XCTAssertEqual(error, .outcomeUnknown, payload)
            } catch {
                XCTFail("Unexpected error for \(payload): \(error)")
            }
            XCTAssertEqual(ProfileMutationURLProtocol.count(
                path: "/c/c/bawu/delthread",
                id: harness.id
            ), 1, payload)
            ProfileMutationURLProtocol.remove(id: harness.id)
        }
    }

    func testDeleteNestedFailureAliasesRemainSpecificAndAreNotRetried() async {
        let cases: [(String, TiebaAPIError)] = [
            (
                #"{"data":{"error_no":220034,"error_msg":"tbs校验失败"}}"#,
                .response(code: 220034, message: "tbs校验失败")
            ),
            (
                #"{"error":{"no":110001,"errmsg":"登录已失效"}}"#,
                .sessionExpired(code: 110001, message: "登录已失效")
            )
        ]

        for (payload, expected) in cases {
            let harness = makeAPI(mode: .finalResponse(Data(payload.utf8)))
            do {
                try await harness.api.deleteOwnThread(
                    account: Self.account,
                    target: Self.deletionTarget
                )
                XCTFail("Expected a nested deletion error")
            } catch let error as TiebaAPIError {
                XCTAssertEqual(error, expected, payload)
            } catch {
                XCTFail("Unexpected error for \(payload): \(error)")
            }
            XCTAssertEqual(ProfileMutationURLProtocol.count(
                path: "/c/c/bawu/delthread",
                id: harness.id
            ), 1, payload)
            ProfileMutationURLProtocol.remove(id: harness.id)
        }
    }

    func testDeleteConflictingStatusAliasesHaveUnknownOutcomeWithoutRetry() async {
        let payloads = [
            #"{"error_code":0,"data":{"error_no":220034,"error_msg":"tbs校验失败"}}"#,
            #"{"result":0,"error":{"no":110001,"errmsg":"登录已失效"}}"#,
            #"{"errno":7,"no":8,"error_msg":"状态冲突"}"#,
            #"{"error_code":0,"error":"请求失败"}"#
        ]

        for payload in payloads {
            let harness = makeAPI(mode: .finalResponse(Data(payload.utf8)))
            do {
                try await harness.api.deleteOwnThread(
                    account: Self.account,
                    target: Self.deletionTarget
                )
                XCTFail("Expected unknown deletion outcome for \(payload)")
            } catch let error as UserProfileMutationError {
                XCTAssertEqual(error, .outcomeUnknown, payload)
            } catch {
                XCTFail("Unexpected error for \(payload): \(error)")
            }
            XCTAssertEqual(ProfileMutationURLProtocol.count(
                path: "/c/c/bawu/delthread",
                id: harness.id
            ), 1, payload)
            ProfileMutationURLProtocol.remove(id: harness.id)
        }
    }

    func testCancellationBeforeDeleteDispatchMakesNoNetworkRequest() async {
        let harness = makeAPI(mode: .success)
        defer { ProfileMutationURLProtocol.remove(id: harness.id) }
        let operation = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            try await harness.api.deleteOwnThread(
                account: Self.account,
                target: Self.deletionTarget
            )
        }

        do {
            try await operation.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected before even the read-only TBS refresh.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(ProfileMutationURLProtocol.records(id: harness.id).isEmpty)
    }

    func testCancellationAfterDeleteDispatchHasUnknownOutcomeWithoutRetry() async throws {
        let harness = makeAPI(mode: .holdFinalRequest)
        defer { ProfileMutationURLProtocol.remove(id: harness.id) }
        let operation = Task {
            try await harness.api.deleteOwnThread(
                account: Self.account,
                target: Self.deletionTarget
            )
        }

        try await waitForRequest(path: "/c/c/bawu/delthread", id: harness.id)
        operation.cancel()

        do {
            try await operation.value
            XCTFail("Expected unknown outcome")
        } catch let error as UserProfileMutationError {
            XCTAssertEqual(error, .outcomeUnknown)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(ProfileMutationURLProtocol.count(
            path: "/c/c/bawu/delthread",
            id: harness.id
        ), 1)
    }

    func testSameUIDMetadataUpdateDoesNotInvalidateAccountScopedState() {
        var updated = Self.account
        updated.name = "new-account-name"
        updated.displayName = "已修改昵称"
        updated.portrait = "new-portrait"
        updated.tbs = "refreshed-tbs"

        XCTAssertNil(AccountTransitionPolicy.invalidatedAccountID(
            previous: Self.account,
            next: updated
        ))
    }

    func testSameUIDCredentialReplacementInvalidatesAccountScopedState() {
        var replacedBDUSS = Self.account
        replacedBDUSS.bduss = "replacement-bduss"
        XCTAssertEqual(AccountTransitionPolicy.invalidatedAccountID(
            previous: Self.account,
            next: replacedBDUSS
        ), "42")

        var replacedSTOKEN = Self.account
        replacedSTOKEN.stoken = "replacement-stoken"
        XCTAssertEqual(AccountTransitionPolicy.invalidatedAccountID(
            previous: Self.account,
            next: replacedSTOKEN
        ), "42")

        var replacedBAIDUID = Self.account
        replacedBAIDUID.baiduID = "replacement-baiduid"
        XCTAssertEqual(AccountTransitionPolicy.invalidatedAccountID(
            previous: Self.account,
            next: replacedBAIDUID
        ), "42")

        replacedBAIDUID.baiduID = nil
        XCTAssertEqual(AccountTransitionPolicy.invalidatedAccountID(
            previous: Self.account,
            next: replacedBAIDUID
        ), "42")
    }

    func testLogoutOrDifferentUIDInvalidatesPreviousAccountScopedState() {

        var replacement = Self.account
        replacement.uid = "99"
        XCTAssertEqual(AccountTransitionPolicy.invalidatedAccountID(
            previous: Self.account,
            next: replacement
        ), "42")
        XCTAssertEqual(AccountTransitionPolicy.invalidatedAccountID(
            previous: Self.account,
            next: nil
        ), "42")
    }

    func testOnlyLoggedOutToLoggedInTransitionReleasesGlobalWriteBarrier() {
        XCTAssertTrue(AccountTransitionPolicy.shouldReleaseGlobalInvalidation(
            previous: nil,
            next: Self.account
        ))

        var metadataUpdate = Self.account
        metadataUpdate.displayName = "新昵称"
        XCTAssertFalse(AccountTransitionPolicy.shouldReleaseGlobalInvalidation(
            previous: Self.account,
            next: metadataUpdate
        ))
        XCTAssertFalse(AccountTransitionPolicy.shouldReleaseGlobalInvalidation(
            previous: Self.account,
            next: nil
        ))
        XCTAssertFalse(AccountTransitionPolicy.shouldReleaseGlobalInvalidation(
            previous: nil,
            next: nil
        ))
    }

    func testManagementPolicyExposesEditingAndDeletionOnlyForMatchingCurrentUser() throws {
        let profile = Self.currentUserProfile
        let target = Self.deletionTarget

        XCTAssertTrue(UserProfileManagementPolicy.canEdit(
            profile: profile,
            account: Self.account
        ))
        XCTAssertEqual(UserProfileManagementPolicy.deletionTarget(
            profile: profile,
            account: Self.account,
            threadID: target.threadID,
            targetsByThreadID: [target.threadID: target]
        ), target)

        var otherProfile = profile
        otherProfile.isCurrentUser = false
        XCTAssertFalse(UserProfileManagementPolicy.canEdit(
            profile: otherProfile,
            account: Self.account
        ))
        XCTAssertNil(UserProfileManagementPolicy.deletionTarget(
            profile: otherProfile,
            account: Self.account,
            threadID: target.threadID,
            targetsByThreadID: [target.threadID: target]
        ))

        var mismatchedAccount = Self.account
        mismatchedAccount.uid = "99"
        XCTAssertFalse(UserProfileManagementPolicy.canEdit(
            profile: profile,
            account: mismatchedAccount
        ))
    }

    func testThreadDetailDerivesDeletionTargetOnlyForExactCurrentAuthor() {
        let page = Self.ownThreadPage

        XCTAssertEqual(
            UserProfileManagementPolicy.threadDetailDeletionTarget(
                account: Self.account,
                threadID: page.thread.id,
                page: page,
                explicitTarget: nil
            ),
            Self.deletionTarget
        )

        var otherAccount = Self.account
        otherAccount.uid = "99"
        XCTAssertNil(UserProfileManagementPolicy.threadDetailDeletionTarget(
            account: otherAccount,
            threadID: page.thread.id,
            page: page,
            explicitTarget: nil
        ))
        XCTAssertNil(UserProfileManagementPolicy.threadDetailDeletionTarget(
            account: nil,
            threadID: page.thread.id,
            page: page,
            explicitTarget: Self.deletionTarget
        ))
    }

    func testThreadDetailRejectsIncompleteOrMismatchedDeletionMetadata() {
        var page = Self.ownThreadPage
        page.forum.id = 0
        XCTAssertNil(UserProfileManagementPolicy.threadDetailDeletionTarget(
            account: Self.account,
            threadID: page.thread.id,
            page: page,
            explicitTarget: nil
        ))

        var mismatchedTarget = Self.deletionTarget
        mismatchedTarget.firstPostID += 1
        XCTAssertNil(UserProfileManagementPolicy.threadDetailDeletionTarget(
            account: Self.account,
            threadID: page.thread.id,
            page: page,
            explicitTarget: mismatchedTarget
        ))
    }

    func testManagementPolicyAppliesProfileEditWithoutChangingAccountIdentityOrCredentials() {
        let request = UserProfileEditRequest(
            nickname: "  新昵称  ",
            introduction: "新的个人简介",
            sex: .female
        )

        let updatedAccount = UserProfileManagementPolicy.updatedAccount(
            Self.account,
            applying: request
        )
        XCTAssertEqual(updatedAccount.uid, Self.account.uid)
        XCTAssertEqual(updatedAccount.name, Self.account.name)
        XCTAssertEqual(updatedAccount.displayName, "新昵称")
        XCTAssertEqual(updatedAccount.bduss, Self.account.bduss)
        XCTAssertEqual(updatedAccount.stoken, Self.account.stoken)
        XCTAssertEqual(updatedAccount.baiduID, Self.account.baiduID)

        let updatedProfile = UserProfileManagementPolicy.updatedProfile(
            Self.currentUserProfile,
            applying: request
        )
        XCTAssertEqual(updatedProfile.user.displayName, "新昵称")
        XCTAssertEqual(updatedProfile.intro, "新的个人简介")
        XCTAssertEqual(updatedProfile.sex, .female)

        var maleProfile = Self.currentUserProfile
        maleProfile.sex = .male
        let preservingRequest = UserProfileEditRequest(
            nickname: "原昵称",
            introduction: "原简介",
            sex: .unspecified
        )
        XCTAssertEqual(
            UserProfileManagementPolicy.updatedProfile(
                maleProfile,
                applying: preservingRequest
            ).sex,
            .male
        )
    }

    func testMutationPresentationRequiresReadOnlyRefreshForUnknownOutcome() {
        XCTAssertEqual(
            UserProfileMutationPresentationPolicy.failure(
                for: UserProfileMutationError.outcomeUnknown
            ),
            .resultPending
        )
        XCTAssertEqual(
            UserProfileMutationPresentationPolicy.failure(
                for: UserProfileMutationError.missingNickname
            ),
            .retryable(message: "昵称不能为空。")
        )
    }

    func testProfileConfirmationRequiresMatchingServerValues() {
        let request = UserProfileEditRequest(
            nickname: "  新昵称  ",
            introduction: "新的个人简介",
            sex: .female
        )
        var confirmed = Self.currentUserProfile
        confirmed.user.displayName = "新昵称"
        confirmed.intro = "新的个人简介"
        confirmed.sex = .female

        XCTAssertTrue(UserProfileManagementPolicy.profile(confirmed, confirms: request))

        var staleNickname = confirmed
        staleNickname.user.displayName = "旧昵称"
        XCTAssertFalse(UserProfileManagementPolicy.profile(staleNickname, confirms: request))

        var staleIntro = confirmed
        staleIntro.intro = "旧简介"
        XCTAssertFalse(UserProfileManagementPolicy.profile(staleIntro, confirms: request))

        var staleSex = confirmed
        staleSex.sex = .male
        XCTAssertFalse(UserProfileManagementPolicy.profile(staleSex, confirms: request))
    }

    func testProfileConfirmationTreatsUnspecifiedSexAsPreserveExistingValue() {
        var profile = Self.currentUserProfile
        profile.user.displayName = "现有昵称"
        profile.intro = "现有简介"
        profile.sex = .male

        XCTAssertTrue(UserProfileManagementPolicy.profile(
            profile,
            confirms: UserProfileEditRequest(
                nickname: "现有昵称",
                introduction: "现有简介",
                sex: .unspecified
            )
        ))
    }

    func testDeletionDispatchPolicyNeverResubmitsAfterUnknownOutcome() {
        XCTAssertTrue(OwnThreadDeletionDispatchPolicy.canSubmit(
            hasValidatedTarget: true,
            isSubmitting: false,
            hasUnconfirmedOutcome: false
        ))
        XCTAssertFalse(OwnThreadDeletionDispatchPolicy.canSubmit(
            hasValidatedTarget: false,
            isSubmitting: false,
            hasUnconfirmedOutcome: false
        ))
        XCTAssertFalse(OwnThreadDeletionDispatchPolicy.canSubmit(
            hasValidatedTarget: true,
            isSubmitting: true,
            hasUnconfirmedOutcome: false
        ))
        XCTAssertFalse(OwnThreadDeletionDispatchPolicy.canSubmit(
            hasValidatedTarget: true,
            isSubmitting: false,
            hasUnconfirmedOutcome: true
        ))
    }

    func testDeletionCompletionDismissesOnlyWhileDetailPageIsStillVisible() {
        XCTAssertTrue(OwnThreadDeletionNavigationPolicy.shouldDismissAfterCompletion(
            isPageVisible: true
        ))
        XCTAssertFalse(OwnThreadDeletionNavigationPolicy.shouldDismissAfterCompletion(
            isPageVisible: false
        ))
    }

    @MainActor
    func testUnknownDeletionStateSurvivesDetailRecreationUntilConfirmedDeleted() {
        let state = OwnThreadMutationState()

        state.publish(accountID: "42", threadID: 9001, outcome: .needsRefresh)

        XCTAssertTrue(state.hasUnconfirmedDeletion(accountID: "42", threadID: 9001))
        XCTAssertFalse(state.hasUnconfirmedDeletion(accountID: "42", threadID: 9002))
        XCTAssertFalse(state.hasUnconfirmedDeletion(accountID: "84", threadID: 9001))
        XCTAssertFalse(OwnThreadDeletionDispatchPolicy.canSubmit(
            hasValidatedTarget: true,
            isSubmitting: false,
            hasUnconfirmedOutcome: state.hasUnconfirmedDeletion(
                accountID: "42",
                threadID: 9001
            )
        ))

        state.publish(accountID: "42", threadID: 9001, outcome: .deleted)

        XCTAssertFalse(state.hasUnconfirmedDeletion(accountID: "42", threadID: 9001))
        XCTAssertTrue(OwnThreadDeletionDispatchPolicy.canSubmit(
            hasValidatedTarget: true,
            isSubmitting: false,
            hasUnconfirmedOutcome: state.hasUnconfirmedDeletion(
                accountID: "42",
                threadID: 9001
            )
        ))
    }

#if DEBUG
    func testFixturePersistsProfileEditAndRemovesDeletedThreadOnReadOnlyReload() async throws {
        let api = FixtureTiebaAPI()
        let account = FixtureTiebaAPI.account
        let user = UserSummary(
            id: Int64(account.uid) ?? 0,
            name: account.name,
            displayName: account.displayName,
            portrait: account.portrait
        )
        let request = UserProfileEditRequest(
            nickname: "夹具新昵称",
            introduction: "夹具新简介",
            sex: .male
        )

        try await api.updateOwnProfile(account: account, request: request)
        let editedProfile = try await api.userProfile(account: account, user: user)
        XCTAssertEqual(editedProfile.user.displayName, "夹具新昵称")
        XCTAssertEqual(editedProfile.intro, "夹具新简介")
        XCTAssertEqual(editedProfile.sex, .male)

        let beforeDeletion = try await api.userThreads(
            account: account,
            userID: user.id,
            page: 1
        )
        let threadID = try XCTUnwrap(beforeDeletion.threads.first?.id)
        let target = try XCTUnwrap(beforeDeletion.deletionTargetsByThreadID[threadID])
        try await api.deleteOwnThread(account: account, target: target)

        let afterDeletion = try await api.userThreads(
            account: account,
            userID: user.id,
            page: 1
        )
        XCTAssertFalse(afterDeletion.threads.contains { $0.id == threadID })
        XCTAssertNil(afterDeletion.deletionTargetsByThreadID[threadID])
    }
#endif

    private func makeAPI(mode: ProfileMutationStubMode) -> (api: TiebaAPI, id: String) {
        let id = UUID().uuidString
        ProfileMutationURLProtocol.register(mode: mode, id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProfileMutationURLProtocol.self]
        configuration.httpAdditionalHeaders = [ProfileMutationURLProtocol.testIDHeader: id]
        return (
            TiebaAPI(
                client: TiebaHTTPClient(session: URLSession(configuration: configuration)),
                requestBuilder: Self.requestBuilder
            ),
            id
        )
    }

    private func waitForRequest(path: String, id: String) async throws {
        for _ in 0..<200 {
            if ProfileMutationURLProtocol.count(path: path, id: id) == 1 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(path)")
    }

    private static func formFields(_ data: Data?) throws -> [String: String] {
        let body = try XCTUnwrap(data)
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        var components = URLComponents()
        components.percentEncodedQuery = text
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
    }

    private static let account = Account(
        uid: "42",
        name: "fixture",
        displayName: "夹具账号",
        portrait: "fixture-portrait",
        bduss: "fixture-bduss",
        stoken: "fixture-stoken",
        baiduID: "fixture-baiduid",
        tbs: "stale-tbs"
    )

    private static let profileEditRequest = UserProfileEditRequest(
        nickname: "新昵称",
        introduction: "新简介",
        sex: .female
    )

    private static let malformedMutationResponses = [
        #"{"error_code":false,"error_msg":""}"#,
        #"{"error_code":0.0,"error_msg":""}"#,
        #"{"error_code":{"value":0},"error_msg":""}"#,
        #"{"error_code":null,"error_msg":""}"#,
        #"{"error_code":0,"result":true,"error_msg":""}"#,
        #"{"error_code":0,"data":{"error_code":false},"error_msg":""}"#,
        #"{"error_code":0,"data":{"result":0.0},"error_msg":""}"#,
        #"{"error_code":0,"data":{"err_code":{"value":0}},"error_msg":""}"#,
        #"{"error_code":0,"data":{"errno":null},"error_msg":""}"#,
        #"{"error_code":0,"error":{"errno":0.0,"errmsg":""},"error_msg":""}"#,
        #"{"error_code":0,"data":true,"error_msg":""}"#,
        #"{"error_code":0,"data":[],"error_msg":""}"#,
        #"{"error_code":0,"data":null,"error_msg":""}"#
    ]

    private static let deletionTarget = OwnThreadDeletionTarget(
        forumID: 73,
        forumName: "夹具",
        threadID: 1001,
        firstPostID: 2001
    )

    private static let reply = OwnReply(
        id: 2001,
        forumID: 73,
        forumName: "夹具",
        threadID: 1001,
        threadTitle: "回复：夹具标题",
        body: "第一条回复"
    )

    /// One `post_list` row per thread with the account's own replies nested
    /// under `content`, which is the shape the JSON reply feed answers with.
    private static let replyFeedJSON = profileMutationReplyFeedJSON

    private static let ownThreadPage = ThreadPage(
        thread: ThreadSummary(
            id: 1001,
            forumID: 73,
            title: "本人主题",
            author: UserSummary(
                id: 42,
                name: "fixture",
                displayName: "夹具账号",
                portrait: "fixture-portrait"
            ),
            forumName: "夹具",
            replyCount: 0,
            viewCount: 0,
            blocks: [],
            isTop: false,
            isGood: false,
            hasVideo: false
        ),
        forum: Forum(
            id: 73,
            name: "夹具",
            displayName: "夹具吧",
            avatarURL: nil,
            memberCount: 0,
            threadCount: 0
        ),
        mainPost: Post(
            id: 2001,
            threadID: 1001,
            floor: 1,
            author: UserSummary(
                id: 42,
                name: "fixture",
                displayName: "夹具账号",
                portrait: "fixture-portrait"
            ),
            ipAddress: nil,
            createdAt: nil,
            blocks: [],
            subpostCount: 0,
            likeCount: 0,
            previewSubposts: []
        ),
        posts: [],
        currentPage: 1,
        totalPage: 1,
        hasMore: false
    )

    private static let currentUserProfile = UserProfile(
        user: UserSummary(
            id: 42,
            name: "fixture",
            displayName: "夹具账号",
            portrait: "fixture-portrait"
        ),
        isCurrentUser: true,
        isFollowed: false,
        tiebaID: "42",
        tiebaAge: "1年",
        sex: .unspecified,
        location: nil,
        intro: "原简介",
        backgroundURL: nil,
        agreeCount: 0,
        followingCount: 0,
        followerCount: 0,
        threadCount: 1,
        followedForumCount: 0,
        followedForums: [],
        followedForumsVisibility: .visible
    )

    private static let requestBuilder = TiebaRequestBuilder(
        screenScale: 3,
        screenWidth: 1179,
        screenHeight: 2556,
        clientID: "profile-mutation-test"
    )
}

/// One `post_list` row per thread with the account's own replies nested under
/// `content` — the shape `/c/u/feed/userpost` answers with for `is_thread = 0`.
private let profileMutationReplyFeedJSON = """
{
  "error_code": 0,
  "error_msg": "",
  "hide_post": 0,
  "post_list": [
    {
      "forum_id": 73,
      "thread_id": 1001,
      "forum_name": "夹具",
      "title": "回复：夹具标题",
      "content": [
        {
          "post_id": 2001,
          "create_time": 1700000000,
          "post_type": 0,
          "post_content": [
            { "type": 0, "text": "第一条" },
            { "type": 0, "text": "回复" }
          ]
        },
        {
          "post_id": "2002",
          "create_time": 0,
          "post_type": 1,
          "post_content": [ { "type": 3, "text": "" } ]
        }
      ]
    }
  ]
}
"""

private enum ProfileMutationStubMode: Sendable {
    case success
    case businessError
    case sessionExpired
    case finalResponse(Data)
    case transportFailure
    case decodeFailure
    case holdFinalRequest
}

private struct ProfileMutationRecordedRequest: Sendable {
    var host: String
    var path: String
    var userAgent: String?
    var cookie: String?
    var body: Data?
}

private final class ProfileMutationURLProtocol: URLProtocol {
    static let testIDHeader = "X-TiebaPure-Profile-Mutation-Test-ID"

    private struct Context {
        var mode: ProfileMutationStubMode
        var records: [ProfileMutationRecordedRequest]
    }

    private static let lock = NSLock()
    private static var contexts: [String: Context] = [:]

    static func register(mode: ProfileMutationStubMode, id: String) {
        lock.lock()
        contexts[id] = Context(mode: mode, records: [])
        lock.unlock()
    }

    static func remove(id: String) {
        lock.lock()
        contexts.removeValue(forKey: id)
        lock.unlock()
    }

    static func records(id: String) -> [ProfileMutationRecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return contexts[id]?.records ?? []
    }

    static func count(path: String, id: String) -> Int {
        records(id: id).count { $0.path == path }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: testIDHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let id = request.value(forHTTPHeaderField: Self.testIDHeader),
              let mode = Self.record(request: request, id: id) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        switch url.path {
        case "/c/s/login":
            respond(Data(#"{"error_code":"0","anti":{"tbs":"fresh-tbs"}}"#.utf8))
        case "/c/u/feed/userpost":
            respond(Data(profileMutationReplyFeedJSON.utf8))
        case "/c/c/profile/modify", "/c/c/bawu/delthread", "/c/c/bawu/delpost":
            switch mode {
            case .success:
                respond(Data(#"{"error_code":0,"error_msg":""}"#.utf8))
            case .businessError:
                respond(Data(#"{"error_code":220034,"error_msg":"tbs校验失败"}"#.utf8))
            case .sessionExpired:
                respond(Data(#"{"error_code":110001,"error_msg":"登录已失效"}"#.utf8))
            case .finalResponse(let data):
                respond(data)
            case .transportFailure:
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            case .decodeFailure:
                respond(Data("{".utf8))
            case .holdFinalRequest:
                break
            }
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }

    override func stopLoading() {}

    private static func record(request: URLRequest, id: String) -> ProfileMutationStubMode? {
        let record = ProfileMutationRecordedRequest(
            host: request.url?.host ?? "",
            path: request.url?.path ?? "",
            userAgent: request.value(forHTTPHeaderField: "User-Agent"),
            cookie: request.value(forHTTPHeaderField: "Cookie"),
            body: requestBody(request)
        )
        lock.lock()
        defer { lock.unlock() }
        guard var context = contexts[id] else { return nil }
        context.records.append(record)
        contexts[id] = context
        return context.mode
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private func respond(_ data: Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: [
                      "Content-Type": "application/json",
                      "Content-Length": "\(data.count)"
                  ]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
