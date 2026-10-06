import Foundation
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import TiebaPure

protocol StateRegressionScratchDefaultsProviding: AnyObject {}

extension StateRegressionScratchDefaultsProviding where Self: XCTestCase {
    func makeScratchDefaults(function: String = #function) throws -> UserDefaults {
        let suiteName = "\(function).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}

final class CrossVersionStateRegressionTests: XCTestCase,
    StateRegressionScratchDefaultsProviding {
    private enum ExpectedPersistenceError: Error {
        case writeFailed
    }

    @MainActor
    func testLegacyMigrationKeepsDefaultsWhenPersistenceFailsOrIsNotDurable() throws {
        let defaults = try makeScratchDefaults()
        let key = "legacy"
        let legacyData = Data("legacy-value".utf8)

        defaults.set(legacyData, forKey: key)
        XCTAssertThrowsError(
            try LegacyStorageMigration.persistThenRemoveLegacyValue(
                defaults: defaults,
                key: key,
                destinationIsDurable: true
            ) {
                throw ExpectedPersistenceError.writeFailed
            }
        )
        XCTAssertEqual(defaults.data(forKey: key), legacyData)

        var didPersistIntoFallback = false
        try LegacyStorageMigration.persistThenRemoveLegacyValue(
            defaults: defaults,
            key: key,
            destinationIsDurable: false
        ) {
            didPersistIntoFallback = true
        }
        XCTAssertTrue(didPersistIntoFallback)
        XCTAssertEqual(defaults.data(forKey: key), legacyData)

        try LegacyStorageMigration.persistThenRemoveLegacyValue(
            defaults: defaults,
            key: key,
            destinationIsDurable: true
        ) {}
        XCTAssertNil(defaults.object(forKey: key))
    }

    @MainActor
    func testAppAppearancePersistsOverridesAndSanitizesInvalidValues() throws {
        let suiteName = "AppAppearanceStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let key = "appearance"

        let store = AppAppearanceStore(defaults: defaults, key: key)
        XCTAssertEqual(store.selection, .system)
        XCTAssertNil(store.selection.preferredColorScheme)
        XCTAssertNil(defaults.object(forKey: key))

        store.select(.dark)
        XCTAssertEqual(store.selection, .dark)
        XCTAssertEqual(store.selection.preferredColorScheme, .dark)
        XCTAssertEqual(defaults.string(forKey: key), AppAppearance.dark.rawValue)

        let reloaded = AppAppearanceStore(defaults: defaults, key: key)
        XCTAssertEqual(reloaded.selection, .dark)

        reloaded.select(.light)
        XCTAssertEqual(reloaded.selection, .light)
        XCTAssertEqual(reloaded.selection.preferredColorScheme, .light)
        XCTAssertEqual(defaults.string(forKey: key), AppAppearance.light.rawValue)

        reloaded.select(.system)
        XCTAssertEqual(reloaded.selection, .system)
        XCTAssertNil(reloaded.selection.preferredColorScheme)
        XCTAssertNil(defaults.object(forKey: key))

        defaults.set("invalid-appearance", forKey: key)
        let sanitized = AppAppearanceStore(defaults: defaults, key: key)
        XCTAssertEqual(sanitized.selection, .system)
        XCTAssertNil(defaults.object(forKey: key))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testForumThreadSortPreferencePersistsPerForumAndRepairsInvalidValues() throws {
        let defaults = try makeScratchDefaults()
        let key = "forum-thread-sort"
        let firstForum = Forum(
            id: 101,
            name: "测试",
            displayName: "测试吧",
            avatarURL: nil,
            memberCount: 0,
            threadCount: 0
        )
        let secondForum = Forum(
            id: 102,
            name: "无障碍",
            displayName: "无障碍吧",
            avatarURL: nil,
            memberCount: 0,
            threadCount: 0
        )
        let nameOnlyForum = Forum(
            id: 0,
            name: "  测试吧 ",
            displayName: "测试吧",
            avatarURL: nil,
            memberCount: 0,
            threadCount: 0
        )
        let normalizedNameOnlyForum = Forum(
            id: 0,
            name: "测试",
            displayName: "测试吧",
            avatarURL: nil,
            memberCount: 0,
            threadCount: 0
        )

        let store = ForumThreadSortPreferenceStore(defaults: defaults, key: key)
        XCTAssertEqual(store.selection(for: firstForum), .replyTime)
        XCTAssertEqual(store.selection(for: secondForum), .replyTime)

        store.select(.publishTime, for: firstForum)
        XCTAssertEqual(store.selection(for: firstForum), .publishTime)
        XCTAssertEqual(store.selection(for: secondForum), .replyTime)
        XCTAssertEqual(
            store.selection(for: nameOnlyForum),
            .publishTime,
            "应用内和 Universal Link 进入同一贴吧时应共享排序偏好"
        )
        XCTAssertEqual(store.selection(for: normalizedNameOnlyForum), .publishTime)
        XCTAssertEqual(
            ForumThreadSortPreferenceStore(defaults: defaults, key: key)
                .selection(for: firstForum),
            .publishTime
        )

        store.select(.featured, for: firstForum)
        XCTAssertEqual(
            store.selection(for: firstForum),
            .publishTime,
            "精华是页签而非最新排序偏好，不应覆盖此前选择"
        )

        store.select(.publishTime, for: nameOnlyForum)
        XCTAssertEqual(store.selection(for: normalizedNameOnlyForum), .publishTime)

        let firstKey = ForumThreadSortPreferenceStore.preferenceKey(for: firstForum)
        let secondKey = ForumThreadSortPreferenceStore.preferenceKey(for: secondForum)
        defaults.set(
            [
                firstKey: ForumThreadCategory.featured.rawValue,
                secondKey: ForumThreadCategory.publishTime.rawValue
            ],
            forKey: key
        )
        XCTAssertEqual(store.selection(for: firstForum), .replyTime)
        XCTAssertEqual(store.selection(for: secondForum), .publishTime)
        XCTAssertNil(defaults.dictionary(forKey: key)?[firstKey])
        XCTAssertEqual(
            defaults.dictionary(forKey: key)?[secondKey] as? String,
            ForumThreadCategory.publishTime.rawValue
        )

        defaults.set("corrupt", forKey: key)
        XCTAssertEqual(store.selection(for: firstForum), .replyTime)
        XCTAssertNil(defaults.object(forKey: key))

        store.select(.publishTime, for: firstForum)
        store.select(.replyTime, for: firstForum)
        XCTAssertEqual(store.selection(for: firstForum), .replyTime)
        XCTAssertNil(defaults.object(forKey: key))

        store.select(.publishTime, for: secondForum)
        store.reset()
        XCTAssertEqual(store.selection(for: secondForum), .replyTime)
    }

    func testSearchRoutePreservesMatchedPostID() {
        let route = SearchThreadRoute(threadID: 10, forumID: 20, postID: 30)
        XCTAssertEqual(route.postID, 30)
    }

    func testSearchRequestKeyIncludesEveryResultCondition() {
        let base = SearchRequestKey(
            accountID: "A",
            keyword: "词",
            forumName: "吧",
            filterType: 2,
            sortType: 5,
            page: 1
        )
        XCTAssertNotEqual(base, SearchRequestKey(accountID: "B", keyword: "词", forumName: "吧", filterType: 2, sortType: 5, page: 1))
        XCTAssertNotEqual(base, SearchRequestKey(accountID: "A", keyword: "新词", forumName: "吧", filterType: 2, sortType: 5, page: 1))
        XCTAssertNotEqual(base, SearchRequestKey(accountID: "A", keyword: "词", forumName: "吧", filterType: 1, sortType: 5, page: 1))
        XCTAssertNotEqual(base, SearchRequestKey(accountID: "A", keyword: "词", forumName: "吧", filterType: 2, sortType: 0, page: 1))
        XCTAssertNotEqual(base, SearchRequestKey(accountID: "A", keyword: "词", forumName: "吧", filterType: 2, sortType: 5, page: 2))
    }

    func testThreadReadingVisibilityPolicyRecordsBottomMostVisibleReply() {
        let mainPostID: UInt64 = 2001
        let postIDs: [UInt64] = [2001, 2002, 2003, 2004]
        let visiblePostIDs: Set<UInt64> = [2001, 2002, 2003]

        XCTAssertEqual(
            ThreadReadingVisibilityPolicy.bottomMostVisiblePostID(
                postIDsInDisplayOrder: postIDs,
                visiblePostIDs: visiblePostIDs,
                excludedPostID: mainPostID
            ),
            2003
        )
        XCTAssertEqual(
            ThreadReadingVisibilityPolicy.bottomMostVisiblePostID(
                postIDsInDisplayOrder: [2001, 2004, 2003, 2002],
                visiblePostIDs: visiblePostIDs,
                excludedPostID: mainPostID
            ),
            2002,
            "倒序或热门列表必须按当前显示顺序选择最下方可见回复"
        )
        XCTAssertNil(ThreadReadingVisibilityPolicy.bottomMostVisiblePostID(
            postIDsInDisplayOrder: [mainPostID],
            visiblePostIDs: [mainPostID],
            excludedPostID: mainPostID
        ))
        XCTAssertNil(ThreadReadingVisibilityPolicy.bottomMostVisiblePostID(
            postIDsInDisplayOrder: postIDs,
            visiblePostIDs: [],
            excludedPostID: mainPostID
        ))
    }

    func testThreadReadingScrollRegionUsesStableBoundaries() {
        XCTAssertEqual(ThreadReadingScrollRegion.resolve(distanceFromTop: -1), .top)
        XCTAssertEqual(ThreadReadingScrollRegion.resolve(distanceFromTop: 0), .top)
        XCTAssertEqual(
            ThreadReadingScrollRegion.resolve(
                distanceFromTop: ShortPullRefreshPolicy.topTolerance
            ),
            .top
        )
        XCTAssertEqual(
            ThreadReadingScrollRegion.resolve(
                distanceFromTop: ShortPullRefreshPolicy.topTolerance + 0.5
            ),
            .nearTop
        )
        XCTAssertEqual(
            ThreadReadingScrollRegion.resolve(
                distanceFromTop: ThreadReadingViewportPolicy.minimumRecordingDistance - 0.5
            ),
            .nearTop
        )
        XCTAssertEqual(
            ThreadReadingScrollRegion.resolve(
                distanceFromTop: ThreadReadingViewportPolicy.minimumRecordingDistance
            ),
            .away
        )
    }

    func testThreadReadingPersistenceWaitsForIdleAndSelectsOneAction() {
        XCTAssertEqual(
            ThreadReadingPersistencePolicy.intent(
                scrollRegion: .away,
                didMoveAwayFromTop: true
            ),
            .record
        )
        XCTAssertEqual(
            ThreadReadingPersistencePolicy.intent(
                scrollRegion: .top,
                didMoveAwayFromTop: true
            ),
            .clear
        )
        XCTAssertEqual(
            ThreadReadingPersistencePolicy.intent(
                scrollRegion: .nearTop,
                didMoveAwayFromTop: true
            ),
            .none
        )
        XCTAssertEqual(
            ThreadReadingPersistencePolicy.intent(
                scrollRegion: .away,
                didMoveAwayFromTop: false
            ),
            .none
        )
    }

    func testThreadReadingTrackingCancelsPendingCommitWithoutDiscardingViewport() {
        let state = ThreadReadingTrackingState()
        state.visiblePostIDs = [2002, 2003]
        state.scrollRegion = .away
        state.lastRecordedPostID = 2002
        state.didMoveAwayFromTop = true
        state.pendingCommitTask = Task {}

        state.cancelPendingCommit()

        XCTAssertEqual(state.visiblePostIDs, [2002, 2003])
        XCTAssertEqual(state.scrollRegion, .away)
        XCTAssertNil(state.pendingCommitTask)
        XCTAssertEqual(state.lastRecordedPostID, 2002)
        XCTAssertTrue(state.didMoveAwayFromTop)
    }

    func testThreadReadingTrackingUsesViewportVisibilityWithoutDuplicates() {
        let state = ThreadReadingTrackingState()

        XCTAssertTrue(state.postBecameVisible(2002))
        XCTAssertTrue(state.postBecameVisible(2003))
        XCTAssertFalse(state.postBecameVisible(2002))
        XCTAssertFalse(state.postBecameVisible(0))
        XCTAssertEqual(state.visiblePostIDs, [2002, 2003])

        XCTAssertTrue(state.postBecameHidden(2002))
        XCTAssertFalse(state.postBecameHidden(2002))
        XCTAssertEqual(state.visiblePostIDs, [2003])
    }

    func testThreadReadingTrackingKeepsDeferredPageLoadUntilItCanStart() {
        let state = ThreadReadingTrackingState()
        XCTAssertFalse(state.consumePendingAutomaticPageLoad(canLoad: true))

        state.pendingAutomaticPageLoad = true
        XCTAssertFalse(state.consumePendingAutomaticPageLoad(canLoad: false))
        XCTAssertTrue(state.pendingAutomaticPageLoad)
        XCTAssertTrue(state.consumePendingAutomaticPageLoad(canLoad: true))
        XCTAssertFalse(state.consumePendingAutomaticPageLoad(canLoad: true))
    }

    func testThreadReadingTrackingResetClearsViewportAndRegion() {
        let state = ThreadReadingTrackingState()
        state.visiblePostIDs = [2002, 2003]
        state.isScrollIdle = false
        state.scrollRegion = .away
        state.lastRecordedPostID = 2003
        state.didMoveAwayFromTop = true
        state.pendingCommitTask = Task {}
        state.pendingAutomaticPageLoad = true

        state.reset()

        XCTAssertEqual(state.visiblePostIDs, [])
        XCTAssertTrue(state.isScrollIdle)
        XCTAssertEqual(state.scrollRegion, .top)
        XCTAssertNil(state.lastRecordedPostID)
        XCTAssertFalse(state.didMoveAwayFromTop)
        XCTAssertNil(state.pendingCommitTask)
        XCTAssertFalse(state.pendingAutomaticPageLoad)
    }

    func testPreciseScrollSessionsDistinguishRepeatedRestoreToSamePost() {
        let first = ThreadPreciseScrollSession(postID: 2002)
        let second = ThreadPreciseScrollSession(postID: 2002)

        XCTAssertEqual(first.postID, second.postID)
        XCTAssertNotEqual(first, second)
    }

    func testFixtureSearchCarriesPostIDAndCancellationPropagates() async throws {
        let api = FixtureTiebaAPI(scenario: .success)
        let page = try await api.searchThreads(
            keyword: "确定性",
            page: 1,
            sortType: 5,
            filterType: 2,
            forumName: nil,
            pageSize: 30
        )
        XCTAssertEqual(page.results.first?.postID, 2002)

        let slow = FixtureTiebaAPI(scenario: .slow)
        let task = Task {
            try await slow.searchThreads(
                keyword: "慢请求",
                page: 1,
                sortType: 5,
                filterType: 2,
                forumName: nil,
                pageSize: 30
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }

    @MainActor
    func testReadingPreferencesPersistIndependentlyAndRemoveDefaultValues() throws {
        let defaults = try makeScratchDefaults()
        let keys = ReadingPreferencesStore.StorageKeys(
            fontSize: "reader-font",
            fontFamily: "reader-family",
            lineSpacing: "reader-spacing",
            defaultReplySort: "reader-sort",
            mediaLoading: "reader-media"
        )
        let store = ReadingPreferencesStore(defaults: defaults, keys: keys)

        XCTAssertEqual(store.preferences, .default)
        XCTAssertNil(defaults.object(forKey: keys.fontSize))
        XCTAssertNil(defaults.object(forKey: keys.fontFamily))
        XCTAssertNil(defaults.object(forKey: keys.lineSpacing))
        XCTAssertNil(defaults.object(forKey: keys.defaultReplySort))
        XCTAssertNil(defaults.object(forKey: keys.mediaLoading))

        store.select(fontSize: .large)
        store.select(fontFamily: .serif)
        XCTAssertEqual(defaults.string(forKey: keys.fontSize), ReaderFontSize.large.rawValue)
        XCTAssertEqual(defaults.string(forKey: keys.fontFamily), ReaderFontFamily.serif.rawValue)
        XCTAssertNil(defaults.object(forKey: keys.lineSpacing))
        XCTAssertNil(defaults.object(forKey: keys.defaultReplySort))
        XCTAssertNil(defaults.object(forKey: keys.mediaLoading))

        store.select(lineSpacing: .relaxed)
        store.select(defaultReplySort: .descending)
        store.select(mediaLoading: .manual)
        XCTAssertEqual(
            ReadingPreferencesStore(defaults: defaults, keys: keys).preferences,
            ReadingPreferences(
                fontSize: .large,
                fontFamily: .serif,
                lineSpacing: .relaxed,
                defaultReplySort: .descending,
                mediaLoading: .manual
            )
        )

        store.select(fontSize: .standard)
        XCTAssertNil(defaults.object(forKey: keys.fontSize))
        XCTAssertEqual(defaults.string(forKey: keys.fontFamily), ReaderFontFamily.serif.rawValue)
        XCTAssertEqual(defaults.string(forKey: keys.lineSpacing), ReaderLineSpacing.relaxed.rawValue)
        XCTAssertEqual(defaults.integer(forKey: keys.defaultReplySort), ThreadReplySort.descending.rawValue)
        XCTAssertEqual(defaults.string(forKey: keys.mediaLoading), ReaderMediaLoadingPolicy.manual.rawValue)

        store.update(.default)
        XCTAssertEqual(store.preferences, .default)
        XCTAssertNil(defaults.object(forKey: keys.fontSize))
        XCTAssertNil(defaults.object(forKey: keys.fontFamily))
        XCTAssertNil(defaults.object(forKey: keys.lineSpacing))
        XCTAssertNil(defaults.object(forKey: keys.defaultReplySort))
        XCTAssertNil(defaults.object(forKey: keys.mediaLoading))
    }

    @MainActor
    func testReadingPreferencesSanitizeOnlyInvalidStoredValues() throws {
        let defaults = try makeScratchDefaults()
        let keys = ReadingPreferencesStore.StorageKeys(
            fontSize: "reader-font",
            fontFamily: "reader-family",
            lineSpacing: "reader-spacing",
            defaultReplySort: "reader-sort",
            mediaLoading: "reader-media"
        )
        defaults.set("oversized", forKey: keys.fontSize)
        defaults.set(ReaderFontFamily.rounded.rawValue, forKey: keys.fontFamily)
        defaults.set(ReaderLineSpacing.compact.rawValue, forKey: keys.lineSpacing)
        defaults.set(ThreadReplySort.ascending.rawValue, forKey: keys.defaultReplySort)
        defaults.set(ReaderMediaLoadingPolicy.dataSaving.rawValue, forKey: keys.mediaLoading)

        let store = ReadingPreferencesStore(defaults: defaults, keys: keys)
        XCTAssertEqual(store.preferences.fontSize, .standard)
        XCTAssertEqual(store.preferences.fontFamily, .rounded)
        XCTAssertEqual(store.preferences.lineSpacing, .compact)
        XCTAssertEqual(store.preferences.defaultReplySort, .ascending)
        XCTAssertEqual(store.preferences.mediaLoading, .dataSaving)
        XCTAssertNil(defaults.object(forKey: keys.fontSize))
        XCTAssertEqual(defaults.string(forKey: keys.lineSpacing), ReaderLineSpacing.compact.rawValue)
        XCTAssertEqual(defaults.integer(forKey: keys.defaultReplySort), ThreadReplySort.ascending.rawValue)
        XCTAssertEqual(
            defaults.string(forKey: keys.mediaLoading),
            ReaderMediaLoadingPolicy.dataSaving.rawValue
        )

        defaults.set("invalid-media-policy", forKey: keys.mediaLoading)
        let sanitizedMedia = ReadingPreferencesStore(defaults: defaults, keys: keys)
        XCTAssertEqual(sanitizedMedia.preferences.lineSpacing, .compact)
        XCTAssertEqual(sanitizedMedia.preferences.defaultReplySort, .ascending)
        XCTAssertEqual(sanitizedMedia.preferences.mediaLoading, .automatic)
        XCTAssertNil(defaults.object(forKey: keys.mediaLoading))
        XCTAssertNotNil(defaults.object(forKey: keys.lineSpacing))
        XCTAssertNotNil(defaults.object(forKey: keys.defaultReplySort))
    }

    @MainActor
    func testReadingPreferencesResetRemovesEveryOverride() throws {
        let defaults = try makeScratchDefaults()
        let keys = ReadingPreferencesStore.StorageKeys(
            fontSize: "reader-font",
            fontFamily: "reader-family",
            lineSpacing: "reader-spacing",
            defaultReplySort: "reader-sort",
            mediaLoading: "reader-media"
        )
        let store = ReadingPreferencesStore(defaults: defaults, keys: keys)
        store.update(ReadingPreferences(
            fontSize: .extraLarge,
            fontFamily: .monospaced,
            lineSpacing: .relaxed,
            defaultReplySort: .descending,
            mediaLoading: .manual
        ))

        store.reset()

        XCTAssertEqual(store.preferences, .default)
        XCTAssertNil(defaults.object(forKey: keys.fontSize))
        XCTAssertNil(defaults.object(forKey: keys.fontFamily))
        XCTAssertNil(defaults.object(forKey: keys.lineSpacing))
        XCTAssertNil(defaults.object(forKey: keys.defaultReplySort))
        XCTAssertNil(defaults.object(forKey: keys.mediaLoading))
    }

    func testReaderFontSizeAndDynamicTypeScalingAreMonotonic() {
        let largeCategory = UITraitCollection(preferredContentSizeCategory: .large)
        let pointSizes = ReaderFontSize.allCases.map {
            ReaderTypographyPolicy.font(
                textStyle: .body,
                fontSize: $0,
                compatibleWith: largeCategory
            ).pointSize
        }
        XCTAssertEqual(pointSizes.count, 4)
        XCTAssertLessThan(pointSizes[0], pointSizes[1])
        XCTAssertLessThan(pointSizes[1], pointSizes[2])
        XCTAssertLessThan(pointSizes[2], pointSizes[3])

        let accessibilityCategory = UITraitCollection(
            preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
        let standardFont = ReaderTypographyPolicy.font(
            textStyle: .body,
            fontSize: .standard,
            compatibleWith: largeCategory
        )
        let accessibilityFont = ReaderTypographyPolicy.font(
            textStyle: .body,
            fontSize: .standard,
            compatibleWith: accessibilityCategory
        )
        XCTAssertGreaterThan(accessibilityFont.pointSize, standardFont.pointSize)

        let serifFont = ReaderTypographyPolicy.font(
            textStyle: .body,
            fontSize: .standard,
            fontFamily: .serif,
            compatibleWith: largeCategory
        )
        XCTAssertEqual(serifFont.pointSize, standardFont.pointSize, accuracy: 0.01)
        XCTAssertNotEqual(serifFont.fontName, standardFont.fontName)
    }

    func testReaderFontImportPolicyExposesSelectableTTFAndOTFTypes() throws {
        XCTAssertEqual(ReaderFontImportPolicy.supportedFileExtensions, ["ttf", "otf"])

        let contentTypes = ReaderFontImportPolicy.allowedContentTypes
        XCTAssertEqual(contentTypes.count, 2)
        for (fileExtension, contentType) in zip(
            ReaderFontImportPolicy.supportedFileExtensions,
            contentTypes
        ) {
            let systemResolvedType = try XCTUnwrap(
                UTType(filenameExtension: fileExtension)
            )
            XCTAssertEqual(contentType, systemResolvedType)
            XCTAssertTrue(contentType.conforms(to: .data))
            XCTAssertEqual(contentType.preferredFilenameExtension, fileExtension)
            XCTAssertTrue(ReaderFontImportPolicy.supports(fileExtension: fileExtension.uppercased()))
        }
        XCTAssertFalse(ReaderFontImportPolicy.supports(fileExtension: "ttc"))
    }

    func testBuiltInReaderFontTitlesDescribeWesternGlyphScope() {
        XCTAssertEqual(ReaderFontFamily.serif.title, "衬线（西文）")
        XCTAssertEqual(ReaderFontFamily.rounded.title, "圆体（西文）")
        XCTAssertEqual(ReaderFontFamily.monospaced.title, "等宽（西文）")
    }

    @MainActor
    func testReaderFontStoreRejectsUnsupportedAndCorruptFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = ReaderFontStore(baseDirectoryURL: directory)

        let unsupported = directory.appendingPathComponent("font.txt")
        try Data("not a font".utf8).write(to: unsupported)
        XCTAssertThrowsError(try ReaderFontStore.prepareImport(from: unsupported)) { error in
            XCTAssertEqual(error as? ReaderFontStoreError, .unsupportedFile)
        }

        let corrupt = directory.appendingPathComponent("font.ttf")
        try Data("not a font".utf8).write(to: corrupt)
        XCTAssertThrowsError(try ReaderFontStore.prepareImport(from: corrupt)) { error in
            XCTAssertEqual(error as? ReaderFontStoreError, .invalidFont)
        }
        XCTAssertTrue(store.entries.isEmpty)
    }

    @MainActor
    func testMissingImportedReaderFontSelectionFallsBackToSystem() throws {
        let defaults = try makeScratchDefaults()
        let keys = ReadingPreferencesStore.StorageKeys(
            fontSize: "reader-font",
            fontFamily: "reader-family",
            lineSpacing: "reader-spacing",
            defaultReplySort: "reader-sort",
            mediaLoading: "reader-media"
        )
        let missingFamily = try XCTUnwrap(
            ReaderFontFamily.imported(postScriptName: "MissingReaderFont-Regular")
        )
        defaults.set(missingFamily.rawValue, forKey: keys.fontFamily)
        let store = ReadingPreferencesStore(defaults: defaults, keys: keys)

        XCTAssertEqual(store.preferences.fontFamily, missingFamily)
        store.reconcileAvailableImportedFonts([])

        XCTAssertEqual(store.preferences.fontFamily, .system)
        XCTAssertNil(defaults.object(forKey: keys.fontFamily))
        XCTAssertNil(ReaderFontFamily(rawValue: "imported:Bad\nFont"))
    }

    func testReaderLineSpacingPreservesExistingDefaultsAndMapsPreferences() {
        XCTAssertEqual(
            ReaderTypographyPolicy.lineSpacing(.standard, context: .body),
            8,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderTypographyPolicy.lineSpacing(.standard, context: .subpost),
            3,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderTypographyPolicy.lineSpacing(.compact, context: .body),
            6,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderTypographyPolicy.lineSpacing(.relaxed, context: .body),
            12,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderTypographyPolicy.lineSpacing(.compact, context: .subpost),
            2.25,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderTypographyPolicy.lineSpacing(.relaxed, context: .subpost),
            4.5,
            accuracy: 0.001
        )
        // The 标题 heading is set larger than the body, so it keeps a wider gap.
        XCTAssertEqual(
            ReaderTypographyPolicy.lineSpacing(.standard, context: .title),
            8,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderTypographyPolicy.lineSpacing(.compact, context: .title),
            6,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderTypographyPolicy.lineSpacing(.relaxed, context: .title),
            12,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderTypographyPolicy.kern(.standard, context: .body),
            0.45,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderTypographyPolicy.kern(.compact, context: .body),
            0.3375,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderTypographyPolicy.kern(.relaxed, context: .body),
            0.675,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderTypographyPolicy.kern(.standard, context: .subpost),
            0.25,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderTypographyPolicy.kern(.standard, context: .title),
            0.5,
            accuracy: 0.001
        )
    }

    func testReaderMediaRequestPolicyControlsAutomaticAndFallbackRequests() {
        XCTAssertEqual(
            ReaderMediaRequestPolicy.resolve(.automatic),
            ReaderMediaRequestPolicy(loadsAutomatically: true, allowsFallback: true)
        )
        XCTAssertEqual(
            ReaderMediaRequestPolicy.resolve(.dataSaving),
            ReaderMediaRequestPolicy(loadsAutomatically: true, allowsFallback: false)
        )
        XCTAssertEqual(
            ReaderMediaRequestPolicy.resolve(.manual),
            ReaderMediaRequestPolicy(loadsAutomatically: false, allowsFallback: true)
        )

        let manual = ReaderMediaRequestPolicy.resolve(.manual)
        XCTAssertFalse(manual.allowsLoading(sourceIdentity: "image-a", manualAuthorization: nil))
        XCTAssertTrue(manual.allowsLoading(sourceIdentity: "image-a", manualAuthorization: "image-a"))
        XCTAssertFalse(
            manual.allowsLoading(sourceIdentity: "image-b", manualAuthorization: "image-a"),
            "手动加载授权不得跟随复用视图泄漏到新的媒体 URL"
        )

        let dataSaving = ReaderMediaRequestPolicy.resolve(.dataSaving)
        XCTAssertFalse(dataSaving.allowsFallback(sourceIdentity: "image-a", explicitAuthorization: nil))
        XCTAssertTrue(
            dataSaving.allowsFallback(
                sourceIdentity: "image-a",
                explicitAuthorization: "image-a"
            )
        )
        XCTAssertFalse(
            dataSaving.allowsFallback(
                sourceIdentity: "image-b",
                explicitAuthorization: "image-a"
            ),
            "显式原图授权只属于用户点击的当前媒体"
        )
    }

    func testReaderImageRequestSourcePolicySkipsFailedPreviewAfterExplicitOriginalTap() throws {
        let preview = try XCTUnwrap(URL(string: "https://example.com/preview.jpg"))
        let original = try XCTUnwrap(URL(string: "https://example.com/original.jpg"))
        let sourceIdentity = "image-a"

        XCTAssertEqual(
            ReaderImageRequestSourcePolicy.resolve(
                previewURL: preview,
                originalURL: original,
                requestPolicy: .resolve(.automatic),
                sourceIdentity: sourceIdentity,
                explicitOriginalAuthorization: nil
            ),
            ReaderImageRequestSources(primaryURL: preview, fallbackURL: original)
        )
        XCTAssertEqual(
            ReaderImageRequestSourcePolicy.resolve(
                previewURL: preview,
                originalURL: original,
                requestPolicy: .resolve(.dataSaving),
                sourceIdentity: sourceIdentity,
                explicitOriginalAuthorization: nil
            ),
            ReaderImageRequestSources(primaryURL: preview, fallbackURL: nil)
        )
        XCTAssertEqual(
            ReaderImageRequestSourcePolicy.resolve(
                previewURL: preview,
                originalURL: original,
                requestPolicy: .resolve(.dataSaving),
                sourceIdentity: sourceIdentity,
                explicitOriginalAuthorization: sourceIdentity
            ),
            ReaderImageRequestSources(primaryURL: original, fallbackURL: nil),
            "明确点击加载原图后必须跳过已经失败的缩略图"
        )
        XCTAssertEqual(
            ReaderImageRequestSourcePolicy.resolve(
                previewURL: preview,
                originalURL: original,
                requestPolicy: .resolve(.dataSaving),
                sourceIdentity: "image-b",
                explicitOriginalAuthorization: sourceIdentity
            ),
            ReaderImageRequestSources(primaryURL: preview, fallbackURL: nil),
            "原图授权不得泄漏到复用后的另一张图片"
        )
    }

    func testAutomaticMediaRemainsActivatableWhilePreviewLoads() {
        XCTAssertFalse(ReaderMediaActivationPolicy.blocksWhileLoading(
            requestPolicy: .resolve(.automatic)
        ))
        XCTAssertFalse(ReaderMediaActivationPolicy.blocksWhileLoading(
            requestPolicy: .resolve(.dataSaving)
        ))
        XCTAssertTrue(ReaderMediaActivationPolicy.blocksWhileLoading(
            requestPolicy: .resolve(.manual)
        ))
    }

    func testInitialPostTargetOverridesDefaultReplySort() {
        XCTAssertEqual(
            ThreadInitialReplySortPolicy.resolve(
                defaultReplySort: .descending,
                initialPostID: 2_002
            ),
            .ascending
        )
        XCTAssertEqual(
            ThreadInitialReplySortPolicy.resolve(
                defaultReplySort: .hot,
                initialPostID: 2_002
            ),
            .ascending
        )
        XCTAssertEqual(
            ThreadInitialReplySortPolicy.resolve(
                defaultReplySort: .descending,
                initialPostID: nil
            ),
            .descending
        )
    }
}
