import Foundation
import SwiftUI

struct MeView: View {
    let account: Account?

    @ObservedObject private var browsingHistoryStore = BrowsingHistoryStore.shared
    @ObservedObject private var blocklistStore = BlocklistStore.shared
    @State private var showsLogin = false
    @State private var navigationPath: [MeNavigationRoute] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Form {
                if let account {
                    Section("账号") {
                        Button {
                            openUser(userSummary(for: account), sourceThreadID: nil)
                        } label: {
                            HStack(spacing: TiebaPureTheme.Spacing.sm) {
                                AvatarView(
                                    url: account.portraitURL,
                                    title: account.displayName,
                                    size: TiebaPureTheme.AvatarSize.large
                                )

                                VStack(alignment: .leading, spacing: TiebaPureTheme.Spacing.xxs) {
                                    Text(account.displayName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)

                                    Text("UID \(account.uid)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: TiebaPureTheme.Spacing.sm)

                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, TiebaPureTheme.Spacing.xs)
                        .accessibilityLabel("查看\(account.displayName)的用户主页")
                        .accessibilityHint("打开自己的用户主页")
                        .accessibilityIdentifier("me-user-profile-button")

                        Button {
                            navigationPath.append(.messages)
                        } label: {
                            Label("消息", systemImage: "bell")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("消息")
                        .accessibilityHint("查看回复我的和@我的消息")
                        .accessibilityIdentifier("me-messages-entry")

                        Button {
                            navigationPath.append(.followedUsers)
                        } label: {
                            Label("关注的用户", systemImage: "person.2")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("查看当前账号关注的用户")
                        .accessibilityIdentifier("followed-users-entry")

                        Button {
                            navigationPath.append(.followedForums)
                        } label: {
                            Label("关注的吧", systemImage: "star")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关注的吧")
                        .accessibilityHint("打开已关注的贴吧列表")
                        .accessibilityIdentifier("followed-forums-entry")

                        Button {
                            navigationPath.append(.myReplies)
                        } label: {
                            Label("我的回帖", systemImage: "text.bubble")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("我的回帖")
                        .accessibilityHint("查看并逐条删除这个账号发过的回复")
                        .accessibilityIdentifier("my-replies-entry")

                        Button {
                            navigationPath.append(.myDrafts)
                        } label: {
                            Label("我的草稿", systemImage: "doc.text")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("我的草稿")
                        .accessibilityHint("查看本机保存的草稿，并逐条删除")
                        .accessibilityIdentifier("my-drafts-entry")
                    }
                } else {
                    Section("账号") {
                        VStack(alignment: .leading, spacing: TiebaPureTheme.Spacing.sm) {
                            Label("未登录也可以浏览公开帖子", systemImage: "book")
                                .font(.body)

                            Button {
                                showsLogin = true
                            } label: {
                                Label("手机号验证码登录", systemImage: "iphone.gen2")
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .accessibilityHint("打开百度移动登录页，使用手机号和验证码登录。")
                        }
                        .padding(.vertical, TiebaPureTheme.Spacing.xs)
                    }
                }

                Section("浏览") {
                    Button {
                        navigationPath.append(.threadFavorites)
                    } label: {
                        Label("帖子收藏", systemImage: "star")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("帖子收藏")
                    .accessibilityHint("查看贴吧账号里收藏的帖子")
                    .accessibilityIdentifier("thread-favorites-entry")

                    Button {
                        navigationPath.append(.browsingHistory)
                    } label: {
                        HStack(spacing: TiebaPureTheme.Spacing.sm) {
                            Label("浏览历史", systemImage: "clock.arrow.circlepath")
                            Spacer(minLength: TiebaPureTheme.Spacing.sm)
                            if visibleHistoryCount > 0 {
                                Text("\(visibleHistoryCount)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(browsingHistoryAccessibilityLabel)
                    .accessibilityHint("查看本机保存的帖子浏览记录")
                    .accessibilityIdentifier("browsing-history-entry")
                }

                Section("应用") {
                    Button {
                        navigationPath.append(.settings)
                    } label: {
                        Label("设置", systemImage: "gearshape")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("调整显示模式和其他应用设置")
                    .accessibilityIdentifier("app-settings-entry")

                    Button {
                        navigationPath.append(.about)
                    } label: {
                        Label("关于 TiebaPure", systemImage: "info.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("查看来源、许可证和源码链接")
                }
            }
            .navigationTitle("我的")
            .interactiveNavigationPopRevealSource()
            .navigationDestination(for: MeNavigationRoute.self) { route in
                destination(for: route)
            }
            .sheet(isPresented: $showsLogin) {
                NavigationStack {
                    LoginView()
                        .navigationTitle("手机号验证码登录")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("关闭") {
                                    showsLogin = false
                                }
                            }
                        }
                }
            }
            .onChange(of: account?.id) { newValue in
                if newValue != nil {
                    showsLogin = false
                } else {
                    navigationPath = []
                }
            }
        }
        .toolbar(.visible, for: .tabBar)
    }

    private var browsingHistoryAccessibilityLabel: String {
        guard visibleHistoryCount > 0 else { return "浏览历史" }
        return "浏览历史，共 \(visibleHistoryCount) 条"
    }

    private var currentBlocklist: BlocklistSnapshot {
        BlocklistSnapshot(entries: blocklistStore.entries)
    }

    private var visibleHistoryCount: Int {
        BrowsingHistoryListPolicy.visibleEntries(
            browsingHistoryStore.items,
            blocklist: currentBlocklist
        ).count
    }

    private func userSummary(for account: Account) -> UserSummary {
        UserSummary(
            id: Int64(account.uid) ?? 0,
            name: account.name,
            displayName: account.displayName,
            portrait: account.portrait
        )
    }

    @ViewBuilder
    private func destination(for route: MeNavigationRoute) -> some View {
        switch route {
        case .messages:
            if let account {
                MessagesView(account: account, openThreadInParent: openThread)
            }
        case .followedForums:
            if let account {
                ForumListView(account: account, openForumInParent: openForum)
            }
        case .myReplies:
            if let account {
                MyRepliesView(account: account, openThreadInParent: openThread)
            }
        case .myDrafts:
            if let account {
                MyDraftsView(
                    account: account,
                    openThreadInParent: openThread,
                    openForumInParent: openForum
                )
            }
        case .followedUsers:
            if let account {
                FollowedUsersView(account: account, openUserInParent: { user in
                    openUser(user, sourceThreadID: nil)
                })
            }
        case .threadFavorites:
            ThreadFavoritesView(account: account, openThreadInParent: openThread)
        case .browsingHistory:
            BrowsingHistoryView(account: account, openThreadInParent: openThread)
        case .settings:
            SettingsView(account: account)
        case .about:
            AboutView()
        case let .thread(threadRoute):
            ThreadDetailView(
                account: account,
                threadID: threadRoute.threadID,
                forumID: threadRoute.forumID,
                initialPostID: threadRoute.initialPostID,
                initialDestination: threadRoute.initialDestination,
                ownThreadDeletionTarget: threadRoute.ownThreadDeletionTarget,
                openUserInParent: { user in
                    openUser(user, sourceThreadID: threadRoute.threadID)
                },
                openForumInParent: openForum
            )
        case let .forum(id, name, displayName, avatarURL):
            ForumThreadsView(
                account: account,
                forum: Forum(
                    id: id,
                    name: name,
                    displayName: displayName,
                    avatarURL: avatarURL,
                    memberCount: 0,
                    threadCount: 0
                ),
                openThreadInParent: openThread,
                openUserInParent: { user in
                    openUser(user, sourceThreadID: nil)
                }
            )
        case let .user(user, sourceThreadID):
            UserProfileView(
                account: account,
                user: user,
                sourceThreadID: sourceThreadID,
                onReturnToSourceThread: {
                    navigationPath = MeNavigationPathPolicy.removingCurrent(
                        route,
                        from: navigationPath
                    )
                },
                openThreadInParent: openThread,
                openForumInParent: openForum
            )
        }
    }

    private func openThread(_ route: ReaderSplitThreadRoute) {
        navigationPath = MeNavigationPathPolicy.pushing(.thread(route), onto: navigationPath)
    }

    private func openForum(_ forum: Forum) {
        navigationPath = MeNavigationPathPolicy.pushing(.fromForum(forum), onto: navigationPath)
    }

    private func openUser(_ user: UserSummary, sourceThreadID: Int64?) {
        navigationPath = MeNavigationPathPolicy.pushing(
            .user(user: user, sourceThreadID: sourceThreadID),
            onto: navigationPath
        )
    }
}

enum MeNavigationRoute: Hashable {
    case messages
    case followedForums
    case followedUsers
    case myReplies
    case myDrafts
    case threadFavorites
    case browsingHistory
    case settings
    case about
    case thread(ReaderSplitThreadRoute)
    case forum(id: Int64, name: String, displayName: String, avatarURL: URL?)
    case user(user: UserSummary, sourceThreadID: Int64?)

    static func fromForum(_ forum: Forum) -> MeNavigationRoute {
        .forum(
            id: forum.id,
            name: forum.name,
            displayName: forum.displayName,
            avatarURL: forum.avatarURL
        )
    }
}

enum MeNavigationPathPolicy {
    static func pushing(
        _ route: MeNavigationRoute,
        onto path: [MeNavigationRoute]
    ) -> [MeNavigationRoute] {
        path + [route]
    }

    static func removingCurrent(
        _ route: MeNavigationRoute,
        from path: [MeNavigationRoute]
    ) -> [MeNavigationRoute] {
        guard path.last == route else { return path }
        return Array(path.dropLast())
    }
}

/// Replies this session deleted, so a list feed that still returns one cannot put
/// the row back.
///
/// The service keeps answering its own reply feed with a deleted reply for an
/// unbounded while afterwards, and every re-entry into 我的回帖 reloads from that
/// feed, which is why a deleted row used to reappear until the service caught up.
/// The record lives in memory only: it ends with the process, and the next launch
/// reads whatever the service says by then.
final class OwnReplyDeletionLedger {
    static let shared = OwnReplyDeletionLedger()

    private let lock = NSLock()
    private var deletedIDs: Set<UInt64> = []
    private var insertionOrder: [UInt64] = []
    /// Bounded so a long session cannot grow the set without limit.
    private let capacity: Int

    init(capacity: Int = 200) {
        self.capacity = max(capacity, 1)
    }

    func contains(_ id: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return deletedIDs.contains(id)
    }

    func record(_ id: UInt64) {
        guard id > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard deletedIDs.insert(id).inserted else { return }
        insertionOrder.append(id)
        while insertionOrder.count > capacity {
            deletedIDs.remove(insertionOrder.removeFirst())
        }
    }

    /// Drops the replies this account already deleted from a freshly loaded page.
    /// The dropped IDs come back so the caller can report that the service is
    /// still serving them.
    func removingDeletedReplies(
        from replies: [OwnReply]
    ) -> (visible: [OwnReply], droppedIDs: [UInt64]) {
        lock.lock()
        let deleted = deletedIDs
        lock.unlock()
        guard deleted.isEmpty == false else { return (replies, []) }

        var droppedIDs: [UInt64] = []
        let visible = replies.filter { reply in
            guard deleted.contains(reply.id) else { return true }
            droppedIDs.append(reply.id)
            return false
        }
        return (visible, droppedIDs)
    }
}

/// 我的回帖: every reply this account wrote, each one deletable in place.
///
/// The profile page lists threads only, and the only thing the app could delete
/// was a thread, so a reply could neither be found nor removed. Rows come from
/// the reply feed (`is_thread = 0`) and delete by the reply's own post ID.
struct MyRepliesView: View {
    @EnvironmentObject private var environment: AppEnvironment

    let account: Account
    let openThreadInParent: (ReaderSplitThreadRoute) -> Void

    @State private var replies: [OwnReply] = []
    @State private var nextPage = 1
    @State private var hasMore = true
    @State private var visibility: UserContentVisibility = .visible
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var errorMessage: String?
    @State private var pendingDeletion: OwnReply?
    @State private var deletingReplyID: UInt64?
    @State private var actionError: String?

    private var userID: Int64 { Int64(account.uid) ?? 0 }

    var body: some View {
        Group {
            if isLoading, replies.isEmpty {
                ReaderStateView.loading("正在加载你的回帖")
                    .frame(minHeight: 220)
                    .background(Color(uiColor: .systemBackground))
            } else if let errorMessage, replies.isEmpty {
                ReaderStateView.error(message: errorMessage) {
                    Task { await reload() }
                }
                .frame(minHeight: 220)
                .background(Color(uiColor: .systemBackground))
            } else if visibility == .privateContent {
                ReaderStateView.empty(
                    title: "贴吧没有返回你的回帖",
                    message: "该列表当前不可见，稍后再试。"
                )
                .frame(minHeight: 220)
                .background(Color(uiColor: .systemBackground))
                .accessibilityIdentifier("my-replies-private")
            } else if replies.isEmpty {
                ReaderStateView.empty(
                    title: "还没有可管理的回帖",
                    message: "这个账号发过的回复会列在这里，可以逐条删除。",
                    actionTitle: hasMore ? "继续加载" : nil,
                    action: hasMore ? { Task { await loadMore() } } : nil
                )
                .frame(minHeight: 220)
                .background(Color(uiColor: .systemBackground))
                .accessibilityIdentifier("my-replies-empty")
            } else {
                List {
                    Section {
                        ForEach(replies) { reply in
                            HStack(spacing: TiebaPureTheme.Spacing.sm) {
                                Button {
                                    openThread(reply)
                                } label: {
                                    row(reply)
                                }
                                .buttonStyle(.plain)
                                .disabled(deletingReplyID != nil)
                                .accessibilityIdentifier("my-reply-\(reply.id)")

                                // A visible delete control: the row is a
                                // navigation button, so a swipe alone left the
                                // list looking like it had no way to delete.
                                Button {
                                    pendingDeletion = reply
                                } label: {
                                    deleteControlLabel(for: reply)
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                                .disabled(deletingReplyID != nil)
                                .accessibilityLabel("删除这条回复")
                                .accessibilityIdentifier("my-reply-delete-\(reply.id)")
                            }
                            .swipeActions(edge: .trailing) {
                                Button("删除", role: .destructive) {
                                    pendingDeletion = reply
                                }
                                .disabled(deletingReplyID != nil)
                            }
                        }
                    } footer: {
                        // A delete used to sit on a write token that measured
                        // twenty seconds before the row even reached the
                        // service, so the wait was named. The token now comes
                        // from the fast route and the copy only says what is
                        // happening.
                        if deletingReplyID != nil {
                            Text("正在删除这条回复，请不要离开这个页面。")
                        } else {
                            Text("点右侧垃圾桶或左滑一条回复可以删除它。删除只影响这一条回复，不会动主题帖。")
                        }
                    }

                    if hasMore {
                        Section {
                            Button("加载更多") {
                                Task { await loadMore() }
                            }
                            .disabled(isLoading)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .accessibilityIdentifier("my-replies-load-more")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await reload() }
            }
        }
        .navigationTitle("我的回帖")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reloadIfNeeded() }
        .confirmationDialog(
            "删除这条回复？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if $0 == false { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let reply = pendingDeletion {
                Button("删除回复", role: .destructive) {
                    Task { await delete(reply) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let reply = pendingDeletion {
                Text("将删除你在「\(reply.forumName)」的这条回复：\n\(replyPreview(reply))")
            }
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if $0 == false { actionError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private func row(_ reply: OwnReply) -> some View {
        VStack(alignment: .leading, spacing: TiebaPureTheme.Spacing.xxs) {
            HStack(spacing: TiebaPureTheme.Spacing.xs) {
                if reply.forumName.isEmpty == false {
                    Text(reply.forumName)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(TiebaPureTheme.ColorToken.primaryAccent)
                        .lineLimit(1)
                }

                Spacer(minLength: TiebaPureTheme.Spacing.xs)

                if let createdAt = reply.createdAt {
                    Text(ReaderDateText.string(from: createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if reply.threadTitle.isEmpty == false {
                Text(reply.threadTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(reply.body.isEmpty ? "（无文字内容）" : reply.body)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, TiebaPureTheme.Spacing.xxs)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func deleteControlLabel(for reply: OwnReply) -> some View {
        if deletingReplyID == reply.id {
            ProgressView()
                .frame(width: 44, height: 44)
        } else {
            Image(systemName: "trash")
                .font(.body)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    private func replyPreview(_ reply: OwnReply) -> String {
        let text = reply.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return "（无文字内容）" }
        return String(text.prefix(60))
    }

    /// Opens the thread at the reply itself, not just the thread.
    ///
    /// A floor reply's own post ID is a floor, so the thread screen loads the page
    /// holding it and scrolls there. A 楼中楼 reply's ID is not a floor — the feed
    /// reports `post_type = 1` for those — so it travels as a 楼中楼 target and the
    /// thread screen resolves the parent floor and rings the reply itself.
    private func openThread(_ reply: OwnReply) {
        guard reply.threadID > 0 else { return }
        openThreadInParent(
            ReaderSplitThreadRoute(
                threadID: reply.threadID,
                forumID: reply.forumID > 0 ? reply.forumID : nil,
                initialPostID: reply.isSubpost ? nil : reply.id,
                initialSubpostID: reply.isSubpost ? reply.id : nil
            )
        )
    }

    private func reloadIfNeeded() async {
        guard didLoad == false else { return }
        didLoad = true
        await reload()
    }

    private func reload() async {
        nextPage = 1
        hasMore = true
        await load(replacing: true)
    }

    private func loadMore() async {
        await load(replacing: false)
    }

    private func load(replacing: Bool) async {
        guard isLoading == false, replacing || hasMore else { return }
        let requestedPage = replacing ? 1 : nextPage
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await environment.api.userReplies(
                account: account,
                userID: userID,
                page: requestedPage
            )
            visibility = page.visibility
            let (visibleReplies, stillServedIDs) = OwnReplyDeletionLedger.shared
                .removingDeletedReplies(from: page.replies)
            if stillServedIDs.isEmpty == false {
                // Evidence, not noise: it says the service is still listing a reply
                // this account already deleted, which is the lag the ledger hides.
                await AppLog.shared.record(
                    .warning,
                    "删除回帖",
                    "列表仍返回已删除的 pid=\(stillServedIDs.map(String.init).joined(separator: ","))，已在本机隐藏"
                )
            }
            if replacing {
                replies = visibleReplies
            } else {
                var seen = Set(replies.map(\.id))
                for reply in visibleReplies where seen.insert(reply.id).inserted {
                    replies.append(reply)
                }
            }
            hasMore = page.visibility == .visible && page.hasMore
            nextPage = requestedPage + 1
        } catch is CancellationError {
            return
        } catch {
            errorMessage = ReaderErrorMessage.message(for: error)
        }
    }

    private func delete(_ reply: OwnReply) async {
        guard deletingReplyID == nil else { return }
        deletingReplyID = reply.id
        pendingDeletion = nil
        defer { deletingReplyID = nil }
        do {
            try await environment.api.deleteOwnReply(account: account, reply: reply)
            // Removing the row here is not enough on its own: the service's reply
            // feed keeps returning a just-deleted reply for a while, and every
            // re-entry reloads from it, so the deletion is remembered for this
            // session as well.
            OwnReplyDeletionLedger.shared.record(reply.id)
            replies.removeAll { $0.id == reply.id }
        } catch {
            actionError = ReaderErrorMessage.message(for: error)
        }
    }
}

/// 我的草稿: every draft this account holds on this device.
///
/// A draft was only reachable by opening the editor for that exact target, so a
/// draft kept "just in case" could neither be found nor removed. This lists them
/// with where each one would be posted, and deletes one at a time.
struct MyDraftsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    let account: Account
    let openThreadInParent: (ReaderSplitThreadRoute) -> Void
    let openForumInParent: (Forum) -> Void

    @State private var drafts: [ContentDraftSummary] = []
    @State private var isLoading = false
    @State private var didLoad = false
    @State private var errorMessage: String?
    @State private var pendingDeletion: ContentDraftSummary?
    @State private var actionError: String?

    var body: some View {
        Group {
            if isLoading, drafts.isEmpty {
                ReaderStateView.loading("正在读取本机草稿")
                    .frame(minHeight: 220)
                    .background(Color(uiColor: .systemBackground))
            } else if let errorMessage, drafts.isEmpty {
                ReaderStateView.error(message: errorMessage) {
                    Task { await load() }
                }
                .frame(minHeight: 220)
                .background(Color(uiColor: .systemBackground))
            } else if drafts.isEmpty {
                ReaderStateView.empty(
                    title: "本机没有草稿",
                    message: "编辑器里「保存草稿」保存的内容会出现在这里。"
                )
                .frame(minHeight: 220)
                .background(Color(uiColor: .systemBackground))
                .accessibilityIdentifier("my-drafts-empty")
            } else {
                List {
                    Section {
                        ForEach(drafts) { draft in
                            HStack(spacing: TiebaPureTheme.Spacing.sm) {
                                Button {
                                    open(draft)
                                } label: {
                                    row(draft)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("my-draft-\(draft.target.draftKey)")

                                Button {
                                    pendingDeletion = draft
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.body)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                                .accessibilityLabel("删除这份草稿")
                                .accessibilityIdentifier("my-draft-delete-\(draft.target.draftKey)")
                            }
                            .swipeActions(edge: .trailing) {
                                Button("删除", role: .destructive) {
                                    pendingDeletion = draft
                                }
                            }
                        }
                    } footer: {
                        Text("点右侧垃圾桶或左滑可以删除一份草稿；删除只影响本机这份草稿。")
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
            }
        }
        .navigationTitle("我的草稿")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadIfNeeded() }
        .confirmationDialog(
            "删除这份草稿？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if $0 == false { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let draft = pendingDeletion {
                Button("删除草稿", role: .destructive) {
                    delete(draft)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let draft = pendingDeletion {
                Text("将删除「\(draft.prompt)」的本机草稿：\n\(preview(draft))")
            }
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if $0 == false { actionError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private func row(_ draft: ContentDraftSummary) -> some View {
        VStack(alignment: .leading, spacing: TiebaPureTheme.Spacing.xxs) {
            HStack(spacing: TiebaPureTheme.Spacing.xs) {
                Text(draft.prompt)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(TiebaPureTheme.ColorToken.primaryAccent)
                    .lineLimit(2)

                Spacer(minLength: TiebaPureTheme.Spacing.xs)

                Text(ReaderDateText.string(from: draft.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                Text(draft.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(preview(draft))
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            if draft.hasAttachments {
                Text("含图片附件（\(byteCountText(draft.attachmentPayloadByteCount))）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, TiebaPureTheme.Spacing.xxs)
        .contentShape(Rectangle())
    }

    private func preview(_ draft: ContentDraftSummary) -> String {
        let text = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return "（无文字内容）" }
        return String(text.prefix(80))
    }

    private func byteCountText(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// Opens what the draft is about: the thread it replies to, or the forum it
    /// would post in. The editor itself is only opened from the entry point the
    /// draft belongs to, which knows the reply context.
    private func open(_ draft: ContentDraftSummary) {
        let target = draft.target
        if let threadID = target.threadID, threadID > 0 {
            openThreadInParent(
                ReaderSplitThreadRoute(
                    threadID: threadID,
                    forumID: target.forumID > 0 ? target.forumID : nil
                )
            )
        } else if target.forumID > 0 {
            openForumInParent(
                Forum(
                    id: target.forumID,
                    name: target.forumName,
                    displayName: target.forumDisplayName,
                    avatarURL: ForumAvatarIndex.shared.url(for: target.forumID),
                    memberCount: 0,
                    threadCount: 0
                )
            )
        }
    }

    private func loadIfNeeded() async {
        guard didLoad == false else { return }
        didLoad = true
        await load()
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            drafts = try await environment.contentDraftStore.summaries(accountID: account.id)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = ReaderErrorMessage.message(for: error)
        }
    }

    private func delete(_ draft: ContentDraftSummary) {
        pendingDeletion = nil
        guard environment.contentDraftStore.delete(
            accountID: draft.accountID,
            target: draft.target
        ) else {
            actionError = "本机草稿删除失败，草稿仍然保留。"
            return
        }
        drafts.removeAll { $0.id == draft.id }
    }
}
