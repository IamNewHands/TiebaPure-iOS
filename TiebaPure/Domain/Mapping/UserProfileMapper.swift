import Foundation

enum UserProfileMapper {
    static func profile(
        from proto: Tieba_User,
        fallback: UserSummary,
        isCurrentUser: Bool
    ) -> UserProfile {
        let user = UserMapper.fromUser(proto, fallbackID: fallback.id)
        let resolvedUser = UserSummary(
            id: user.id,
            name: firstNonEmpty(user.name, fallback.name),
            displayName: firstNonEmpty(user.displayName, fallback.displayName, user.name),
            portrait: firstNonEmpty(user.portrait, fallback.portrait),
            level: user.level ?? fallback.level,
            levelName: firstNonEmptyOptional(user.levelName, fallback.levelName),
            ipAddress: firstNonEmptyOptional(user.ipAddress, fallback.ipAddress)
        )
        let forums = proto.likeForum.compactMap { item -> Forum? in
            let name = normalizedForumName(item.forumName)
            guard name.isEmpty == false else { return nil }
            let id = Int64(exactly: item.forumID) ?? 0
            return Forum(
                id: id,
                name: name,
                displayName: name.hasSuffix("吧") ? name : "\(name)吧",
                avatarURL: nil,
                memberCount: 0,
                threadCount: 0
            )
        }
        // Privacy is a server-side property. Keep the raw public list here so
        // a local forum block cannot be mistaken for a private profile; the
        // view applies the blocklist only when presenting these forums.
        let uniqueForums = deduplicatedForums(forums)
        let declaredForumCount = max(Int(proto.myLikeNum), uniqueForums.count)
        let privacyValue = proto.hasPrivSets ? Int(proto.privSets.like) : 0

        return UserProfile(
            user: resolvedUser,
            isCurrentUser: isCurrentUser,
            isFollowed: proto.hasConcerned_p != 0,
            tiebaID: firstNonEmpty(proto.tiebaUid, proto.id == 0 ? "" : "\(proto.id)"),
            tiebaAge: proto.tbAge,
            sex: sex(from: proto.sex != 0 ? proto.sex : proto.gender),
            location: firstNonEmptyOptional(proto.ipAddress, proto.ip, fallback.ipAddress),
            intro: firstNonEmpty(proto.displayIntro, proto.intro),
            backgroundURL: TiebaURL.make(proto.bgPic),
            agreeCount: max(Int(proto.totalAgreeNum), Int(proto.agreeNum)),
            followingCount: max(Int(proto.concernNum), 0),
            followerCount: max(Int(proto.fansNum), 0),
            threadCount: max(Int(proto.threadNum), 0),
            followedForumCount: max(declaredForumCount, 0),
            followedForums: uniqueForums,
            followedForumsVisibility: UserProfilePrivacyPolicy.followedForumsVisibility(
                isCurrentUser: isCurrentUser,
                privacyValue: privacyValue,
                declaredCount: declaredForumCount,
                returnedCount: uniqueForums.count
            )
        )
    }

    static func threadsPage(
        from response: Tiebapure_Profile_UserThreadsResponse,
        page: Int
    ) -> UserThreadsPage {
        let rawItems = response.data.postList
        var threads: [ThreadSummary] = []
        var deletionTargetsByThreadID: [Int64: OwnThreadDeletionTarget] = [:]
        for item in rawItems {
            guard let thread = thread(from: item),
                  TiebaContentFilter.shouldKeep(thread: thread) else {
                continue
            }
            threads.append(thread)
            if let deletionTarget = deletionTarget(from: item) {
                deletionTargetsByThreadID[thread.id] = deletionTarget
            }
        }
        return UserThreadsPage(
            threads: threads,
            currentPage: page,
            // A page that only contains blocked entries is still a real
            // server page; keep pagination alive so later visible entries
            // remain reachable.
            hasMore: response.data.hidePost == 0 && rawItems.isEmpty == false,
            visibility: response.data.hidePost == 0 ? .visible : .privateContent,
            deletionTargetsByThreadID: deletionTargetsByThreadID
        )
    }

    /// The reply feed answers with one row per thread and the account's own
    /// replies nested underneath, so the flat list this screen shows is built by
    /// walking both levels. Rows are keyed by post ID: one thread can hold
    /// several of the account's replies.
    static func ownRepliesPage(from response: UserPostFeedDTO, page: Int) -> OwnRepliesPage {
        var replies: [OwnReply] = []
        var seenPostIDs = Set<UInt64>()
        for thread in response.threads {
            guard thread.threadID > 0 else { continue }
            for reply in thread.replies {
                guard reply.postID > 0, seenPostIDs.insert(reply.postID).inserted else { continue }
                replies.append(
                    OwnReply(
                        id: reply.postID,
                        forumID: thread.forumID,
                        forumName: normalizedForumName(thread.forumName),
                        threadID: thread.threadID,
                        threadTitle: thread.title.trimmingCharacters(in: .whitespacesAndNewlines),
                        body: replyBody(from: reply.contents),
                        createdAt: reply.createTime == 0
                            ? nil
                            : Date(timeIntervalSince1970: TimeInterval(reply.createTime))
                    )
                )
            }
        }
        return OwnRepliesPage(
            replies: replies,
            currentPage: page,
            hasMore: response.hidePost == 0 && response.threads.isEmpty == false,
            visibility: response.hidePost == 0 ? .visible : .privateContent
        )
    }

    /// A reply made only of pictures has no text to show, and an empty row would
    /// read as a decode failure rather than as a picture reply.
    private static func replyBody(from contents: [UserPostFeedDTO.ContentDTO]) -> String {
        let text = contents.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty == false { return text }
        return contents.isEmpty ? "" : "［非文字内容］"
    }

    static func deletionTarget(
        from item: Tiebapure_Profile_UserThreadItem
    ) -> OwnThreadDeletionTarget? {
        guard let forumID = Int64(exactly: item.forumID), forumID > 0,
              let threadID = Int64(exactly: item.threadID), threadID > 0,
              item.postID > 0 else {
            return nil
        }
        return OwnThreadDeletionTarget(
            forumID: forumID,
            forumName: item.forumName,
            threadID: threadID,
            firstPostID: item.postID
        )
    }

    static func thread(from item: Tiebapure_Profile_UserThreadItem) -> ThreadSummary? {
        guard let threadID = Int64(exactly: item.threadID), threadID > 0 else { return nil }

        var blocks = PostMapper.blocks(from: item.firstPostContent)
        if blocks.isEmpty {
            blocks = PostMapper.blocks(from: item.richAbstract)
        }
        blocks = PostMapper.appendingUniqueVoices(from: item.voiceInfo, to: blocks)
        if blocks.isEmpty {
            let abstractText = item.abstractThread
                .map(\.text)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackText = firstNonEmpty(abstractText, item.contentThread)
            if fallbackText.isEmpty == false {
                blocks = [.text(fallbackText)]
            }
        }
        for media in item.media {
            guard let block = PostMapper.imageBlock(from: media), contains(block, in: blocks) == false else {
                continue
            }
            blocks.append(block)
        }

        let richTitle = PostMapper.blocks(from: item.richTitle)
            .compactMap(\.plainText)
            .joined()
        let authorName = firstNonEmpty(item.nameShow, item.userName, item.userID == 0 ? "" : "用户\(item.userID)")
        let forumID = Int64(exactly: item.forumID)

        return ThreadSummary(
            id: threadID,
            forumID: (forumID ?? 0) == 0 ? nil : forumID,
            title: firstNonEmpty(item.title, richTitle),
            author: UserSummary(
                id: item.userID,
                name: firstNonEmpty(item.userName, authorName),
                displayName: authorName,
                portrait: item.userPortrait,
                ipAddress: item.ip
            ),
            forumName: normalizedForumName(item.forumName),
            replyCount: Int(item.replyNum),
            viewCount: max(Int(item.viewNum), 0),
            likeCount: max(Int(item.agreeNum), 0),
            createdAt: item.createTime == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(item.createTime)),
            lastReplyAt: nil,
            blocks: blocks,
            hasVideo: false
        )
    }

    private static func sex(from value: Int32) -> UserProfileSex {
        switch value {
        case 1:
            return .male
        case 2:
            return .female
        default:
            return .unspecified
        }
    }

    // Forum names route by their verbatim API value; stripping a trailing
    // "吧" would misroute forums genuinely named 网吧/酒吧.
    private static func normalizedForumName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deduplicatedForums(_ forums: [Forum]) -> [Forum] {
        var seen = Set<String>()
        return forums.filter { forum in
            let key = forum.id != 0 ? "id:\(forum.id)" : "name:\(forum.name.lowercased())"
            return seen.insert(key).inserted
        }
    }

    private static func contains(_ candidate: ContentBlock, in blocks: [ContentBlock]) -> Bool {
        guard case let .image(candidateImage) = candidate else { return false }
        let candidateURLs = [candidateImage.thumbnailURL, candidateImage.originalURL].compactMap { $0 }
        return blocks.contains { block in
            guard case let .image(image) = block else { return false }
            let existingURLs = [image.thumbnailURL, image.originalURL].compactMap { $0 }
            return candidateURLs.contains { existingURLs.contains($0) }
        }
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.isEmpty == false } ?? ""
    }

    private static func firstNonEmptyOptional(_ values: String?...) -> String? {
        let value = values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.isEmpty == false } ?? ""
        return value.isEmpty ? nil : value
    }
}
