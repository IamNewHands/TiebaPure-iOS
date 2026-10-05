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

private enum SubpostLegacyAnimationCompletion {
    case dismiss
    case restore
}

private struct SubpostLegacyAnimationCompletionObserver: AnimatableModifier {
    var observedValue: CGFloat
    let targetValue: CGFloat?
    let generation: UInt
    let completion: (UInt) -> Void

    var animatableData: CGFloat {
        get { observedValue }
        set {
            observedValue = newValue
            guard let targetValue,
                  abs(newValue - targetValue) <= 0.5 else { return }
            let completion = completion
            let generation = generation
            DispatchQueue.main.async {
                completion(generation)
            }
        }
    }

    func body(content: Content) -> some View {
        content
    }
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
    @State private var legacyAnimationGeneration: UInt = 0
    @State private var legacyAnimationTarget: CGFloat?
    @State private var legacyAnimationCompletion: SubpostLegacyAnimationCompletion?
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
                .modifier(
                    SubpostLegacyAnimationCompletionObserver(
                        observedValue: activeDismissAxis == .rightSwipe ? horizontalOffset : verticalOffset,
                        targetValue: legacyAnimationTarget,
                        generation: legacyAnimationGeneration,
                        completion: completeLegacyAnimation
                    )
                )
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
                        if activeDismissAxis == .rightSwipe {
                            let targetOffset = max(horizontalOffset, newSize.width + 32)
                            if #available(iOS 17.0, *) {
                                horizontalOffset = targetOffset
                            } else {
                                beginLegacyAnimation(
                                    target: targetOffset,
                                    axis: .rightSwipe,
                                    animation: .easeIn(duration: reduceMotion ? 0.12 : 0.24),
                                    completion: .dismiss
                                )
                            }
                        } else {
                            let targetOffset = max(verticalOffset, newSize.height + 32)
                            if #available(iOS 17.0, *) {
                                verticalOffset = targetOffset
                            } else {
                                beginLegacyAnimation(
                                    target: targetOffset,
                                    axis: activeDismissAxis,
                                    animation: .easeIn(duration: reduceMotion ? 0.12 : 0.24),
                                    completion: .dismiss
                                )
                            }
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
        switch activeDismissAxis {
        case .rightSwipe:
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
            finishDismissal(containerSize: containerSize)
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

    private func finishDismissal(containerSize: CGSize) {
        guard phase != .dismissing else { return }
        phase = .dismissing

        let duration = reduceMotion ? 0.12 : 0.24
        let isRightSwipe = activeDismissAxis == .rightSwipe
        let targetOffset = isRightSwipe
            ? max(containerSize.width + 32, 1)
            : max(containerSize.height + 32, 1)

        if #available(iOS 17.0, *) {
            cancelLegacyAnimationCompletion()
            withAnimation(
                .easeIn(duration: duration),
                completionCriteria: .logicallyComplete
            ) {
                if isRightSwipe {
                    horizontalOffset = targetOffset
                } else {
                    verticalOffset = targetOffset
                }
            } completion: {
                guard phase == .dismissing else { return }
                onDismiss()
            }
        } else {
            beginLegacyAnimation(
                target: targetOffset,
                axis: activeDismissAxis,
                animation: .easeIn(duration: duration),
                completion: .dismiss
            )
        }
    }

    private func restore() {
        guard phase != .dismissing else { return }
        phase = .restoring
        rejectedCurrentGesture = false

        let duration = reduceMotion ? 0.10 : 0.22
        let restoringAxis = activeDismissAxis
        if #available(iOS 17.0, *) {
            cancelLegacyAnimationCompletion()
            withAnimation(
                .spring(duration: duration, bounce: reduceMotion ? 0 : 0.08),
                completionCriteria: .logicallyComplete
            ) {
                horizontalOffset = 0
                verticalOffset = 0
            } completion: {
                guard phase == .restoring else { return }
                horizontalOffset = 0
                verticalOffset = 0
                activeDismissAxis = nil
                phase = .idle
            }
        } else {
            beginLegacyAnimation(
                target: 0,
                axis: restoringAxis,
                animation: .spring(duration: duration, bounce: reduceMotion ? 0 : 0.08),
                completion: .restore
            )
        }
    }

    private func beginLegacyAnimation(
        target: CGFloat,
        axis: SubpostSheetDismissAxis?,
        animation: Animation,
        completion: SubpostLegacyAnimationCompletion
    ) {
        legacyAnimationGeneration &+= 1
        legacyAnimationTarget = target
        legacyAnimationCompletion = completion
        withAnimation(animation) {
            if axis == .rightSwipe {
                horizontalOffset = target
            } else {
                verticalOffset = target
            }
        }
    }

    private func completeLegacyAnimation(generation: UInt) {
        guard generation == legacyAnimationGeneration,
              let completion = legacyAnimationCompletion else { return }
        cancelLegacyAnimationCompletion()
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

    private func cancelLegacyAnimationCompletion() {
        legacyAnimationGeneration &+= 1
        legacyAnimationTarget = nil
        legacyAnimationCompletion = nil
    }

    /// SwiftUI's `DragGesture` does not expose UIKit's cancelled/failed states.
    /// Rotation, scene deactivation, or removal of the gesture host can
    /// therefore interrupt a drag without calling `onEnded`. Reset all
    /// transient state so the next presentation never inherits a half-dragged
    /// surface or a permanently rejected gesture.
    private func cancelInterruptedGesture() {
        guard phase != .dismissing else { return }
        cancelLegacyAnimationCompletion()
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

enum SubpostRightSwipeDismissPolicy {
    static let minimumTrackingDistance: CGFloat = 8
    static let horizontalDominance: CGFloat = 1.2
    static let completionProgress: CGFloat = 0.28
    static let completionDistance: CGFloat = 110
    static let predictedCompletionDistance: CGFloat = 220
    static let predictionDuration: CGFloat = 0.18
    static let maximumInteractiveOffsetFraction: CGFloat = 0.72

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

    static func shouldFinish(
        translationX: CGFloat,
        predictedTranslationX: CGFloat,
        containerWidth: CGFloat
    ) -> Bool {
        guard containerWidth > 0 else { return false }
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
