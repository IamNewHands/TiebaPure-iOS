import Foundation

/// The 热点 (hot-thread) tab as one response: the service's own sub-tabs and
/// the hot threads themselves.
///
/// The tab list comes back on every request, so switching sub-tabs keeps the
/// same set of tabs without a second discovery call.
struct HotFeed: Equatable, Sendable {
    var tabs: [HotTab] = []
    var threads: [ThreadSummary] = []
}

/// One sub-tab of the hot-thread listing.
struct HotTab: Identifiable, Equatable, Sendable {
    /// The whole-list tab. The service reports only its category sub-tabs
    /// (视频/长更/游戏/数码…) in `hot_thread_tab_info`, and `tab_code="all"` is
    /// the only request that answers with the full hot list — so the chip is
    /// built here, and it is also what a freshly opened tab starts on.
    static let allCode = "all"
    static let allName = "全部"
    static let all = HotTab(code: allCode, name: allName)

    var code: String
    var name: String

    var id: String { code }
}