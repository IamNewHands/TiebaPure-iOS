import XCTest
@testable import TiebaPure

/// The log is the only evidence channel for undocumented endpoints, so the two
/// properties that make it trustworthy are covered here: a secret never leaves
/// the device, and a captured payload stays readable as a shape description.
final class AppLogTests: XCTestCase {
    private func makeLog() -> AppLog {
        AppLog()
    }

    func testRecordingKeepsEntriesInOrder() async {
        let log = makeLog()
        await log.record(.info, "分类甲", "第一条")
        await log.record(.warning, "分类乙", "第二条")

        let entries = await log.recent()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.message), ["第一条", "第二条"])
        XCTAssertEqual(entries.map(\.category), ["分类甲", "分类乙"])
        XCTAssertEqual(entries[1].level, .warning)
    }

    func testRecentRespectsLimitAndKeepsNewest() async {
        let log = makeLog()
        for index in 0 ..< 10 {
            await log.record(.info, "分类", "消息\(index)")
        }

        let entries = await log.recent(3)
        XCTAssertEqual(entries.map(\.message), ["消息7", "消息8", "消息9"])
    }

    func testClearRemovesEverything() async {
        let log = makeLog()
        await log.record(.info, "分类", "消息")
        await log.clear()

        let count = await log.count()
        XCTAssertEqual(count, 0)
    }

    func testExportContainsEveryRecordedMessage() async {
        let log = makeLog()
        await log.record(.info, "进吧等级", "第1页 error_code=0")
        await log.record(.error, "首页推荐", "第2页 失败")

        let text = await log.exportText(deviceSummary: "iOS 18.0 / iPhone")
        XCTAssertTrue(text.contains("第1页 error_code=0"))
        XCTAssertTrue(text.contains("第2页 失败"))
        XCTAssertTrue(text.contains("iOS 18.0 / iPhone"))
        XCTAssertTrue(text.contains("条目数：2"))
    }

    func testRedactionRemovesJSONSecretValues() {
        let text = #"{"error_code":0,"BDUSS":"abcdef123456","STOKEN":"zzzz","tbs":"qqq"}"#
        let redacted = DiagnosticRedaction.redact(text)

        XCTAssertFalse(redacted.contains("abcdef123456"))
        XCTAssertFalse(redacted.contains("zzzz"))
        XCTAssertFalse(redacted.contains("qqq"))
        XCTAssertTrue(redacted.contains("\"error_code\":0"))
    }

    func testRedactionRemovesCookieSecretValues() {
        let text = "BDUSS=secretvalue; STOKEN=other; ka=open"
        let redacted = DiagnosticRedaction.redact(text)

        XCTAssertFalse(redacted.contains("secretvalue"))
        XCTAssertFalse(redacted.contains("other"))
        XCTAssertTrue(redacted.contains("ka=open"))
    }

    func testRedactionKeepsOrdinaryDiagnosticText() {
        let text = "第1页 error_code=0 帖子12条 来源吧=百度贴吧、Android"
        XCTAssertEqual(DiagnosticRedaction.redact(text), text)
    }

    func testRedactionShortensLongOpaqueBlobs() {
        let blob = String(repeating: "a1b2c3d4", count: 12)
        let redacted = DiagnosticRedaction.redact("原始\(blob)字节")

        XCTAssertFalse(redacted.contains(blob))
        XCTAssertTrue(redacted.contains("字节"))
    }

    func testSkeletonReportsKeysWithoutLeakingValues() throws {
        let json = """
        {"error_code":0,"data":{"like_forum":[{"forum_id":1,"level_id":7,"is_sign":1}]}}
        """
        let skeleton = DiagnosticJSON.skeleton(Data(json.utf8))

        XCTAssertTrue(skeleton.contains("error_code"))
        XCTAssertTrue(skeleton.contains("like_forum"))
        XCTAssertTrue(skeleton.contains("level_id"))
        XCTAssertTrue(skeleton.contains("is_sign"))
        XCTAssertTrue(skeleton.contains("Num(7)"))
    }

    func testSkeletonMarksEmptyContainers() {
        XCTAssertEqual(DiagnosticJSON.skeleton(Data("{}".utf8)), "{}")
        XCTAssertEqual(DiagnosticJSON.skeleton(Data("[]".utf8)), "[]")
        XCTAssertEqual(DiagnosticJSON.skeleton(Data("\"\"".utf8)), "String(empty)")
    }

    func testSkeletonNeverTruncatesTheFieldListTheDiagnosisDependsOn() {
        // 顶层键列表就是诊断依据：缺了 like_forum 之外的某个键看不出扁平/嵌套，
        // 所以超过旧的 6 键上限也必须一个不少地打出来。
        let json = #"{"block_pop_info":null,"ctime":"1","data":null,"error_code":0,"error_msg":"","fold_display_num":null,"forum_create_info":null,"like_forum":[],"like_forum_has_more":0,"other":1,"user":{}}"#
        let skeleton = DiagnosticJSON.skeleton(Data(json.utf8))

        for key in [
            "block_pop_info", "ctime", "data", "error_code", "error_msg",
            "fold_display_num", "forum_create_info", "like_forum",
            "like_forum_has_more", "other", "user"
        ] {
            XCTAssertTrue(skeleton.contains(key), "字段 \(key) 不该被截断")
        }
        XCTAssertFalse(skeleton.contains("…"), "字段列表不该再出现 …N more 截断尾")
    }
}
