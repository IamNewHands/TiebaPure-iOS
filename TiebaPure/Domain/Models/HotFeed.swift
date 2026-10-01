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

/// One sub-tab of the hot-thread listing. An empty code means the service's
/// default tab, which is how the tab asks for the first page.
struct HotTab: Identifiable, Equatable, Sendable {
    var code: String
    var name: String

    var id: String { code }
}