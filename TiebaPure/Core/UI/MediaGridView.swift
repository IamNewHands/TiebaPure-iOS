import SwiftUI

struct ReaderMediaItem: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case image
        case video
    }

    var id: String
    var kind: Kind
    var thumbnailURL: URL?
    var image: ImageContent?
    var video: VideoContent?
    var aspectRatio: CGFloat
    var accessibilityLabel: String

    init(
        id: String,
        kind: Kind,
        thumbnailURL: URL?,
        image: ImageContent? = nil,
        video: VideoContent? = nil,
        aspectRatio: CGFloat = 1,
        accessibilityLabel: String
    ) {
        self.id = id
        self.kind = kind
        self.thumbnailURL = thumbnailURL
        self.image = image
        self.video = video
        self.aspectRatio = max(0.5, min(aspectRatio, 2.0))
        self.accessibilityLabel = accessibilityLabel
    }

    var previewSourceIdentity: String {
        [
            id,
            kind == .image ? "image" : "video",
            thumbnailURL?.absoluteString ?? "",
            image?.originalURL?.absoluteString ?? ""
        ].joined(separator: "|")
    }
}

struct MediaGridView: View {
    let items: [ReaderMediaItem]
    let maxItemHeight: CGFloat?
    let totalItemCount: Int
    let usesCompactFeedLayout: Bool
    let isInteractive: Bool
    let destinationAccessibilityLabel: String?
    let destinationAccessibilityHint: String?
    /// List surfaces show a post's 动图 as a still CDN preview unless this is
    /// on, in which case a thumbnail whose original is animated is replaced by
    /// the animation once the CDN confirms it.
    let prefersAnimatedOriginal: Bool
    let onTap: (ReaderMediaItem, CGRect?, UIImage?, ImagePreviewSourceAnchor?) -> Void

    init(
        items: [ReaderMediaItem],
        maxItemHeight: CGFloat? = nil,
        totalItemCount: Int? = nil,
        usesCompactFeedLayout: Bool = false,
        isInteractive: Bool = true,
        destinationAccessibilityLabel: String? = nil,
        destinationAccessibilityHint: String? = nil,
        prefersAnimatedOriginal: Bool = false,
        onTap: @escaping (ReaderMediaItem, CGRect?, UIImage?, ImagePreviewSourceAnchor?) -> Void = { _, _, _, _ in }
    ) {
        self.items = items
        self.maxItemHeight = maxItemHeight
        self.totalItemCount = max(totalItemCount ?? items.count, items.count)
        self.usesCompactFeedLayout = usesCompactFeedLayout
        self.isInteractive = isInteractive
        self.destinationAccessibilityLabel = destinationAccessibilityLabel
        self.destinationAccessibilityHint = destinationAccessibilityHint
        self.prefersAnimatedOriginal = prefersAnimatedOriginal
        self.onTap = onTap
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if usesCompactFeedLayout {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .aspectRatio(
                        ForumFeedMediaLayoutPolicy.containerAspectRatio(totalCount: totalItemCount),
                        contentMode: .fit
                    )
                    .overlay {
                        HStack(spacing: TiebaPureTheme.Spacing.xs) {
                            ForEach(items) { item in
                                mediaButton(item)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
            } else {
                standardGrid
            }

            if ForumFeedMediaLayoutPolicy.showsMoreBadge(
                totalCount: totalItemCount,
                visibleCount: items.count
            ) {
                Label("\(totalItemCount)", systemImage: "photo.on.rectangle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(TiebaPureTheme.Spacing.xs)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var standardGrid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: TiebaPureTheme.Spacing.xs),
            count: columnCount
        )
        return LazyVGrid(columns: columns, alignment: .leading, spacing: TiebaPureTheme.Spacing.xs) {
            ForEach(items) { item in
                mediaButton(item)
            }
        }
    }

    private func mediaButton(_ item: ReaderMediaItem) -> some View {
        Group {
            if isInteractive {
                MediaItemButton(
                    item: item,
                    maxHeight: usesCompactFeedLayout ? nil : maxItemHeight,
                    aspectRatioOverride: usesCompactFeedLayout ? nil : thumbnailAspectRatio,
                    fillsAvailableSpace: usesCompactFeedLayout,
                    totalItemCount: totalItemCount,
                    destinationAccessibilityLabel: destinationAccessibilityLabel,
                    destinationAccessibilityHint: destinationAccessibilityHint,
                    prefersAnimatedOriginal: prefersAnimatedOriginal,
                    onTap: onTap
                )
            } else {
                MediaThumbnailView(
                    item: item,
                    maxHeight: usesCompactFeedLayout ? nil : maxItemHeight,
                    aspectRatioOverride: usesCompactFeedLayout ? nil : thumbnailAspectRatio,
                    fillsAvailableSpace: usesCompactFeedLayout,
                    retryTrigger: 0,
                    isManualLoadAuthorized: false,
                    explicitOriginalAuthorization: nil,
                    showsManualLoadIndicator: false,
                    prefersAnimatedOriginal: prefersAnimatedOriginal,
                    onLoadStateChange: { _ in }
                )
                .accessibilityHidden(true)
            }
        }
    }

    private var columnCount: Int {
        if usesCompactFeedLayout {
            return max(1, items.count)
        }
        switch items.count {
        case 0, 1:
            return 1
        case 2, 4:
            return 2
        default:
            return 3
        }
    }

    private var thumbnailAspectRatio: CGFloat? {
        guard usesCompactFeedLayout else { return nil }
        return ForumFeedMediaLayoutPolicy.thumbnailAspectRatio(
            totalCount: totalItemCount,
            visibleCount: items.count
        )
    }
}

private struct MediaItemButton: View {
    @Environment(\.readingPreferences) private var readingPreferences

    let item: ReaderMediaItem
    let maxHeight: CGFloat?
    let aspectRatioOverride: CGFloat?
    let fillsAvailableSpace: Bool
    let totalItemCount: Int
    let destinationAccessibilityLabel: String?
    let destinationAccessibilityHint: String?
    let prefersAnimatedOriginal: Bool
    let onTap: (ReaderMediaItem, CGRect?, UIImage?, ImagePreviewSourceAnchor?) -> Void

    @State private var loadState: TiebaRemoteImageLoadState = .empty
    @State private var retryTrigger = 0
    @State private var manualLoadAuthorization: String?
    @State private var explicitFallbackAuthorization: String?
    @StateObject private var previewSource: ImagePreviewSourceAnchor

    init(
        item: ReaderMediaItem,
        maxHeight: CGFloat?,
        aspectRatioOverride: CGFloat?,
        fillsAvailableSpace: Bool,
        totalItemCount: Int,
        destinationAccessibilityLabel: String?,
        destinationAccessibilityHint: String?,
        prefersAnimatedOriginal: Bool = false,
        onTap: @escaping (ReaderMediaItem, CGRect?, UIImage?, ImagePreviewSourceAnchor?) -> Void
    ) {
        self.item = item
        self.maxHeight = maxHeight
        self.aspectRatioOverride = aspectRatioOverride
        self.fillsAvailableSpace = fillsAvailableSpace
        self.totalItemCount = totalItemCount
        self.destinationAccessibilityLabel = destinationAccessibilityLabel
        self.destinationAccessibilityHint = destinationAccessibilityHint
        self.prefersAnimatedOriginal = prefersAnimatedOriginal
        self.onTap = onTap
        _previewSource = StateObject(
            wrappedValue: ImagePreviewSourceAnchor(
                sourceIdentity: item.previewSourceIdentity
            )
        )
    }

    var body: some View {
        Button(action: activate) {
            MediaThumbnailView(
                item: item,
                maxHeight: maxHeight,
                aspectRatioOverride: aspectRatioOverride,
                fillsAvailableSpace: fillsAvailableSpace,
                retryTrigger: retryTrigger,
                isManualLoadAuthorized: isManualLoadAuthorized,
                explicitOriginalAuthorization: explicitFallbackAuthorization,
                showsManualLoadIndicator: true,
                prefersAnimatedOriginal: prefersAnimatedOriginal,
                previewSource: previewSource,
                onTransitionTap: activate,
                onLoadStateChange: { state in
                    guard loadState != state else { return }
                    loadState = state
                },
                onImageResolved: {
                    previewSource.store(
                        image: $0,
                        sourceIdentity: item.previewSourceIdentity
                    )
                }
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(
            cornerRadius: TiebaPureTheme.Radius.media,
            style: .continuous
        ))
        .minTouchTarget()
        .accessibilityIdentifier("media-item-\(item.id)")
        .accessibilityLabel(mediaAccessibilityLabel)
        .accessibilityHint(mediaAccessibilityHint)
    }

    private func activate() {
        if loadState == .failure {
            if item.kind == .video {
                openDestination()
                return
            }
            if shouldOfferExplicitFallback {
                explicitFallbackAuthorization = item.previewSourceIdentity
            }
            retryTrigger += 1
        } else if item.thumbnailURL != nil,
                  loadState == .empty,
                  mediaRequestPolicy.loadsAutomatically == false {
            if isManualLoadAuthorized == false {
                manualLoadAuthorization = item.previewSourceIdentity
            }
            return
        } else if loadState == .loading,
                  ReaderMediaActivationPolicy.blocksWhileLoading(
                    requestPolicy: mediaRequestPolicy
                  ) {
            return
        } else {
            openDestination()
        }
    }

    private func openDestination() {
        onTap(
            item,
            ImagePreviewSourceRegistry.shared
                .frameInWindow(for: item.previewSourceIdentity)
                ?? previewSource.frameInWindow,
            previewSource.image,
            previewSource
        )
    }

    private var mediaAccessibilityLabel: String {
        let base: String
        if loadState == .failure {
            if item.kind == .video {
                base = "\(destinationAccessibilityLabel ?? item.accessibilityLabel)，封面加载失败"
            } else {
                base = shouldOfferExplicitFallback
                ? "\(item.accessibilityLabel)预览加载失败，加载原图"
                : "\(item.accessibilityLabel)加载失败，重新加载"
            }
        } else if item.thumbnailURL != nil,
                  loadState == .empty,
                  mediaRequestPolicy.loadsAutomatically == false,
                  isManualLoadAuthorized == false {
            base = "加载\(item.accessibilityLabel)"
        } else if loadState == .loading,
                  ReaderMediaActivationPolicy.blocksWhileLoading(
                    requestPolicy: mediaRequestPolicy
                  ) {
            base = "正在加载\(item.accessibilityLabel)"
        } else {
            base = destinationAccessibilityLabel ?? item.accessibilityLabel
        }
        return "\(base)，共\(totalItemCount)项媒体"
    }

    private var mediaAccessibilityHint: String {
        if loadState == .failure {
            if item.kind == .video {
                return destinationAccessibilityHint ?? "打开媒体，封面加载失败不影响内容"
            }
            return shouldOfferExplicitFallback
                ? "明确请求当前媒体原图"
                : "重新请求当前媒体缩略图"
        }
        if item.thumbnailURL != nil,
           loadState == .empty,
           mediaRequestPolicy.loadsAutomatically == false,
           isManualLoadAuthorized == false {
            return "加载当前媒体缩略图"
        }
        if loadState == .loading,
           ReaderMediaActivationPolicy.blocksWhileLoading(
            requestPolicy: mediaRequestPolicy
           ) {
            return "请等待媒体缩略图加载完成"
        }
        return destinationAccessibilityHint ?? "打开媒体"
    }

    private var mediaRequestPolicy: ReaderMediaRequestPolicy {
        ReaderMediaRequestPolicy.resolve(readingPreferences.mediaLoading)
    }

    private var isManualLoadAuthorized: Bool {
        mediaRequestPolicy.allowsLoading(
            sourceIdentity: item.previewSourceIdentity,
            manualAuthorization: manualLoadAuthorization
        )
    }

    private var hasExplicitOriginalAuthorization: Bool {
        mediaRequestPolicy.allowsFallback(
            sourceIdentity: item.previewSourceIdentity,
            explicitAuthorization: explicitFallbackAuthorization
        )
    }

    private var shouldOfferExplicitFallback: Bool {
        guard readingPreferences.mediaLoading == .dataSaving,
              hasExplicitOriginalAuthorization == false,
              let originalURL = item.image?.originalURL else {
            return false
        }
        return originalURL != item.thumbnailURL
    }
}

private struct MediaThumbnailView: View {
    @Environment(\.readingPreferences) private var readingPreferences
    @Environment(\.displayScale) private var displayScale

    let item: ReaderMediaItem
    let maxHeight: CGFloat?
    let aspectRatioOverride: CGFloat?
    let fillsAvailableSpace: Bool
    let retryTrigger: Int
    let isManualLoadAuthorized: Bool
    let explicitOriginalAuthorization: String?
    let showsManualLoadIndicator: Bool
    var prefersAnimatedOriginal: Bool = false
    var previewSource: ImagePreviewSourceAnchor? = nil
    var onTransitionTap: (() -> Void)? = nil
    let onLoadStateChange: (TiebaRemoteImageLoadState) -> Void
    var onImageResolved: ((UIImage) -> Void)? = nil
    var onDebugImageObserverResolved: ((UIView, UIImage) -> Void)? = nil
    @State private var internalLoadState: TiebaRemoteImageLoadState = .empty

    var body: some View {
        Group {
            if fillsAvailableSpace {
                GeometryReader { proxy in
                    thumbnailContent
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            } else {
                thumbnailContent
                    .aspectRatio(aspectRatioOverride ?? item.aspectRatio, contentMode: .fit)
                    .frame(maxHeight: maxHeight)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: TiebaPureTheme.Radius.media, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: TiebaPureTheme.Radius.media, style: .continuous))
    }

    private var thumbnailContent: some View {
        ZStack {
            Rectangle()
                .fill(TiebaPureTheme.ColorToken.readerTertiarySurface)

            if item.thumbnailURL != nil {
                GeometryReader { proxy in
                    TiebaRemoteImage(
                        primaryURL: requestSources.primaryURL,
                        fallbackURL: requestSources.fallbackURL,
                        targetPixelSize: TiebaImageDecodePolicy.previewTargetPixelSize(
                            for: proxy.size,
                            displayScale: displayScale
                        ),
                        contentMode: .fill,
                        retryTrigger: retryTrigger,
                        showsRetryButton: false,
                        showsResolvedImage: previewSource == nil,
                        loadsAutomatically: isManualLoadAuthorized,
                        prefersAnimatedOriginal: prefersAnimatedOriginal,
                        onLoadStateChange: { state in
                            if internalLoadState != state {
                                internalLoadState = state
                            }
                            onLoadStateChange(state)
                            if state == .failure {
                                previewSource?.clearImage(
                                    sourceIdentity: item.previewSourceIdentity
                                )
                            }
                        },
                        onImageResolved: onImageResolved,
                        onDebugImageObserverResolved: onDebugImageObserverResolved
                    )
                }

                if let previewSource {
                    ImagePreviewSourceAnchorReader(
                        anchor: previewSource,
                        sourceIdentity: item.previewSourceIdentity,
                        onTransitionTap: onTransitionTap
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }

                if showsManualLoadIndicator,
                   requestPolicy.loadsAutomatically == false,
                   isManualLoadAuthorized == false,
                   internalLoadState == .empty {
                    manualLoadIndicator
                }
            } else {
                placeholder
            }

            if item.kind == .video, waitsForManualLoad == false {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: TiebaPureTheme.IconSize.play))
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
                .accessibilityHidden(true)
            }
        }
    }

    private var placeholder: some View {
        Image(systemName: item.kind == .video ? "play.rectangle.fill" : "photo")
            .font(.system(size: 28))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private var manualLoadIndicator: some View {
        Image(systemName: "arrow.down.circle")
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: Circle())
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var requestPolicy: ReaderMediaRequestPolicy {
        ReaderMediaRequestPolicy.resolve(readingPreferences.mediaLoading)
    }

    private var requestSources: ReaderImageRequestSources {
        ReaderImageRequestSourcePolicy.resolve(
            previewURL: item.thumbnailURL,
            originalURL: item.image?.originalURL,
            requestPolicy: requestPolicy,
            sourceIdentity: item.previewSourceIdentity,
            explicitOriginalAuthorization: explicitOriginalAuthorization
        )
    }

    private var waitsForManualLoad: Bool {
        item.thumbnailURL != nil
            && requestPolicy.loadsAutomatically == false
            && isManualLoadAuthorized == false
            && internalLoadState == .empty
    }
}

enum ForumFeedMediaLayoutPolicy {
    static func visibleItemCount(totalCount: Int) -> Int {
        min(max(totalCount, 0), 3)
    }

    static func containerAspectRatio(totalCount: Int) -> CGFloat {
        totalCount <= 1 ? 2 : 3
    }

    static func containerHeight(containerWidth: CGFloat, totalCount: Int) -> CGFloat {
        containerWidth / containerAspectRatio(totalCount: totalCount)
    }

    static func thumbnailAspectRatio(totalCount: Int, visibleCount: Int) -> CGFloat {
        let visibleCount = max(visibleCount, 1)
        return containerAspectRatio(totalCount: totalCount) / CGFloat(visibleCount)
    }

    static func showsMoreBadge(totalCount: Int, visibleCount: Int) -> Bool {
        totalCount > visibleCount
    }
}
