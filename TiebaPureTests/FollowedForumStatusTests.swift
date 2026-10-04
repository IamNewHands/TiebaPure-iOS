import XCTest
@testable import TiebaPure

final class FollowedForumStatusTests: XCTestCase {
    func testGuideEndpointTargetsTheWebGuideHost() {
        let url = TiebaEndpoint.followedForumGuide.url

        XCTAssertEqual(url.host, "tieba.baidu.com")
        XCTAssertEqual(url.path, "/c/f/forum/forumGuide")
        XCTAssertNil(url.query)
    }

    func testGuideFieldsCarryGuideParametersWithoutCredentials() throws {
        let fields = try TiebaSocialRequestFactory.followedForumGuideFields(
            tbs: "  tbs-value  ",
            page: 2
        )

        XCTAssertEqual(fields["tbs"], "tbs-value")
        XCTAssertEqual(fields["sort_type"], "3")
        XCTAssertEqual(fields["call_from"], "3")
        XCTAssertEqual(fields["page_no"], "2")
        XCTAssertEqual(fields["res_num"], "\(FollowedForumGuidePolicy.pageSize)")
        XCTAssertNil(fields["BDUSS"], "这个网页接口靠 Cookie 传凭据，表单里不应再出现 BDUSS")
        XCTAssertNil(fields["sign"])
    }

    func testGuideFieldsClampPageAndPageSize() throws {
        let fields = try TiebaSocialRequestFactory.followedForumGuideFields(
            tbs: "tbs",
            page: 0,
            pageSize: 0
        )

        XCTAssertEqual(fields["page_no"], "1")
        XCTAssertEqual(fields["res_num"], "1")
    }

    func testGuideFieldsRejectEmptyTBS() {
        XCTAssertThrowsError(
            try TiebaSocialRequestFactory.followedForumGuideFields(tbs: "   ", page: 1)
        ) { error in
            XCTAssertEqual(error as? TiebaMutationError, .missingTBS)
        }
    }

    func testGuideResponseDecodesLevelAndCheckInForEveryForum() throws {
        // The service answers FLAT: like_forum sits beside error_code, with no
        // data wrapper, and unrelated display keys ride along. Decoding a
        // nested data read nil on every success and reported the whole payload
        // as "empty data".
        let json = """
        {
          "error_code": 0,
          "error_msg": "",
          "ctime": "1",
          "block_pop_info": null,
          "forum_create_info": null,
          "like_forum": [
            { "forum_id": "4242", "forum_name": "合成吧", "level_id": "12", "is_sign": true },
            { "forum_id": 4343, "forum_name": "另一个吧", "level_id": 3, "is_sign": 0 }
          ],
          "like_forum_has_more": "0"
        }
        """

        let response = try JSONDecoder().decode(FollowedForumGuideResponseDTO.self, from: Data(json.utf8))

        XCTAssertEqual(response.errorCode, 0)
        XCTAssertEqual(response.forums.count, 2)
        XCTAssertEqual(response.forums[0].forumID, 4242)
        XCTAssertEqual(response.forums[0].level, 12, "字符串等级也要解出来")
        XCTAssertTrue(response.forums[0].isSignedToday, "布尔签到态也要解出来")
        XCTAssertEqual(response.forums[1].forumID, 4343)
        XCTAssertEqual(response.forums[1].level, 3)
        XCTAssertFalse(response.forums[1].isSignedToday, "数字签到态也要解出来")
        XCTAssertEqual(response.hasMore, false)
    }

    func testGuideResponseTreatsMissingForumListAsEmpty() throws {
        let json = """
        { "error_code": 0, "error_msg": "", "like_forum_has_more": 1 }
        """

        let response = try JSONDecoder().decode(FollowedForumGuideResponseDTO.self, from: Data(json.utf8))

        XCTAssertEqual(response.forums.isEmpty, true)
        XCTAssertEqual(response.hasMore, true)
    }

    func testGuideResponseSurfacesServiceErrorCode() throws {
        let json = """
        { "error_code": 1989, "error_msg": "参数错误" }
        """

        let response = try JSONDecoder().decode(FollowedForumGuideResponseDTO.self, from: Data(json.utf8))

        XCTAssertEqual(response.errorCode, 1989)
        XCTAssertEqual(response.errorMessage, "参数错误")
        XCTAssertEqual(response.forums.isEmpty, true)
    }

    func testGuideResponseKeepsEachForumAvatar() throws {
        // Every guide row carries a signed avatar. It used to be dropped at the
        // DTO, which is why a profile's 关注的吧 list had no image to show even
        // though the app had just downloaded forty of them.
        let json = """
        {
          "error_code": 0,
          "error_msg": "",
          "like_forum": [
            {
              "forum_id": 4242,
              "forum_name": "合成吧",
              "level_id": "12",
              "is_sign": true,
              "avatar": "https://himg.bdimg.com/sys/portraitn/item/abc123"
            },
            { "forum_id": 4343, "forum_name": "另一个吧", "level_id": 3, "is_sign": 0 }
          ]
        }
        """

        let response = try JSONDecoder().decode(FollowedForumGuideResponseDTO.self, from: Data(json.utf8))

        XCTAssertEqual(response.forums[0].avatar, "https://himg.bdimg.com/sys/portraitn/item/abc123")
        XCTAssertEqual(
            TiebaURL.make(response.forums[0].avatar),
            URL(string: "https://himg.bdimg.com/sys/portraitn/item/abc123")
        )
        XCTAssertNil(response.forums[1].avatar, "没有头像的行保持为空，好让列表用首字兜底")
    }

    func testForumAvatarIndexAnswersByForumIDOnly() {
        let index = ForumAvatarIndex()
        XCTAssertTrue(index.needsFetch)
        XCTAssertFalse(index.hasData)

        let stored = index.store(forums: [
            Forum(
                id: 7,
                name: "壁纸",
                displayName: "壁纸吧",
                avatarURL: URL(string: "https://himg.bdimg.com/sys/portraitn/item/seven"),
                memberCount: 0,
                threadCount: 0
            ),
            Forum(id: 8, name: "无图", displayName: "无图吧", avatarURL: nil, memberCount: 0, threadCount: 0)
        ])

        XCTAssertEqual(stored, 1, "没有头像的行不算存进去")
        XCTAssertEqual(
            index.url(for: 7),
            URL(string: "https://himg.bdimg.com/sys/portraitn/item/seven")
        )
        XCTAssertNil(index.url(for: 8), "接口没给头像的行不能凭空补一个")
        XCTAssertNil(index.url(for: 99), "没见过的吧不能借用别的头像")
        XCTAssertTrue(index.hasData)
        XCTAssertFalse(index.needsFetch, "已经有头像了就不再重复请求")
        XCTAssertEqual(index.snapshot.count, 1)
    }

    func testForumAvatarIndexKeepsTryingWhenAnAnswerCarriesNoUsableAvatar() {
        // The guide page answers with an avatar string on every row. If none of
        // them becomes a URL, the index must stay "no data" so the profile can
        // still try the followed-forum list — treating the answer as loaded is
        // what left the list on initial letters with nothing in the log.
        let index = ForumAvatarIndex()

        let stored = index.store(statuses: [
            FollowedForumStatus(forumID: 9, level: 1, isSignedToday: false)
        ])

        XCTAssertEqual(stored, 0)
        XCTAssertFalse(index.hasData)
        XCTAssertTrue(index.needsFetch)
        XCTAssertNil(index.url(for: 9))

        // A caller that already tried the full-list fetch does not repeat it.
        index.markFetchAttempted()
        XCTAssertFalse(index.needsFetch)
        XCTAssertFalse(index.hasData)
    }

    func testForumAvatarNormalizerAcceptsBothShapes() {
        XCTAssertEqual(
            TiebaURL.forumAvatar("https://himg.bdimg.com/sys/portraitn/item/abc123"),
            URL(string: "https://himg.bdimg.com/sys/portraitn/item/abc123"),
            "绝对 URL 原样使用"
        )
        XCTAssertEqual(
            TiebaURL.forumAvatar("http://tb.himg.baidu.com/sys/portrait/item/abc123"),
            URL(string: "https://himg.bdimg.com/sys/portrait/item/abc123"),
            "老 http 头像要升到 https 并换掉已废弃的主机"
        )
        XCTAssertEqual(
            TiebaURL.forumAvatar("abc123"),
            URL(string: "https://himg.bdimg.com/sys/portrait/item/abc123"),
            "裸 portrait token 也要能拼出来，否则整列都会退回首字"
        )
        XCTAssertNil(TiebaURL.forumAvatar("   "))
    }

    func testForumAvatarShapeDescriptionNeverCopiesTheValue() {
        let token = "https://himg.bdimg.com/sys/portraitn/item/verysecret?sign=abcdef123456"
        let description = TiebaURL.shapeDescription(token)

        XCTAssertTrue(description.contains("https://"))
        XCTAssertTrue(description.contains("长度"))
        XCTAssertFalse(description.contains("sign"), "诊断日志不能把签名串抄进去")
        XCTAssertFalse(description.contains("verysecret"))
        XCTAssertEqual(TiebaURL.shapeDescription("  "), "空值")
    }

    func testTileLabelReadsLevelAndCheckInAsOneSentence() {
        XCTAssertEqual(
            ForumTileAccessibilityPolicy.label(
                title: "壁纸吧",
                level: 12,
                isSignedToday: true,
                isManaging: false
            ),
            "进入壁纸吧，等级12，今日已签到"
        )
        XCTAssertEqual(
            ForumTileAccessibilityPolicy.label(
                title: "壁纸吧",
                level: 0,
                isSignedToday: false,
                isManaging: false
            ),
            "进入壁纸吧",
            "没有等级和签到信息时不要念出占位文案"
        )
        XCTAssertEqual(
            ForumTileAccessibilityPolicy.label(
                title: "壁纸吧",
                level: 12,
                isSignedToday: true,
                isManaging: true
            ),
            "壁纸吧",
            "管理模式下的磁贴只念名字，避免和删除按钮冲突"
        )
    }
}
