import Foundation

enum TiebaHotRequestFactory {
    /// The hot-thread endpoint answers with the default tab when the tab code is
    /// empty — together with the tab list — and with one specific tab otherwise,
    /// so the tab id stays fixed and the code is the only variable part.
    static func request(
        account: Account?,
        tabCode: String,
        requestBuilder: TiebaRequestBuilder
    ) -> Tieba_HotThreadList_HotThreadListRequest {
        var requestData = Tieba_HotThreadList_HotThreadListRequestData()
        requestData.common = requestBuilder.common(account: account)
        requestData.tabID = "1"
        requestData.tabCode = tabCode

        var request = Tieba_HotThreadList_HotThreadListRequest()
        request.data = requestData
        return request
    }
}

enum HotFeedMapper {
    static func makeFeed(
        from data: Tieba_HotThreadList_HotThreadListResponseData
    ) -> HotFeed {
        HotFeed(
            tabs: data.hotThreadTabInfo.compactMap { tab in
                // A tab without a code cannot be requested, and a tab without a
                // name has nothing to show on the tab bar.
                guard tab.tabCode.isEmpty == false, tab.tabName.isEmpty == false else { return nil }
                return HotTab(code: tab.tabCode, name: tab.tabName)
            },
            threads: dedupedByID(
                data.threadInfo
                    .filter(TiebaContentFilter.shouldMap(thread:))
                    .map { ThreadMapper.fromThreadInfo($0, usersByID: [:]) }
            )
        )
    }

    /// The same thread can appear twice in one listing (a pinned row repeated at
    /// the top of a sub-tab), and duplicate row identities break list diffing.
    private static func dedupedByID(_ threads: [ThreadSummary]) -> [ThreadSummary] {
        var seen = Set<Int64>()
        return threads.filter { seen.insert($0.id).inserted }
    }
}

extension TiebaAPI {
    /// 热点 (hot threads) for one sub-tab of the home hot-thread tab.
    ///
    /// An empty `tabCode` asks for the service's default tab and the tab list,
    /// which is how the tab bootstraps its own sub-tabs before the user picks
    /// one. Threads are filtered and mapped exactly like the personalized feed
    /// so both tabs share one row presentation.
    func hotThreads(account: Account?, tabCode: String) async throws -> HotFeed {
        let request = TiebaHotRequestFactory.request(
            account: account,
            tabCode: tabCode,
            requestBuilder: requestBuilder
        )
        let multipart = try requestBuilder.multipart(
            protobuf: request,
            account: account,
            includeSToken: false
        )
        do {
            let response = try await client.postProtobuf(
                .hotThreadList,
                body: multipart.body,
                contentType: multipart.contentType,
                headers: [
                    "X-BD-DATA-TYPE": "protobuf",
                    "Cookie": TiebaFeedCookie.value(for: account)
                ],
                as: Tieba_HotThreadList_HotThreadListResponse.self
            )

            try validateTiebaError(response.error)
            guard response.hasData else { throw TiebaAPIError.emptyResponse }
            let feed = HotFeedMapper.makeFeed(from: response.data)
            await AppLog.shared.record(
                .info,
                "首页热点",
                "tabCode=\(tabCode.isEmpty ? "(默认)" : tabCode) 已登录=\(account != nil) "
                    + "子标签=\(feed.tabs.map(\.name).joined(separator: "/")) 帖子\(feed.threads.count)条 "
                    + "来源吧=\(Self.forumNames(feed.threads))"
            )
            return feed
        } catch {
            await AppLog.shared.recordError(
                "首页热点",
                "tabCode=\(tabCode.isEmpty ? "(默认)" : tabCode) 失败",
                error: error
            )
            throw error
        }
    }

    /// A hot listing has no per-forum grouping, so the forum names are the only
    /// way to tell "the service sent the global hot list" from "the service sent
    /// the tab we expected" once a user compares it with the official app.
    private static func forumNames(_ threads: [ThreadSummary]) -> String {
        let names = threads
            .prefix(8)
            .compactMap { $0.forumName?.isEmpty == false ? $0.forumName : nil }
        guard names.isEmpty == false else { return "(帖子未带吧名)" }
        return names.joined(separator: "、")
    }
}