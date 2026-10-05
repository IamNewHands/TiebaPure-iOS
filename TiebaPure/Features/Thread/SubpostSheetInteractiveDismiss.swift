import SwiftUI
import UIKit

enum SubpostSheetDismissPhase: String, Equatable {
    case idle
    case tracking
    case restoring
    case dismissing
}

enum SubpostSheetDismissAxis: Equatable {
    case rightSwipe
    case pullDown
}

enum SubpostSheetScrollCoordinateSpace {
    static let name = "subpost-sheet-scroll"
}

struct SubpostSheetScrollTopPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat?

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

private enum SubpostAnimationCompletion {
    case dismiss
    case restore
}

struct SubpostSheetDismissAction {
    let handler: () -> Void

    func callAsFunction() {
        handler()
    }
}

private struct SubpostSheetDismissActionKey: EnvironmentKey {
    static let defaultValue = SubpostSheetDismissAction(handler: {})
}

private extension EnvironmentValues {
    var subpostSheetDismissAction: SubpostSheetDismissAction {
        get { self[SubpostSheetDismissActionKey.self] }
        set { self[SubpostSheetDismissActionKey.self] = newValue }
    }
}

private struct SubpostSheetLegacyScrollTelemetryAction {
    let onSnapshot: (LegacyScrollTelemetrySnapshot) -> Void
    let onPanChange: (LegacyScrollPanEvent) -> Void
}

private struct SubpostSheetLegacyScrollTelemetryActionKey: EnvironmentKey {
    static let defaultValue = SubpostSheetLegacyScrollTelemetryAction(
        onSnapshot: { _ in },
        onPanChange: { _ in }
    )
}

private extension EnvironmentValues {
    var subpostSheetLegacyScrollTelemetryAction: SubpostSheetLegacyScrollTelemetryAction {
        get { self[SubpostSheetLegacyScrollTelemetryActionKey.self] }
        set { self[SubpostSheetLegacyScrollTelemetryActionKey.self] = newValue }
    }
}

/// The dismiss drag and the sheet's scroll view recognize simultaneously, so
/// the vertical part of a horizontal drag would otherwise keep scrolling the
/// list while the surface is being dragged sideways. The flag below freezes the
/// scroll view for exactly the phase in which the surface follows the finger
/// along the horizontal dismissal axis.
private struct SubpostSheetContentScrollLockKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var subpostSheetContentScrollLock: Bool {
        get { self[SubpostSheetContentScrollLockKey.self] }
        set { self[SubpostSheetContentScrollLockKey.self] = newValue }
    }
}

private struct SubpostSheetContentScrollLockModifier: ViewModifier {
    @Environment(\.subpostSheetContentScrollLock) private var isLocked

    func body(content: Content) -> some View {
        content.scrollDisabled(isLocked)
    }
}

private struct SubpostSheetLegacyScrollTelemetryModifier: ViewModifier {
    @Environment(\.subpostSheetLegacyScrollTelemetryAction) private var action

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
        } else {
            content.legacyScrollTelemetry(
                onPanChange: action.onPanChange,
                action.onSnapshot
            )
        }
    }
}

extension View {
    func subpostSheetLegacyScrollTelemetry() -> some View {
        modifier(SubpostSheetLegacyScrollTelemetryModifier())
    }

    /// Freezes this scroll view while the sheet's horizontal dismissal drag
    /// owns the gesture, so the content cannot follow the vertical part of the
    /// same finger movement. Re-enabled as soon as the drag ends or restores.
    func subpostSheetContentScrollLock() -> some View {
        modifier(SubpostSheetContentScrollLockModifier())
    }
}

struct SubpostSheetDismissButton: View {
    @Environment(\.subpostSheetDismissAction) private var dismissAction

    var body: some View {
        Button("完成") {
            dismissAction()
        }
        .accessibilityHint("关闭楼中楼并返回帖子")
    }
}

/// Owns the complete interactive motion inside the transparent system sheet.
///
/// The system presentation controller remains stationary throughout the drag.
/// Only this SwiftUI surface follows the finger, so UIKit cannot relayout the
/// moving layer behind our back. Completion has one owner: `onDismiss` clears
/// the SwiftUI sheet item after the surface is already offscreen.
struct SubpostSheetInteractiveDismissSurface<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var isEnabled = true
    let onDismiss: () -> Void
    private let content: Content

    @State private var phase = SubpostSheetDismissPhase.idle
    @State private var horizontalOffset: CGFloat = 0
    @State private var verticalOffset: CGFloat = 0
    @State private var rejectedCurrentGesture = false
    @State private var activeDismissAxis: SubpostSheetDismissAxis?
    @State private var isContentAtTop = false
    @State private var contentTopBaseline: CGFloat?
    @State private var legacyPullDownStartedAtTop = false
    @State private var legacyPullDownRejected = false
    @State private var animationGeneration: UInt = 0
    @GestureState private var dismissGestureIsActive = false

    init(
        isEnabled: Bool = true,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.isEnabled = isEnabled
        self.onDismiss = onDismiss
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let containerSize = proxy.size

            content
                .frame(
                    width: containerSize.width,
                    height: containerSize.height
                )
                .background(Color(uiColor: .systemBackground))
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 24,
                        topTrailingRadius: 24
                    )
                )
                .accessibilityIdentifier("subpost-sheet-surface")
                .contentShape(Rectangle())
                .offset(x: horizontalOffset, y: verticalOffset)
                .environment(
                    \.subpostSheetDismissAction,
                    SubpostSheetDismissAction {
                        finishDismissal(containerSize: containerSize)
                    }
                )
                .environment(
                    \.subpostSheetLegacyScrollTelemetryAction,
                    SubpostSheetLegacyScrollTelemetryAction(
                        onSnapshot: handleLegacyScrollSnapshot,
                        onPanChange: { event in
                            handleLegacyScrollPan(
                                event,
                                containerSize: containerSize
                            )
                        }
                    )
                )
                .environment(
                    \.subpostSheetContentScrollLock,
                    SubpostSheetContentScrollPolicy.locksScrolling(
                        phase: phase,
                        axis: activeDismissAxis
                    )
                )
                .simultaneousGesture(
                    dismissGesture(containerSize: containerSize),
                    isEnabled: isEnabled && phase != .dismissing
                )
                .accessibilityAction(named: "关闭楼中楼") {
                    finishDismissal(containerSize: containerSize)
                }
                .compatibleOnChange(of: containerSize) { previousSize, newSize in
                    guard previousSize != newSize else { return }
                    if phase == .dismissing {
                        // Rotation during the short completion animation must
                        // never make an already-hidden surface visible again.
                        let rotationDuration: TimeInterval = reduceMotion ? 0.12 : 0.2
                        if activeDismissAxis == .rightSwipe {
                            let targetOffset = max(horizontalOffset, newSize.width + 32)
                            animateOffset(
                                target: targetOffset,
                                axis: .rightSwipe,
                                animation: .easeOut(duration: rotationDuration),
                                duration: rotationDuration,
                                completion: .dismiss
                            )
                        } else {
                            let targetOffset = max(verticalOffset, newSize.height + 32)
                            animateOffset(
                                target: targetOffset,
                                axis: activeDismissAxis,
                                animation: .easeOut(duration: rotationDuration),
                                duration: rotationDuration,
                                completion: .dismiss
                            )
                        }
                    } else {
                        cancelInterruptedGesture()
                    }
                }
        }
        // The transparent system sheet stops its proposed content height above
        // the bottom container safe area. Extend the complete moving surface,
        // rather than a stationary background, so the safe-area strip stays
        // white at rest and still moves away with the interactive dismissal.
        .ignoresSafeArea(.container, edges: .bottom)
        .background(Color.clear)
        .background {
            SubpostSheetTransparentHostInstaller()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .compatibleOnChange(of: isEnabled) { _, enabled in
            guard enabled == false, phase == .tracking else { return }
            restore()
        }
        .onPreferenceChange(SubpostSheetScrollTopPreferenceKey.self) { contentTop in
            guard let contentTop, contentTop.isFinite else { return }
            let baseline = max(contentTopBaseline ?? contentTop, contentTop)
            contentTopBaseline = baseline
            isContentAtTop = contentTop >= baseline - 1
        }
        .compatibleOnChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active else { return }
            cancelInterruptedGesture()
        }
        .compatibleOnChange(of: dismissGestureIsActive) { wasActive, isActive in
            guard wasActive, isActive == false else { return }
            // GestureState resets even when the system cancels the gesture and
            // omits `onEnded`. Defer one main-actor turn so a normal `onEnded`
            // can choose dismiss/restore first.
            Task { @MainActor in
                await Task.yield()
                guard dismissGestureIsActive == false else { return }
                if phase == .tracking {
                    restore()
                } else if phase == .idle, rejectedCurrentGesture {
                    // A vertical/leftward gesture can be rejected before the
                    // phase enters tracking. If the system cancels it without
                    // `onEnded`, clear that rejection as well.
                    rejectedCurrentGesture = false
                    horizontalOffset = 0
                    verticalOffset = 0
                    activeDismissAxis = nil
                }
            }
        }
        .onDisappear {
            cancelInterruptedGesture()
        }
    }

    private func dismissGesture(containerSize: CGSize) -> some Gesture {
        DragGesture(
            minimumDistance: SubpostRightSwipeDismissPolicy.minimumTrackingDistance,
            coordinateSpace: .local
        )
        .updating($dismissGestureIsActive) { _, isActive, _ in
            isActive = true
        }
        .onChanged { value in
            handleDragChanged(
                translation: value.translation,
                containerSize: containerSize
            )
        }
        .onEnded { value in
            handleDragEnded(
                translation: value.translation,
                predictedTranslation: value.predictedEndTranslation,
                containerSize: containerSize
            )
        }
    }

    private func handleDragChanged(
        translation: CGSize,
        containerSize: CGSize
    ) {
        guard isEnabled,
              phase != .dismissing,
              phase != .restoring,
              rejectedCurrentGesture == false else {
            return
        }

        if phase == .idle {
            if SubpostRightSwipeDismissPolicy.shouldBegin(translation: translation) {
                activeDismissAxis = .rightSwipe
            } else if SubpostPullDownDismissPolicy.shouldBegin(
                translation: translation,
                isContentAtTop: isContentAtTop
            ) {
                activeDismissAxis = .pullDown
            } else {
                rejectedCurrentGesture = true
                return
            }
            phase = .tracking
        }

        guard phase == .tracking else { return }
        switch activeDismissAxis {
        case .rightSwipe:
            // 用户要求：右滑拖动阶段保持垂直位移固定（不上下移动），
            // 水平位移跟手左右移动（往左拉可撤回取消退出）。
            horizontalOffset = SubpostRightSwipeDismissPolicy.horizontalOffset(
                translationX: translation.width,
                containerWidth: containerSize.width
            )
            verticalOffset = 0
        case .pullDown:
            verticalOffset = SubpostPullDownDismissPolicy.verticalOffset(
                translationY: translation.height,
                containerHeight: containerSize.height
            )
            horizontalOffset = 0
        case nil:
            horizontalOffset = 0
            verticalOffset = 0
        }
    }

    private func handleDragEnded(
        translation: CGSize,
        predictedTranslation: CGSize,
        containerSize: CGSize
    ) {
        defer {
            rejectedCurrentGesture = false
        }
        guard phase == .tracking else {
            if phase == .idle {
                horizontalOffset = 0
                verticalOffset = 0
                activeDismissAxis = nil
            }
            return
        }

        let shouldDismiss: Bool
        var releaseVelocity: CGFloat = 0
        switch activeDismissAxis {
        case .rightSwipe:
            releaseVelocity = SubpostRightSwipeDismissPolicy.releaseVelocity(
                translationX: translation.width,
                predictedTranslationX: predictedTranslation.width
            )
            shouldDismiss = SubpostRightSwipeDismissPolicy.shouldFinish(
                translationX: translation.width,
                predictedTranslationX: predictedTranslation.width,
                containerWidth: containerSize.width
            )
        case .pullDown:
            shouldDismiss = SubpostPullDownDismissPolicy.shouldFinish(
                translationY: translation.height,
                predictedTranslationY: predictedTranslation.height,
                containerHeight: containerSize.height
            )
        case nil:
            shouldDismiss = false
        }
        if shouldDismiss {
            finishDismissal(
                containerSize: containerSize,
                releaseVelocity: releaseVelocity
            )
        } else {
            restore()
        }
    }

    private func handleLegacyScrollSnapshot(_ snapshot: LegacyScrollTelemetrySnapshot) {
        if #available(iOS 17.0, *) { return }
        isContentAtTop = snapshot.distanceFromTop <= 1
    }

    private func handleLegacyScrollPan(
        _ event: LegacyScrollPanEvent,
        containerSize: CGSize
    ) {
        if #available(iOS 17.0, *) { return }

        switch event.state {
        case .began:
            legacyPullDownStartedAtTop = isContentAtTop
            legacyPullDownRejected = false
        case .changed:
            guard isEnabled,
                  phase != .dismissing,
                  phase != .restoring,
                  legacyPullDownRejected == false else {
                return
            }
            if phase == .idle {
                let distance = hypot(event.translation.width, event.translation.height)
                guard distance >= SubpostRightSwipeDismissPolicy.minimumTrackingDistance else {
                    return
                }
                guard SubpostPullDownDismissPolicy.shouldBegin(
                    translation: event.translation,
                    isContentAtTop: legacyPullDownStartedAtTop
                ) else {
                    legacyPullDownRejected = true
                    return
                }
                activeDismissAxis = .pullDown
                phase = .tracking
            }
            guard phase == .tracking, activeDismissAxis == .pullDown else { return }
            verticalOffset = SubpostPullDownDismissPolicy.verticalOffset(
                translationY: event.translation.height,
                containerHeight: containerSize.height
            )
            horizontalOffset = 0
        case .ended:
            defer { resetLegacyPullDownGesture() }
            guard phase == .tracking, activeDismissAxis == .pullDown else { return }
            if SubpostPullDownDismissPolicy.shouldFinish(
                translationY: event.translation.height,
                predictedTranslationY: event.translation.height,
                containerHeight: containerSize.height
            ) {
                finishDismissal(containerSize: containerSize)
            } else {
                restore()
            }
        case .cancelled, .failed:
            defer { resetLegacyPullDownGesture() }
            if phase == .tracking, activeDismissAxis == .pullDown {
                restore()
            }
        case .possible:
            break
        @unknown default:
            defer { resetLegacyPullDownGesture() }
            if phase == .tracking, activeDismissAxis == .pullDown {
                restore()
            }
        }
    }

    private func resetLegacyPullDownGesture() {
        legacyPullDownStartedAtTop = false
        legacyPullDownRejected = false
    }

    private func finishDismissal(
        containerSize: CGSize,
        releaseVelocity: CGFloat = 0
    ) {
        guard phase != .dismissing else { return }
        phase = .dismissing

        let isRightSwipe = activeDismissAxis == .rightSwipe
        let targetOffset = isRightSwipe
            ? max(containerSize.width + 32, 1)
            : max(containerSize.height + 32, 1)
        let duration = dismissalDuration(
            isRightSwipe: isRightSwipe,
            targetOffset: targetOffset,
            releaseVelocity: releaseVelocity
        )

        animateOffset(
            target: targetOffset,
            axis: activeDismissAxis,
            animation: .easeOut(duration: duration),
            duration: duration,
            completion: .dismiss
        )
    }

    /// 松手那一刻手指还在移动，所以滑出的时长由剩余距离和松手速度推出：动画起步
    /// 就接近手指速度再减速（`easeOut` 起步即最快），不会像 `easeIn` 那样先停住
    /// 再加速，那段“停住”就是用户看到的卡顿。
    private func dismissalDuration(
        isRightSwipe: Bool,
        targetOffset: CGFloat,
        releaseVelocity: CGFloat
    ) -> TimeInterval {
        guard reduceMotion == false else { return 0.12 }
        guard isRightSwipe else { return 0.24 }
        return SubpostRightSwipeDismissPolicy.completionDuration(
            remainingDistance: max(targetOffset - horizontalOffset, 1),
            releaseVelocity: releaseVelocity
        )
    }

    private func restore() {
        guard phase != .dismissing else { return }
        phase = .restoring
        rejectedCurrentGesture = false

        let duration = reduceMotion ? 0.10 : 0.22
        // 回弹不使用带过冲的弹簧：过冲会越过静止位置继续向左，正是“往左缩”的来源。
        animateOffset(
            target: 0,
            axis: activeDismissAxis,
            animation: .spring(duration: duration, bounce: 0),
            duration: duration,
            completion: .restore
        )
    }

    /// Applies one animated offset change and owns its completion.
    ///
    /// "The animation has finished" cannot be read off the offset value: the
    /// `AnimatableModifier` that used to watch for the target value re-evaluated
    /// this whole surface on every animation frame, and could report the target
    /// before a single frame had been drawn, which cleared the sheet in the
    /// middle of its own dismissal slide. Waiting out the animation's own
    /// duration on the main actor is cheaper and predictable: the completion
    /// never runs before the surface has left the screen, and the generation
    /// token invalidates it as soon as another animation takes over.
    private func animateOffset(
        target: CGFloat,
        axis: SubpostSheetDismissAxis?,
        animation: Animation,
        duration: TimeInterval,
        completion: SubpostAnimationCompletion?
    ) {
        animationGeneration &+= 1
        let generation = animationGeneration
        withAnimation(animation) {
            switch axis {
            case .rightSwipe:
                horizontalOffset = target
                verticalOffset = 0
            case .pullDown:
                verticalOffset = target
                horizontalOffset = 0
            case nil:
                verticalOffset = target
            }
        }
        guard let completion else { return }
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64((duration + 0.04) * 1_000_000_000)
            )
            guard generation == animationGeneration else { return }
            switch completion {
            case .dismiss:
                guard phase == .dismissing else { return }
                onDismiss()
            case .restore:
                guard phase == .restoring else { return }
                horizontalOffset = 0
                verticalOffset = 0
                activeDismissAxis = nil
                phase = .idle
            }
        }
    }

    /// SwiftUI's `DragGesture` does not expose UIKit's cancelled/failed states.
    /// Rotation, scene deactivation, or removal of the gesture host can
    /// therefore interrupt a drag without calling `onEnded`. Reset all
    /// transient state so the next presentation never inherits a half-dragged
    /// surface or a permanently rejected gesture.
    private func cancelInterruptedGesture() {
        guard phase != .dismissing else { return }
        animationGeneration &+= 1
        phase = .idle
        horizontalOffset = 0
        verticalOffset = 0
        rejectedCurrentGesture = false
        activeDismissAxis = nil
        resetLegacyPullDownGesture()
    }
}

/// Makes only the sheet's hosting path transparent. The presentation
/// container and its dimming view remain system-owned, while the gap above the
/// moving SwiftUI surface reveals the real thread instead of an opaque host.
private struct SubpostSheetTransparentHostInstaller: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AttachmentController {
        AttachmentController()
    }

    func updateUIViewController(
        _ uiViewController: AttachmentController,
        context: Context
    ) {
        uiViewController.makeHostingPathTransparent()
    }

    final class AttachmentController: UIViewController {
        private var retryScheduled = false
        private var retryCount = 0
        private static let maximumRetryCount = 12

        override func loadView() {
            let view = UIView(frame: .zero)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            retryCount = 0
            makeHostingPathTransparent()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            retryCount = 0
            makeHostingPathTransparent()
        }

        func makeHostingPathTransparent() {
            guard let presentedView = presentedSurface(containing: self) else {
                scheduleRetry()
                return
            }
            guard view === presentedView || view.isDescendant(of: presentedView) else {
                scheduleRetry()
                return
            }

            retryScheduled = false
            retryCount = 0
            var candidate: UIView? = view
            while let current = candidate {
                current.backgroundColor = .clear
                current.layer.backgroundColor = UIColor.clear.cgColor
                current.isOpaque = false
                current.layer.isOpaque = false
                if current === presentedView {
                    break
                }
                candidate = current.superview
            }
        }

        private func scheduleRetry() {
            guard retryScheduled == false,
                  retryCount < Self.maximumRetryCount else {
                return
            }
            retryScheduled = true
            retryCount += 1
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.retryScheduled = false
                self.makeHostingPathTransparent()
            }
        }

        private func presentedSurface(
            containing controller: UIViewController
        ) -> UIView? {
            var ancestor: UIViewController? = controller
            while let current = ancestor {
                if current.presentingViewController != nil,
                   let presentedView = current.presentationController?.presentedView {
                    return presentedView
                }
                ancestor = current.parent
            }

            var candidate = controller.view.window?.rootViewController
            while let presented = candidate?.presentedViewController {
                if controller.view.isDescendant(of: presented.view),
                   let presentedView = presented.presentationController?.presentedView {
                    return presentedView
                }
                candidate = presented
            }
            return nil
        }
    }
}

/// Decides when the sheet stops scrolling its own content. A right-swipe
/// dismissal moves the surface horizontally, so the vertical part of the same
/// finger movement must not reach the list; a pull-down dismissal keeps the
/// scroll view live because reaching the content top is what starts it (and on
/// iOS 16 the scroll view's own pan is the only signal that reports it).
///
/// The freeze also covers the horizontal slide-out that follows the release:
/// re-enabling the scroll view in the same frame as the release lets UIKit
/// resume the pan recogniser it cancelled mid-touch, which snaps the content
/// offset and costs frames exactly while the dismissal animates.
enum SubpostSheetContentScrollPolicy {
    static func locksScrolling(
        phase: SubpostSheetDismissPhase,
        axis: SubpostSheetDismissAxis?
    ) -> Bool {
        guard axis == .rightSwipe else { return false }
        switch phase {
        case .tracking, .dismissing:
            return true
        case .idle, .restoring:
            return false
        }
    }
}

enum SubpostRightSwipeDismissPolicy {
    static let minimumTrackingDistance: CGFloat = 8
    static let horizontalDominance: CGFloat = 1.2
    static let completionProgress: CGFloat = 0.22
    static let completionDistance: CGFloat = 80
    static let predictedCompletionDistance: CGFloat = 180
    static let predictionDuration: CGFloat = 0.18
    static let maximumInteractiveOffsetFraction: CGFloat = 0.72
    /// 滑出动画的时长下限/上限与最低假定速度：慢速松手也要看得见滑动，快速甩出
    /// 也不能长到像在等待。
    static let minimumCompletionSpeed: CGFloat = 1_100
    static let minimumCompletionDuration: TimeInterval = 0.18
    static let maximumCompletionDuration: TimeInterval = 0.34

    static func shouldBegin(translation: CGSize) -> Bool {
        translation.width > 0
            && translation.width > abs(translation.height) * horizontalDominance
    }

    static func horizontalOffset(translationX: CGFloat, containerWidth: CGFloat) -> CGFloat {
        guard containerWidth > 0 else { return 0 }
        return min(max(translationX, 0), containerWidth * maximumInteractiveOffsetFraction)
    }

    static func verticalOffset(translationX: CGFloat, containerHeight: CGFloat) -> CGFloat {
        guard containerHeight > 0 else { return 0 }
        return min(max(translationX, 0), containerHeight * maximumInteractiveOffsetFraction)
    }

    static func predictedTranslation(translationX: CGFloat, velocityX: CGFloat) -> CGFloat {
        max(translationX + velocityX * predictionDuration, 0)
    }

    /// 松手速度由预测位移反推：预测位移 = 实际位移 + 速度 × 预测时长。
    static func releaseVelocity(
        translationX: CGFloat,
        predictedTranslationX: CGFloat
    ) -> CGFloat {
        (predictedTranslationX - translationX) / predictionDuration
    }

    /// 滑出动画时长 = 剩余距离 ÷ 松手速度，钳制在下限与上限之间。
    static func completionDuration(
        remainingDistance: CGFloat,
        releaseVelocity: CGFloat
    ) -> TimeInterval {
        let distance = max(remainingDistance, 1)
        let speed = max(abs(releaseVelocity), minimumCompletionSpeed)
        return min(
            max(Double(distance / speed), minimumCompletionDuration),
            maximumCompletionDuration
        )
    }

    static func shouldFinish(
        translationX: CGFloat,
        predictedTranslationX: CGFloat,
        containerWidth: CGFloat
    ) -> Bool {
        guard containerWidth > 0 else { return false }
        // 用户向左拉撤回：预测位移小于实际位移（正在向左移动）时，除非已拖过大半屏，否则判定为取消退出
        if predictedTranslationX < translationX {
            return translationX >= containerWidth * 0.5 && predictedTranslationX >= containerWidth * 0.4
        }
        return translationX >= completionDistance
            || translationX / containerWidth >= completionProgress
            || predictedTranslationX >= predictedCompletionDistance
    }
}

enum SubpostPullDownDismissPolicy {
    static let verticalDominance: CGFloat = 1.15
    static let completionProgress: CGFloat = 0.18
    static let completionDistance: CGFloat = 120
    static let predictedCompletionDistance: CGFloat = 240
    static let maximumInteractiveOffsetFraction: CGFloat = 0.72

    static func shouldBegin(translation: CGSize, isContentAtTop: Bool) -> Bool {
        isContentAtTop
            && translation.height > 0
            && translation.height > abs(translation.width) * verticalDominance
    }

    static func verticalOffset(translationY: CGFloat, containerHeight: CGFloat) -> CGFloat {
        guard containerHeight > 0 else { return 0 }
        return min(max(translationY, 0), containerHeight * maximumInteractiveOffsetFraction)
    }

    static func shouldFinish(
        translationY: CGFloat,
        predictedTranslationY: CGFloat,
        containerHeight: CGFloat
    ) -> Bool {
        guard containerHeight > 0 else { return false }
        return translationY >= completionDistance
            || translationY / containerHeight >= completionProgress
            || predictedTranslationY >= predictedCompletionDistance
    }
}
