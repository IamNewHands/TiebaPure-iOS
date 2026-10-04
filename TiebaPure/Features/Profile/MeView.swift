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
    @State private var isDeleting = false
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
                            Button {
                                openThread(reply)
                            } label: {
                                row(reply)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("my-reply-\(reply.id)")
                            .swipeActions(edge: .trailing) {
                                Button("删除", role: .destructive) {
                                    pendingDeletion = reply
                                }
                            }
                        }
                    } footer: {
                        Text("左滑一条回复可以删除它。删除只影响这一条回复，不会动主题帖。")
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

    private func replyPreview(_ reply: OwnReply) -> String {
        let text = reply.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return "（无文字内容）" }
        return String(text.prefix(60))
    }

    private func openThread(_ reply: OwnReply) {
        guard reply.threadID > 0 else { return }
        openThreadInParent(
            ReaderSplitThreadRoute(
                threadID: reply.threadID,
                forumID: reply.forumID > 0 ? reply.forumID : nil
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
            if replacing {
                replies = page.replies
            } else {
                var seen = Set(replies.map(\.id))
                for reply in page.replies where seen.insert(reply.id).inserted {
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
        guard isDeleting == false else { return }
        isDeleting = true
        pendingDeletion = nil
        defer { isDeleting = false }
        do {
            try await environment.api.deleteOwnReply(account: account, reply: reply)
            replies.removeAll { $0.id == reply.id }
        } catch {
            actionError = ReaderErrorMessage.message(for: error)
        }
    }
}
