import XCTest
@testable import TiebaPure

final class UserProfileTests: XCTestCase {
    private let builder = TiebaRequestBuilder(
        screenScale: 3,
        screenWidth: 1179,
        screenHeight: 2556,
        clientID: "profile-test-client"
    )

    override func tearDown() {
        SocialMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testProfileRequestUsesCurrentUserShapeForOwnProfile() {
        let account = makeAccount()
        let user = UserSummary(id: 42, name: "raw", displayName: "本人", portrait: "portrait")

        let context = UserProfileRequestFactory.profileRequest(
            account: account,
            user: user,
            requestBuilder: builder
        )

        XCTAssertTrue(context.isCurrentUser)
        XCTAssertEqual(context.request.data.uid, 42)
        XCTAssertFalse(context.request.data.hasFriendUid)
        XCTAssertEqual(context.request.data.isGuest, 0)
        XCTAssertEqual(context.request.data.needPostCount, 1)
        XCTAssertEqual(context.request.data.hasPlist_p, 1)
        XCTAssertEqual(context.request.data.rn, 20)
        XCTAssertEqual(context.request.data.common.bduss, "bduss")
    }

    func testProfileRequestUsesGuestTargetForAnotherUser() {
        let account = makeAccount()
        let user = UserSummary(id: 99, name: "other", displayName: "其他用户", portrait: "other")

        let context = UserProfileRequestFactory.profileRequest(
            account: account,
            user: user,
            requestBuilder: builder
        )

        XCTAssertFalse(context.isCurrentUser)
        XCTAssertEqual(context.request.data.uid, 42)
        XCTAssertEqual(context.request.data.friendUid, 99)
        XCTAssertEqual(context.request.data.isGuest, 1)
    }

    func testAnonymousProfileRequestDoesNotInventCurrentUserID() {
        let user = UserSummary(id: 99, name: "other", displayName: "其他用户", portrait: "other")

        let context = UserProfileRequestFactory.profileRequest(
            account: nil,
            user: user,
            requestBuilder: builder
        )

        XCTAssertFalse(context.request.data.hasUid)
        XCTAssertEqual(context.request.data.friendUid, 99)
        XCTAssertEqual(context.request.data.isGuest, 1)
    }

    func testUserThreadsRequestIncludesPagingAndViewCardFields() throws {
        let request = try UserProfileRequestFactory.threadsRequest(
            account: makeAccount(),
            userID: 99,
            page: 3,
            requestBuilder: builder
        )

        XCTAssertEqual(request.data.uid, 99)
        XCTAssertEqual(request.data.pn, 3)
        XCTAssertEqual(request.data.rn, 20)
        XCTAssertEqual(request.data.isThread, 1)
        XCTAssertEqual(request.data.needContent, 1)
        XCTAssertEqual(request.data.qType, 1)
        XCTAssertEqual(request.data.isViewCard, 1)
        XCTAssertEqual(request.data.common.stoken, "stoken")
    }

    func testProfileMapperPreservesPublicForumsAndMetadata() {
        var forum = Tieba_LikeForumInfo()
        forum.forumID = 101
        forum.forumName = "测试"
        var suffixNamedForum = Tieba_LikeForumInfo()
        suffixNamedForum.forumID = 102
        suffixNamedForum.forumName = "网吧"
        var privacy = Tieba_PrivSets()
        privacy.like = 1
        var proto = Tieba_User()
        proto.id = 99
        proto.name = "raw"
        proto.nameShow = "显示名称"
        proto.portrait = "portrait"
        proto.levelID = 8
        proto.tiebaUid = "tieba-99"
        proto.tbAge = "10.5年"
        proto.ipAddress = "广东"
        proto.displayIntro = "个人简介"
        proto.totalAgreeNum = 12_345
        proto.hasConcerned_p = 1
        proto.concernNum = 7
        proto.fansNum = 8
        proto.threadNum = 9
        proto.myLikeNum = 2
        proto.privSets = privacy
        proto.likeForum = [forum, suffixNamedForum]

        let profile = UserProfileMapper.profile(
            from: proto,
            fallback: UserSummary(id: 99, name: "", displayName: "", portrait: ""),
            isCurrentUser: false
        )

        XCTAssertEqual(profile.user.displayNameResolved, "显示名称")
        XCTAssertEqual(profile.tiebaID, "tieba-99")
        XCTAssertEqual(profile.location, "广东")
        XCTAssertEqual(profile.agreeCount, 12_345)
        XCTAssertFalse(profile.isCurrentUser)
        XCTAssertTrue(profile.isFollowed)
        XCTAssertEqual(profile.followedForums.map(\.name), ["测试", "网吧"])
        XCTAssertEqual(profile.followedForums.map(\.displayName), ["测试吧", "网吧"])
        XCTAssertEqual(profile.followedForumsVisibility, .visible)
    }

    /// The followed-forum rows of a profile arrive without an avatar: the
    /// service's `likeForum` ships only a name and an id. The row therefore
    /// falls back to the forum's first character, asserted here on the
    /// mapper's own output.
    func testProfileFollowedForumsProvideInitialBadges() {
        var forum = Tieba_LikeForumInfo()
        forum.forumID = 101
        forum.forumName = "测试"
        var latinForum = Tieba_LikeForumInfo()
        latinForum.forumID = 102
        latinForum.forumName = "steam"
        var proto = Tieba_User()
        proto.id = 99
        proto.likeForum = [forum, latinForum]

        let profile = UserProfileMapper.profile(
            from: proto,
            fallback: UserSummary(id: 99, name: "", displayName: "", portrait: ""),
            isCurrentUser: false
        )

        XCTAssertEqual(profile.followedForums.compactMap(\.avatarURL), [])
        XCTAssertEqual(
            profile.followedForums.map { AvatarInitialPolicy.initial(from: $0.name, $0.displayName) },
            ["测", "S"]
        )
    }

    func testAvatarInitialPolicyFallsBackThroughCandidates() {
        XCTAssertNil(AvatarInitialPolicy.initial(from: "", "   "))
        XCTAssertEqual(AvatarInitialPolicy.initial(from: "  ", "网吧"), "网")
        XCTAssertEqual(AvatarInitialPolicy.initial(from: "steam"), "S")
        XCTAssertEqual(AvatarInitialPolicy.initial(from: "🎮游戏"), "🎮")
    }

    func testAvatarInitialPaletteIsStableAndBounded() {
        let count = AvatarInitialPalette.colors.count
        XCTAssertGreaterThan(count, 1)
        for seed in ["孙笑川", "steam", "武汉大学", ""] {
            let index = AvatarInitialPalette.index(for: seed, count: count)
            XCTAssertEqual(index, AvatarInitialPalette.index(for: seed, count: count))
            XCTAssertTrue((0..<count).contains(index))
        }
        XCTAssertEqual(AvatarInitialPalette.index(for: "任何名字", count: 0), 0)
    }

    func testPrivacyPolicyDistinguishesPrivateFromPublicEmptyForums() {
        XCTAssertEqual(
            UserProfilePrivacyPolicy.followedForumsVisibility(
                isCurrentUser: false,
                privacyValue: 0,
                declaredCount: 3,
                returnedCount: 0
            ),
            .privateContent
        )
        XCTAssertEqual(
            UserProfilePrivacyPolicy.followedForumsVisibility(
                isCurrentUser: false,
                privacyValue: 0,
                declaredCount: 0,
                returnedCount: 0
            ),
            .visible
        )
        XCTAssertEqual(
            UserProfilePrivacyPolicy.followedForumsVisibility(
                isCurrentUser: true,
                privacyValue: 0,
                declaredCount: 3,
                returnedCount: 0
            ),
            .visible
        )
    }

    func testHiddenPostResponseMapsToPrivateState() {
        var data = Tiebapure_Profile_UserThreadsResponseData()
        data.hidePost = 1
        var response = Tiebapure_Profile_UserThreadsResponse()
        response.data = data

        let page = UserProfileMapper.threadsPage(from: response, page: 1)

        XCTAssertEqual(page.visibility, .privateContent)
        XCTAssertFalse(page.hasMore)
        XCTAssertTrue(page.threads.isEmpty)
    }

    func testProfileCountFormatterUsesCompactChineseUnits() {
        XCTAssertEqual(UserProfileCountText.string(4_639), "4639")
        XCTAssertEqual(UserProfileCountText.string(10_000), "1万")
        XCTAssertEqual(UserProfileCountText.string(12_345), "1.2万")
        XCTAssertEqual(UserProfileCountText.string(-1), "0")
    }

    func testProfileThreadsUseFlatContentSections() {
        XCTAssertEqual(ForumThreadRow.Presentation.userProfile.cardRadius, 0)
        XCTAssertFalse(ForumThreadRow.Presentation.userProfile.showsDivider)
    }

    func testProfileMetadataOmitsEmptyGroupsWithoutReservedLayoutSpace() {
        let profile = UserProfile(
            user: UserSummary(id: 99, name: "other", displayName: "其他用户", portrait: "portrait"),
            isCurrentUser: false,
            isFollowed: false,
            tiebaID: "",
            tiebaAge: "",
            sex: .unspecified,
            location: "  ",
            intro: "",
            backgroundURL: nil,
            agreeCount: 0,
            followingCount: 0,
            followerCount: 0,
            threadCount: 0,
            followedForumCount: 0,
            followedForums: [],
            followedForumsVisibility: .visible
        )

        XCTAssertTrue(UserProfileMetadataText.items(for: profile, group: .identity).isEmpty)
        XCTAssertTrue(UserProfileMetadataText.items(for: profile, group: .details).isEmpty)
    }

    func testProfileMetadataKeepsIdentityAndDetailsInSeparateRows() {
        var profile = UserProfile(
            user: UserSummary(id: 99, name: "other", displayName: "其他用户", portrait: "portrait"),
            isCurrentUser: false,
            isFollowed: false,
            tiebaID: "tieba-99",
            tiebaAge: "10.5年",
            sex: .female,
            location: "广东",
            intro: "",
            backgroundURL: nil,
            agreeCount: 0,
            followingCount: 0,
            followerCount: 0,
            threadCount: 0,
            followedForumCount: 0,
            followedForums: [],
            followedForumsVisibility: .visible
        )

        XCTAssertEqual(
            UserProfileMetadataText.items(for: profile, group: .identity),
            ["女", "ID tieba-99"]
        )
        XCTAssertEqual(
            UserProfileMetadataText.items(for: profile, group: .details),
            ["吧龄 10.5年", "IP属地 广东"]
        )

        profile.location = "IP属地：北京"
        XCTAssertEqual(
            UserProfileMetadataText.items(for: profile, group: .details),
            ["吧龄 10.5年", "IP属地 北京"]
        )
    }

    func testFollowRequestUsesMinimalAuthenticatedFormShape() throws {
        let account = makeAccount()
        let user = UserSummary(
            id: 99,
            name: "other",
            displayName: "其他用户",
            portrait: "portrait-token"
        )

        let fields = try UserProfileRequestFactory.followFields(
            account: account,
            user: user
        )

        XCTAssertEqual(fields, [
            "BDUSS": "bduss",
            "portrait": "portrait-token",
            "tbs": "tbs"
        ])
        XCTAssertEqual(TiebaEndpoint.login.url.host, "c.tieba.baidu.com")
        XCTAssertEqual(TiebaEndpoint.initNickname.url.host, "c.tieba.baidu.com")
        XCTAssertEqual(TiebaEndpoint.followedForums.url.host, "c.tieba.baidu.com")
        XCTAssertEqual(TiebaEndpoint.followUser.url.host, "tiebac.baidu.com")
        XCTAssertEqual(TiebaEndpoint.unfollowUser.url.host, "tiebac.baidu.com")
        XCTAssertEqual(TiebaEndpoint.followUser.url.path, "/c/c/user/follow")
        XCTAssertEqual(TiebaEndpoint.unfollowUser.url.path, "/c/c/user/unfollow")
    }

    func testFollowRequestRejectsMissingPortrait() {
        let user = UserSummary(id: 99, name: "other", displayName: "其他用户", portrait: "")

        XCTAssertThrowsError(
            try UserProfileRequestFactory.followFields(
                account: makeAccount(),
                user: user
            )
        ) { error in
            XCTAssertEqual(error as? UserProfileAPIError, .missingPortrait)
        }
    }

    func testFollowRequestPrefersExplicitRefreshedTBS() throws {
        let fields = try UserProfileRequestFactory.followFields(
            account: makeAccount(),
            user: UserSummary(id: 99, name: "other", displayName: "其他用户", portrait: "portrait-token"),
            tbs: "fresh-tbs"
        )

        XCTAssertEqual(fields["tbs"], "fresh-tbs")
    }

    func testLikeRequestUsesObjectSpecificPostIDs() throws {
        let account = makeAccount()
        let thread = try TiebaSocialRequestFactory.likeFields(
            account: account,
            tbs: "fresh-tbs",
            threadID: 1001,
            postID: 2001,
            objectType: .thread,
            liked: true,
            requestBuilder: builder
        )
        let post = try TiebaSocialRequestFactory.likeFields(
            account: account,
            tbs: "fresh-tbs",
            threadID: 1001,
            postID: 2002,
            objectType: .post,
            liked: false,
            requestBuilder: builder
        )
        let subpost = try TiebaSocialRequestFactory.likeFields(
            account: account,
            tbs: "fresh-tbs",
            threadID: 1001,
            postID: 3001,
            objectType: .subpost,
            liked: true,
            requestBuilder: builder
        )

        XCTAssertEqual(thread["post_id"], "0")
        XCTAssertEqual(thread["obj_type"], "3")
        XCTAssertEqual(thread["op_type"], "0")
        XCTAssertEqual(thread["_client_version"], TiebaClientVersion.v22.rawValue)
        XCTAssertEqual(thread["BDUSS"], "bduss")
        XCTAssertEqual(thread["cuid"], builder.miniCUID)
        XCTAssertEqual(
            Set(thread.keys),
            Set(["BDUSS", "_client_version", "agree_type", "cuid", "obj_type", "op_type", "post_id", "tbs", "thread_id"])
        )
        XCTAssertEqual(post["post_id"], "2002")
        XCTAssertEqual(post["obj_type"], "1")
        XCTAssertEqual(post["op_type"], "1")
        XCTAssertEqual(subpost["post_id"], "3001")
        XCTAssertEqual(subpost["obj_type"], "2")
    }

    func testFollowedUsersResponseAcceptsStringNumbersAndStripsPortraitQuery() throws {
        let response = try JSONDecoder().decode(
            FollowedUsersResponseDTO.self,
            from: Data(
                #"{"error_code":"0","error_msg":"","pn":"2","total_follow_num":"21","has_more":"1","follow_list":[{"id":"99","name":"raw","name_show":"显示名称","portrait":"tb.1.avatar?t=1234567890"}]}"#.utf8
            )
        )

        XCTAssertEqual(response.currentPage, 2)
        XCTAssertEqual(response.totalCount, 21)
        XCTAssertTrue(response.hasMore)
        XCTAssertEqual(response.users.first?.userSummary.id, 99)
        XCTAssertEqual(response.users.first?.userSummary.displayNameResolved, "显示名称")
        XCTAssertEqual(response.users.first?.userSummary.portrait, "tb.1.avatar")
    }

    func testUserRelationshipRequestUsesExactV22Fields() throws {
        let fields = try TiebaSocialRequestFactory.userRelationshipFields(
            account: makeAccount(),
            userID: 99,
            page: 3
        )

        XCTAssertEqual(fields, [
            "BDUSS": "bduss",
            "_client_version": TiebaClientVersion.v22.rawValue,
            "pn": "3",
            "uid": "99"
        ])
        XCTAssertEqual(TiebaEndpoint.followedUsers.url.host, "tiebac.baidu.com")
        XCTAssertEqual(TiebaEndpoint.followedUsers.url.path, "/c/u/follow/followList")
        XCTAssertEqual(TiebaEndpoint.followers.url.host, "tiebac.baidu.com")
        XCTAssertEqual(TiebaEndpoint.followers.url.path, "/c/u/fans/page")
    }

    func testUserRelationshipRequestsMapFollowingAndFollowersPages() async throws {
        let api = makeSocialAPI { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "tiebac.baidu.com")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "User-Agent"),
                "tieba/\(TiebaClientVersion.v22.rawValue)"
            )
            let fields = try Self.formFields(request)
            XCTAssertEqual(Set(fields.keys), Set(["BDUSS", "_client_version", "pn", "sign", "uid"]))
            XCTAssertEqual(fields["BDUSS"], "bduss")
            XCTAssertEqual(fields["_client_version"], TiebaClientVersion.v22.rawValue)
            XCTAssertEqual(fields["pn"], "2")
            XCTAssertEqual(fields["uid"], "99")
            XCTAssertNotNil(fields["sign"])

            switch url.path {
            case "/c/u/follow/followList":
                return Data(
                    #"{"error_code":"0","pn":"2","total_follow_num":"11","has_more":"1","follow_list":[{"id":"101","name":"following","name_show":"关注用户","portrait":"follow.portrait?t=1"}]}"#.utf8
                )
            case "/c/u/fans/page":
                return Data(
                    #"{"error_code":0,"user_list":[{"id":102,"name":"follower","name_show":"粉丝用户","portrait":"fan.portrait?t=2"}],"page":{"current_page":"2","total_count":"12","has_more":"0"}}"#.utf8
                )
            default:
                XCTFail("Unexpected relationship request: \(url.path)")
                return Data()
            }
        }

        let following = try await api.userRelationships(
            account: makeAccount(),
            userID: 99,
            kind: .following,
            page: 2
        )
        let followers = try await api.userRelationships(
            account: makeAccount(),
            userID: 99,
            kind: .followers,
            page: 2
        )

        XCTAssertEqual(following.users.first?.displayNameResolved, "关注用户")
        XCTAssertEqual(following.users.first?.portrait, "follow.portrait")
        XCTAssertEqual(following.currentPage, 2)
        XCTAssertEqual(following.totalCount, 11)
        XCTAssertTrue(following.hasMore)
        XCTAssertEqual(followers.users.first?.displayNameResolved, "粉丝用户")
        XCTAssertEqual(followers.users.first?.portrait, "fan.portrait")
        XCTAssertEqual(followers.currentPage, 2)
        XCTAssertEqual(followers.totalCount, 12)
        XCTAssertFalse(followers.hasMore)
    }

    func testRelationshipAndMutationDTOsRejectMissingBusinessStatus() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                FollowedUsersResponseDTO.self,
                from: Data(#"{"follow_list":[]}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                FollowersResponseDTO.self,
                from: Data(#"{"user_list":[],"page":{}}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                UserFollowResponseDTO.self,
                from: Data(#"{"error_msg":"missing status"}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ForumMembershipResponseDTO.self,
                from: Data(#"{"data":{"user_forum_info":{"is_follow":"1"}}}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ForumMembershipResponseDTO.self,
                from: Data(#"{"error_code":0,"data":{"user_forum_info":{}}}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ForumMembershipResponseDTO.self,
                from: Data(#"{"error_code":0}"#.utf8)
            )
        )
        let failedMembership = try? JSONDecoder().decode(
            ForumMembershipResponseDTO.self,
            from: Data(#"{"error_code":220034,"error_msg":"tbs校验失败"}"#.utf8)
        )
        XCTAssertEqual(failedMembership?.errorCode, 220034)
        XCTAssertNil(failedMembership?.data)
    }

    func testForumRequestFactoriesUseExactV22AndMinimalMutationFields() throws {
        let membership = try TiebaSocialRequestFactory.forumMembershipFields(
            account: makeAccount(),
            forumID: 73
        )
        let mutation = try TiebaSocialRequestFactory.forumFollowFields(
            account: makeAccount(),
            forumID: 73,
            tbs: "fresh-forum-tbs"
        )

        XCTAssertEqual(membership, [
            "BDUSS": "bduss",
            "_client_version": TiebaClientVersion.v22.rawValue,
            "forum_id": "73",
            "friend_portrait": "portrait"
        ])
        XCTAssertEqual(mutation, [
            "BDUSS": "bduss",
            "fid": "73",
            "tbs": "fresh-forum-tbs"
        ])
        XCTAssertEqual(TiebaEndpoint.forumMembership.url.path, "/c/f/forum/getUserForumLevelInfo")
        XCTAssertEqual(TiebaEndpoint.followForum.url.path, "/c/c/forum/like")
        XCTAssertEqual(TiebaEndpoint.unfollowForum.url.path, "/c/c/forum/unfavolike")
        XCTAssertEqual(TiebaEndpoint.followForum.url.host, "tiebac.baidu.com")
    }

    func testForumMembershipRequestUsesSignedV22Shape() async throws {
        let api = makeSocialAPI { request in
            XCTAssertEqual(request.url?.host, "tiebac.baidu.com")
            XCTAssertEqual(request.url?.path, "/c/f/forum/getUserForumLevelInfo")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "User-Agent"),
                "tieba/\(TiebaClientVersion.v22.rawValue)"
            )
            let fields = try Self.formFields(request)
            XCTAssertEqual(
                Set(fields.keys),
                Set(["BDUSS", "_client_version", "forum_id", "friend_portrait", "sign"])
            )
            XCTAssertEqual(fields["BDUSS"], "bduss")
            XCTAssertEqual(fields["_client_version"], TiebaClientVersion.v22.rawValue)
            XCTAssertEqual(fields["forum_id"], "73")
            XCTAssertEqual(fields["friend_portrait"], "portrait")
            XCTAssertNotNil(fields["sign"])
            return Data(
                #"{"error_code":"0","data":{"user_forum_info":{"is_follow":"1"}}}"#.utf8
            )
        }

        let result = try await api.forumMembership(account: makeAccount(), forum: makeForum())

        XCTAssertEqual(result.forumID, 73)
        XCTAssertTrue(result.isFollowed)
    }

    func testForumFollowMutationSubmitsAtMostOnceAfterFreshTBS() async {
        var requestedPaths: [String] = []
        var mutationCount = 0
        let api = makeSocialAPI { request in
            let url = try XCTUnwrap(request.url)
            requestedPaths.append(url.path)
            switch url.path {
            case "/c/s/login":
                return Data(#"{"error_code":"0","anti":{"tbs":"fresh-forum-tbs"}}"#.utf8)
            case "/c/c/forum/like":
                mutationCount += 1
                XCTAssertEqual(url.host, "tiebac.baidu.com")
                let fields = try Self.formFields(request)
                XCTAssertEqual(Set(fields.keys), Set(["BDUSS", "fid", "sign", "tbs"]))
                XCTAssertEqual(fields["BDUSS"], "bduss")
                XCTAssertEqual(fields["fid"], "73")
                XCTAssertEqual(fields["tbs"], "fresh-forum-tbs")
                XCTAssertNotNil(fields["sign"])
                return Data(#"{"error_code":220034,"error_msg":"tbs校验失败"}"#.utf8)
            default:
                XCTFail("A failed forum mutation must not be replayed: \(url.path)")
                return Data()
            }
        }

        do {
            _ = try await api.setForumFollowed(
                account: makeAccount(),
                forum: makeForum(),
                followed: true
            )
            XCTFail("Expected the TBS validation failure")
        } catch {
            XCTAssertEqual(
                error as? TiebaAPIError,
                .response(code: 220034, message: "tbs校验失败")
            )
        }

        XCTAssertEqual(mutationCount, 1)
        XCTAssertEqual(requestedPaths, ["/c/s/login", "/c/c/forum/like"])
    }

    func testFollowMutationFetchesFreshTBSBeforeSubmitting() async throws {
        var mutationCount = 0
        let api = makeSocialAPI { request in
            let path = try XCTUnwrap(request.url?.path)
            switch path {
            case "/c/s/login":
                // The write token is minted on the protobuf host: the app host's
                // route carries the sync channel and parks the request for the
                // length of its poll window, which measured 20.1s on device.
                XCTAssertEqual(request.url?.host, "tiebac.baidu.com")
                let fields = try Self.formFields(request)
                XCTAssertEqual(fields["_client_version"], "22.5.1.0")
                XCTAssertEqual(fields["bdusstoken"], "bduss")
                XCTAssertNotNil(fields["sign"])
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "User-Agent"),
                    "tieba/22.5.1.0 skin/default"
                )
                return Data(#"{"error_code":"0","anti":{"tbs":"fresh-tbs"}}"#.utf8)
            case "/c/c/user/follow":
                mutationCount += 1
                XCTAssertEqual(request.url?.host, "tiebac.baidu.com")
                let fields = try Self.formFields(request)
                XCTAssertEqual(fields["tbs"], "fresh-tbs")
                XCTAssertNotEqual(fields["tbs"], "tbs")
                XCTAssertEqual(Set(fields.keys), Set(["BDUSS", "portrait", "sign", "tbs"]))
                XCTAssertEqual(fields["BDUSS"], "bduss")
                XCTAssertEqual(fields["portrait"], "portrait-token")
                XCTAssertNotNil(fields["sign"])
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "User-Agent"),
                    "tieba/\(TiebaClientVersion.v22.rawValue)"
                )
                return Data(#"{"error_code":0,"error_msg":""}"#.utf8)
            default:
                XCTFail("Unexpected request path: \(path)")
                return Data()
            }
        }

        try await api.setUserFollowed(
            account: makeAccount(),
            user: UserSummary(id: 99, name: "other", displayName: "其他用户", portrait: "portrait-token"),
            followed: true
        )
        XCTAssertEqual(mutationCount, 1)
    }

    func testFollowMutationDoesNotRetryOrUseWebMutationAfterTBSRejection() async {
        var requestedPaths: [String] = []
        var mutationCount = 0
        let api = makeSocialAPI { request in
            let url = try XCTUnwrap(request.url)
            requestedPaths.append(url.path)
            switch url.path {
            case "/c/s/login":
                return Data(#"{"error_code":"0","anti":{"tbs":"fresh-tbs"}}"#.utf8)
            case "/c/c/user/unfollow":
                mutationCount += 1
                XCTAssertEqual(url.host, "tiebac.baidu.com")
                return Data(#"{"error_code":220034,"error_msg":"tbs校验失败"}"#.utf8)
            default:
                XCTFail("A failed mutation must not trigger another write request: \(url.path)")
                return Data()
            }
        }

        do {
            try await api.setUserFollowed(
                account: makeAccount(),
                user: UserSummary(
                    id: 99,
                    name: "other",
                    displayName: "其他用户",
                    portrait: "portrait-token"
                ),
                followed: false
            )
            XCTFail("Expected the TBS validation failure")
        } catch {
            XCTAssertEqual(
                error as? TiebaAPIError,
                .response(code: 220034, message: "tbs校验失败")
            )
        }

        XCTAssertEqual(mutationCount, 1)
        XCTAssertEqual(requestedPaths, ["/c/s/login", "/c/c/user/unfollow"])
    }

    func testFollowMutationUsesWebTBSWhenClientLoginFalselyReportsExpired() async throws {
        let api = makeSocialAPI { request in
            let path = try XCTUnwrap(request.url?.path)
            switch path {
            case "/c/s/login":
                XCTAssertEqual(request.url?.host, "tiebac.baidu.com")
                return Data(#"{"error_code":"110001","error_msg":"登录已失效"}"#.utf8)
            case "/mo/q/newmoindex":
                XCTAssertEqual(request.url?.host, "tieba.baidu.com")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Cookie"),
                    "BDUSS=bduss; STOKEN=stoken; BAIDUID=baiduid"
                )
                return Data(#"{"data":{"is_login":true,"tbs":"web-fresh-tbs"}}"#.utf8)
            case "/c/c/user/follow":
                let fields = try Self.formFields(request)
                XCTAssertEqual(fields["tbs"], "web-fresh-tbs")
                return Data(#"{"error_code":0,"error_msg":""}"#.utf8)
            default:
                XCTFail("Unexpected request path: \(path)")
                return Data()
            }
        }

        try await api.setUserFollowed(
            account: makeAccount(),
            user: UserSummary(id: 99, name: "other", displayName: "其他用户", portrait: "portrait-token"),
            followed: true
        )
    }

    func testFollowMutationReportsExpiredOnlyWhenWebCheckAlsoRejectsLogin() async {
        let api = makeSocialAPI { request in
            let path = try XCTUnwrap(request.url?.path)
            switch path {
            case "/c/s/login":
                return Data(#"{"error_code":"110001","error_msg":"客户端登录已失效"}"#.utf8)
            case "/mo/q/newmoindex":
                return Data(#"{"data":{"is_login":false}}"#.utf8)
            default:
                XCTFail("Expired account must not submit a follow mutation: \(path)")
                return Data()
            }
        }

        do {
            try await api.setUserFollowed(
                account: makeAccount(),
                user: UserSummary(id: 99, name: "other", displayName: "其他用户", portrait: "portrait-token"),
                followed: true
            )
            XCTFail("Expected session-expired error")
        } catch {
            XCTAssertEqual(
                error as? TiebaAPIError,
                .sessionExpired(code: 110001, message: "客户端登录已失效")
            )
        }
    }

    func testLikeMutationFetchesFreshTBSAndUsesReplyObjectType() async throws {
        let api = makeSocialAPI { request in
            let path = try XCTUnwrap(request.url?.path)
            switch path {
            case "/c/s/login":
                return Data(#"{"error_code":"0","anti":{"tbs":"fresh-like-tbs"}}"#.utf8)
            case "/c/c/agree/opAgree":
                let fields = try Self.formFields(request)
                XCTAssertEqual(fields["tbs"], "fresh-like-tbs")
                XCTAssertEqual(fields["thread_id"], "1001")
                XCTAssertEqual(fields["post_id"], "2002")
                XCTAssertEqual(fields["obj_type"], "1")
                XCTAssertEqual(fields["op_type"], "0")
                XCTAssertEqual(fields["_client_version"], TiebaClientVersion.v22.rawValue)
                XCTAssertEqual(fields["cuid"], self.builder.miniCUID)
                XCTAssertEqual(
                    Set(fields.keys),
                    Set(["BDUSS", "_client_version", "agree_type", "cuid", "obj_type", "op_type", "post_id", "sign", "tbs", "thread_id"])
                )
                XCTAssertNotNil(fields["sign"])
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "User-Agent"),
                    "tieba/\(TiebaClientVersion.v22.rawValue)"
                )
                return Data(#"{"error_code":"0","error_msg":""}"#.utf8)
            default:
                XCTFail("Unexpected request path: \(path)")
                return Data()
            }
        }

        try await api.setPostLiked(
            account: makeAccount(),
            threadID: 1001,
            postID: 2002,
            objectType: .post,
            liked: true
        )
    }

    func testLikeMutationDoesNotRetryAfterExplicitValidationFailure() async {
        var attemptedTBSValues: [String] = []
        var requestedPaths: [String] = []
        let api = makeSocialAPI { request in
            let path = try XCTUnwrap(request.url?.path)
            requestedPaths.append(path)
            switch path {
            case "/c/s/login":
                return Data(#"{"error_code":"0","anti":{"tbs":"client-like-tbs"}}"#.utf8)
            case "/c/c/agree/opAgree":
                let fields = try Self.formFields(request)
                let tbs = try XCTUnwrap(fields["tbs"])
                attemptedTBSValues.append(tbs)
                return Data(#"{"error_code":220034,"error_msg":"tbs校验失败"}"#.utf8)
            default:
                XCTFail("A failed like mutation must not be replayed: \(path)")
                return Data()
            }
        }

        do {
            try await api.setPostLiked(
                account: makeAccount(),
                threadID: 1001,
                postID: 2002,
                objectType: .post,
                liked: true
            )
            XCTFail("Expected the TBS validation failure")
        } catch {
            XCTAssertEqual(error as? TiebaAPIError, .response(code: 220034, message: "tbs校验失败"))
        }

        XCTAssertEqual(attemptedTBSValues, ["client-like-tbs"])
        XCTAssertEqual(requestedPaths, ["/c/s/login", "/c/c/agree/opAgree"])
    }

    func testFollowResponseAcceptsNumericAndStringErrorCodes() throws {
        let numeric = try JSONDecoder().decode(
            UserFollowResponseDTO.self,
            from: Data(#"{"error_code":0,"error_msg":""}"#.utf8)
        )
        let string = try JSONDecoder().decode(
            UserFollowResponseDTO.self,
            from: Data(#"{"error_code":"12","error_msg":"失败"}"#.utf8)
        )

        XCTAssertEqual(numeric.errorCode, 0)
        XCTAssertEqual(string.errorCode, 12)
        XCTAssertEqual(string.errorMessage, "失败")
    }

    private func makeAccount() -> Account {
        Account(
            uid: "42",
            name: "raw",
            displayName: "本人",
            portrait: "portrait",
            bduss: "bduss",
            stoken: "stoken",
            baiduID: "baiduid",
            tbs: "tbs"
        )
    }

    private func makeForum() -> Forum {
        Forum(
            id: 73,
            name: "测试",
            displayName: "测试吧",
            avatarURL: nil,
            memberCount: 0,
            threadCount: 0
        )
    }

    private func makeSocialAPI(handler: @escaping (URLRequest) throws -> Data) -> TiebaAPI {
        SocialMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SocialMockURLProtocol.self]
        return TiebaAPI(
            client: TiebaHTTPClient(session: URLSession(configuration: configuration)),
            requestBuilder: builder
        )
    }

    private static func formFields(_ request: URLRequest) throws -> [String: String] {
        let body: Data
        if let requestBody = request.httpBody {
            body = requestBody
        } else {
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw try XCTUnwrap(stream.streamError) }
                if count == 0 { break }
                collected.append(contentsOf: buffer.prefix(count))
            }
            body = collected
        }
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        var components = URLComponents()
        components.percentEncodedQuery = text
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}

private final class SocialMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let data = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
