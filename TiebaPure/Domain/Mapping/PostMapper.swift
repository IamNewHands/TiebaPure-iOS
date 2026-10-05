import Foundation

enum PostMapper {
    static func blocks(from contents: [Tieba_PbContent]) -> [ContentBlock] {
        deduplicatingVoices(in: contents.flatMap(blocks))
    }

    static func subpostBlocks(
        from contents: [Tieba_PbContent],
        usersByID: [Int64: Tieba_User]
    ) -> [ContentBlock] {
        let mapped = blocks(from: contents)
        let resolved = ReplyTargetResolver.resolve(in: mapped, usersByID: usersByID)
        return TiebaLinkExtractor.extractLinks(from: resolved)
    }

    static func blocks(from content: Tieba_PbContent) -> [ContentBlock] {
        guard TiebaContentFilter.shouldKeep(content: content) else { return [] }

        switch content.type {
        case 0, 9, 27:
            let emoticonBlocks = TiebaEmoticon.blocks(from: content.text)
            return TiebaLinkExtractor.extractLinks(from: emoticonBlocks)
        case 1:
            return [.link(title: TiebaEmoticon.plainDisplayText(content.text), url: url(firstNonEmpty(content.link)))]
        case 2:
            let code = emoticonCode(from: content) ?? ""
            return code.isEmpty ? [] : [.emoticon(code: code)]
        case 3, 20:
            let size = parseSize(content.bsize, fallbackWidth: content.width, fallbackHeight: content.height)
            let thumbnailURL = url(firstNonEmpty(
                content.cdnSrc,
                content.cdnSrcActive,
                content.bigCdnSrc,
                content.bigSrc,
                content.dynamic,
                content.src,
                content.originSrc
            ))
            let originalURL = url(firstNonEmpty(
                content.originSrc,
                content.bigCdnSrc,
                content.bigSrc,
                content.cdnSrc,
                content.src
            ))
            guard thumbnailURL != nil || originalURL != nil else { return [] }
            return [.image(ImageContent(
                thumbnailURL: thumbnailURL,
                originalURL: originalURL,
                width: size.width,
                height: size.height,
                showOriginalButton: content.showOriginalBtn == 1
            ))]
        case 4:
            return [.mention(userID: content.uid == 0 ? nil : content.uid, text: content.text)]
        case 5:
            let size = parseSize(content.bsize, fallbackWidth: content.width, fallbackHeight: content.height)
            return [.video(VideoContent(
                videoURL: url(firstNonEmpty(content.link)),
                coverURL: url(firstNonEmpty(content.src, content.cdnSrc)),
                webURL: url(firstNonEmpty(content.text)),
                width: size.width,
                height: size.height,
                duration: Int(content.duringTime)
            ))]
        case 10:
            guard let voice = VoiceContent(
                md5: content.voiceMd5,
                durationMilliseconds: Int(content.duringTime)
            ) else {
                return []
            }
            return [.voice(voice)]
        default:
            return TiebaEmoticon.blocks(from: content.text)
        }
    }

    static func videoBlock(from videoInfo: Tieba_VideoInfo) -> ContentBlock? {
        guard videoInfo.videoURL.isEmpty == false || videoInfo.thumbnailURL.isEmpty == false else {
            return nil
        }

        return .video(VideoContent(
            videoURL: url(firstNonEmpty(videoInfo.videoURL)),
            coverURL: url(firstNonEmpty(videoInfo.thumbnailURL)),
            webURL: nil,
            width: Int(videoInfo.videoWidth),
            height: Int(videoInfo.videoHeight),
            duration: Int(videoInfo.videoDuration)
        ))
    }

    static func imageBlock(from media: Tieba_Media) -> ContentBlock? {
        let thumbnailURL = url(firstNonEmpty(
            media.bigPic,
            media.dynamicPic,
            media.srcPic,
            media.originPic
        ))
        let originalURL = url(firstNonEmpty(
            media.originPic,
            media.bigPic,
            media.dynamicPic,
            media.srcPic
        ))
        guard thumbnailURL != nil || originalURL != nil else { return nil }

        return .image(ImageContent(
            thumbnailURL: thumbnailURL,
            originalURL: originalURL,
            width: Int(media.width),
            height: Int(media.height),
            showOriginalButton: media.showOriginalBtn == 1
        ))
    }

    static func appendingUniqueVoices(
        from voices: [Tieba_Voice],
        to blocks: [ContentBlock]
    ) -> [ContentBlock] {
        deduplicatingVoices(
            in: blocks + voices.compactMap { voice in
                guard let content = VoiceContent(
                    md5: voice.voiceMd5,
                    durationMilliseconds: Int(voice.duringTime)
                ) else {
                    return nil
                }
                return .voice(content)
            }
        )
    }

    static func post(from proto: Tieba_Post, usersByID: [Int64: Tieba_User], threadID: Int64) -> Post {
        let author = UserMapper.fromUser(
            proto.hasAuthor ? proto.author : Tieba_User(),
            fallbackID: proto.authorID,
            fallback: usersByID[proto.authorID]
        )

        return Post(
            id: proto.id,
            threadID: threadID == 0 ? proto.tid : threadID,
            floor: Int(proto.floor),
            author: author,
            ipAddress: firstNonEmpty(author.ipAddress, proto.lbsInfo.name),
            createdAt: proto.time == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(proto.time)),
            blocks: blocks(from: proto.content),
            subpostCount: Int(proto.subPostNumber),
            likeCount: likeCount(from: proto),
            isLiked: proto.agree.hasAgree_p != 0,
            previewSubposts: proto.subPostList.subPostList
                .filter(TiebaContentFilter.shouldKeep(subpost:))
                .map { subpost($0, usersByID: usersByID) }
        )
    }

    static func subpost(_ proto: Tieba_SubPostList, usersByID: [Int64: Tieba_User] = [:]) -> Subpost {
        let author = UserMapper.fromUser(
            proto.hasAuthor ? proto.author : Tieba_User(),
            fallbackID: proto.authorID,
            fallback: usersByID[proto.authorID]
        )

        return Subpost(
            id: proto.id,
            floor: Int(proto.floor),
            author: author,
            ipAddress: firstNonEmpty(author.ipAddress, proto.location.name),
            blocks: subpostBlocks(from: proto.content, usersByID: usersByID),
            createdAt: proto.time == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(proto.time)),
            likeCount: Int(proto.agree.agreeNum),
            isLiked: proto.agree.hasAgree_p != 0
        )
    }

    static func subpost(from proto: Tieba_SubPostList) -> Subpost {
        subpost(proto)
    }

    static func threadPage(from response: Tieba_PbPage_PbPageResponse) -> ThreadPage {
        let data = response.data
        var usersByID: [Int64: Tieba_User] = [:]
        for user in data.userList {
            usersByID[user.id] = user
        }

        let forum = ForumMapper.fromProto(data.forum)
        let thread = ThreadMapper.fromThreadInfo(data.thread, usersByID: usersByID)
        let rawMainPost = data.hasFirstFloorPost && data.firstFloorPost.id != 0
            ? data.firstFloorPost
            : data.postList.first {
                $0.floor == 1
                    && $0.id != 0
            }
        let posts = data.postList
            .filter(TiebaContentFilter.shouldKeep(post:))
            .map { post(from: $0, usersByID: usersByID, threadID: data.thread.id) }
            .map { enrichIPIfNeeded($0, thread: thread) }
        let mainPost = rawMainPost.map {
            enrichIPIfNeeded(
                post(from: $0, usersByID: usersByID, threadID: data.thread.id),
                thread: thread
            )
        }

        return ThreadPage(
            thread: thread,
            forum: forum,
            mainPost: mainPost,
            posts: posts,
            currentPage: Int(data.page.currentPage),
            totalPage: Int(data.page.totalPage),
            hasMore: data.page.currentPage < data.page.totalPage || data.page.hasMore_p != 0,
            isCollected: data.thread.collectStatus != 0
        )
    }

    private static func parseSize(
        _ value: String,
        fallbackWidth: UInt32 = 0,
        fallbackHeight: UInt32 = 0
    ) -> (width: Int, height: Int) {
        let parts = value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let width = parts.first ?? Int(fallbackWidth)
        let height = parts.dropFirst().first ?? Int(fallbackHeight)
        return (width, height)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { $0 }.first { $0.isEmpty == false }
    }

    private static func emoticonCode(from content: Tieba_PbContent) -> String? {
        let candidates = [content.c, content.text]
        if let renderable = candidates.first(where: { value in
            value.isEmpty == false && TiebaEmoticon.imageName(for: value) != nil
        }) {
            return renderable
        }
        return firstNonEmpty(content.c, content.text)
    }

    private static func deduplicatingVoices(in blocks: [ContentBlock]) -> [ContentBlock] {
        var seenMD5s = Set<String>()
        return blocks.filter { block in
            guard case let .voice(voice) = block else { return true }
            return seenMD5s.insert(voice.md5).inserted
        }
    }

    private static func enrichIPIfNeeded(_ post: Post, thread: ThreadSummary) -> Post {
        guard firstNonEmpty(post.ipAddress) == nil,
              post.author.id != 0,
              post.author.id == thread.author.id,
              let threadAuthorIP = firstNonEmpty(thread.author.ipAddress) else {
            return post
        }

        var enriched = post
        enriched.ipAddress = threadAuthorIP
        return enriched
    }

    private static func likeCount(from proto: Tieba_Post) -> Int {
        if proto.agree.agreeNum != 0 {
            return Int(proto.agree.agreeNum)
        }
        if proto.postZan.zanNum != 0 {
            return Int(proto.postZan.zanNum)
        }
        return Int(proto.zan.num)
    }

    private static func url(_ value: String?) -> URL? {
        TiebaURL.make(value)
    }
}

private enum ReplyTargetResolver {
    static func resolve(
        in blocks: [ContentBlock],
        usersByID: [Int64: Tieba_User]
    ) -> [ContentBlock] {
        mergeAdjacentText(in: blocks).enumerated().flatMap { index, block in
            switch block {
            case let .mention(userID, text):
                guard userID == nil,
                      let resolvedID = uniqueUserID(
                        matching: text,
                        usersByID: usersByID
                      ) else {
                    return [block]
                }
                return [.mention(userID: resolvedID, text: text)]
            case let .text(text) where index == 0:
                return flattenedReplyTarget(
                    in: text,
                    usersByID: usersByID
                ) ?? [block]
            default:
                return [block]
            }
        }
    }

    /// Some PBPage preview responses flatten `回复 用户名：正文` into a
    /// type-0 text block, while PBFloor returns a structured type-4 mention.
    /// The prefix shape alone is not proof of a reply quote — users type it
    /// too — so only the leading text block of a subpost is considered.
    /// A missing or ambiguous UID stays `nil`; the name remains a native link
    /// that can be resolved on demand instead of being rendered as plain text.
    private static func flattenedReplyTarget(
        in text: String,
        usersByID: [Int64: Tieba_User]
    ) -> [ContentBlock]? {
        guard text.hasPrefix("回复") else { return nil }
        let replyEnd = text.index(text.startIndex, offsetBy: 2)
        guard replyEnd < text.endIndex else { return nil }

        guard let delimiter = text[replyEnd...].firstIndex(where: {
            $0 == ":" || $0 == "："
        }) else {
            return nil
        }

        var targetStart = replyEnd
        while targetStart < delimiter, text[targetStart].isWhitespace {
            targetStart = text.index(after: targetStart)
        }
        var targetEnd = delimiter
        while targetEnd > targetStart {
            let previous = text.index(before: targetEnd)
            guard text[previous].isWhitespace else { break }
            targetEnd = previous
        }
        guard targetStart < targetEnd else { return nil }

        let displayedName = String(text[targetStart..<targetEnd])
        guard TiebaUserName.normalized(displayedName).isEmpty == false else { return nil }
        let userID = uniqueUserID(matching: displayedName, usersByID: usersByID)

        var result: [ContentBlock] = []
        let prefix = String(text[..<targetStart])
        if prefix.isEmpty == false {
            result.append(.text(prefix))
        }
        result.append(.mention(userID: userID, text: displayedName))
        let suffix = String(text[targetEnd...])
        if suffix.isEmpty == false {
            result.append(.text(suffix))
        }
        return result
    }

    private static func mergeAdjacentText(in blocks: [ContentBlock]) -> [ContentBlock] {
        blocks.reduce(into: []) { result, block in
            guard case let .text(text) = block else {
                result.append(block)
                return
            }
            guard case let .text(previous)? = result.last else {
                result.append(block)
                return
            }
            result[result.count - 1] = .text(previous + text)
        }
    }

    private static func uniqueUserID(
        matching displayText: String,
        usersByID: [Int64: Tieba_User]
    ) -> Int64? {
        let target = TiebaUserName.normalized(displayText)
        guard target.isEmpty == false else { return nil }

        let matches = Set(usersByID.values.compactMap { user -> Int64? in
            guard user.id > 0 else { return nil }
            let names = [user.nameShow, user.name]
                .map(TiebaUserName.normalized)
                .filter { $0.isEmpty == false }
            return names.contains(target) ? user.id : nil
        })
        guard matches.count == 1 else { return nil }
        return matches.first
    }
}
