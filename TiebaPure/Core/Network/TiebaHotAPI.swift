import Foundation

enum TiebaHotRequestFactory {
    /// One listing per sub-tab: the tab id stays fixed and the code is the only
    /// variable part. The tab list itself comes back on every response, so the
    /// first request needs no discovery round.
    ///
    /// An empty code is not a usable "default": the service answers it with a
    /// stub of a handful of threads, while `tab_code="all"` is the whole hot
    /// list. The view therefore asks for `HotTab.allCode` and this mapping only
    /// keeps an empty caller from reproducing the stub.
    static func request(
        account: Account?,
        tabCode: String,
        requestBuilder: TiebaRequestBuilder
    ) -> Tieba_HotThreadList_HotThreadListRequest {
        var requestData = Tieba_HotThreadList_HotThreadListRequestData()
        requestData.common = requestBuilder.common(account: account)
        requestData.tabID = "1"
        requestData.tabCode = tabCode.isEmpty ? HotTab.allCode : tabCode

        var request = Tieba_HotThreadList_HotThreadListRequest()
        request.data = requestData
        return request
    }
}

enum HotFeedMapper {
    static func makeFeed(
        from data: Tieba_HotThreadList_HotThreadListResponseData
    ) -> HotFeed {
        let reported = data.hotThreadTabInfo.compactMap { tab -> HotTab? in
            // A tab without a code cannot be requested, and a tab without a
            // name has nothing to show on the tab bar.
            guard tab.tabCode.isEmpty == false, tab.tabName.isEmpty == false else { return nil }
            return HotTab(code: tab.tabCode, name: tab.tabName)
        }
        var tabs = reported
        // The service lists only its category sub-tabs, so without this chip
        // the bar would have no way back to the whole list after a category is
        // picked. A category already called "all" would then duplicate it.
        if tabs.contains(where: { $0.code == HotTab.allCode }) == false {
            tabs.insert(HotTab.all, at: 0)
        }
        return HotFeed(
            tabs: tabs,
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
    /// An empty `tabCode` is resolved to `HotTab.allCode`, so every request
    /// names a real listing. Threads are filtered and mapped exactly like the
    /// personalized feed so both tabs share one row presentation.
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
            // The service's own tab list (with codes) is what decides whether a
            // missing 全部 is a server change or a local one, and the raw count
            // separates "the service sent four threads" from "we filtered them".
            let serverTabs = response.data.hotThreadTabInfo
                .map { "\($0.tabName)(\($0.tabCode))" }
                .joined(separator: "/")
            await AppLog.shared.record(
                .info,
                "首页热点",
                "tabCode=\(tabCode.isEmpty ? HotTab.allCode : tabCode) 已登录=\(account != nil) "
                    + "服务端子标签=\(serverTabs.isEmpty ? "(无)" : serverTabs) "
                    + "展示=\(feed.tabs.map(\.name).joined(separator: "/")) "
                    + "原始\(response.data.threadInfo.count)条 保留\(feed.threads.count)条 "
                    + "来源吧=\(Self.forumNames(feed.threads))"
            )
            return feed
        } catch {
            await AppLog.shared.recordError(
                "首页热点",
                "tabCode=\(tabCode.isEmpty ? HotTab.allCode : tabCode) 失败",
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