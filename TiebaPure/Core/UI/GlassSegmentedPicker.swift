import SwiftUI

/// One choice in a `GlassSegmentedPicker`. A named type rather than a tuple so
/// `ForEach` can key on the value and the call sites stay readable.
struct GlassPickerOption<Value: Hashable> {
    let value: Value
    let label: String

    init(value: Value, label: String) {
        self.value = value
        self.label = label
    }
}

/// Height of the glass bar: a 32 pt segment plus 3 pt of padding on each side.
private let glassBarHeight: CGFloat = 38
/// Inset between the bar's capsule and the segments.
private let glassBarPadding: CGFloat = 3
/// Gap between two segments.
private let glassBarGap: CGFloat = 2
/// How much the lens magnifies what sits under it.
private let lensMagnification: CGFloat = 1.2

/// The section switcher used at the top of the feed, messages, favorites,
/// history and search screens.
///
/// On iOS 26 and later it draws a real Liquid Glass bar: one glass capsule with
/// a translucent selection capsule sliding inside it. The selection is a plain
/// tinted capsule instead of a second `.glassEffect` because stacking glass on
/// glass turns the selected segment muddy instead of reading as a raised lens.
///
/// Holding the bar lifts a magnifying lens over the segment under the finger —
/// the same gesture the system tab bar answers with. The lens is a second glass
/// capsule that rides above the bar and clips a scaled copy of the labels, so
/// the text under the finger genuinely grows rather than just changing colour.
/// Dragging carries the lens segment by segment with a haptic on each, and the
/// finger lifting commits the segment the lens is over. Without that, switching
/// sections meant aiming at a 32 pt target; with it the whole bar is draggable
/// and the lens says where the selection will land before the finger lifts.
///
/// Below iOS 26 — the deployment floor is still 16.4 — it falls back to the
/// system segmented control, so the screen keeps a familiar and accessible
/// switcher on older systems rather than an unblurred imitation.
///
/// Both branches keep `identifier` on the switcher and expose each choice as a
/// button labelled with its title, so callers and UI tests address the control
/// the same way on either OS.
struct GlassSegmentedPicker<Value: Hashable>: View {
    private let title: String
    private let options: [GlassPickerOption<Value>]
    @Binding private var selection: Value
    private let identifier: String

    @Namespace private var selectionNamespace
    /// The segment the lens is over, or `nil` when the bar is idle.
    @State private var dragIndex: Int?

    init(
        _ title: String,
        options: [GlassPickerOption<Value>],
        selection: Binding<Value>,
        identifier: String
    ) {
        self.title = title
        self.options = options
        self._selection = selection
        self.identifier = identifier
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            glassBar
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier)
        } else {
            fallbackPicker
        }
    }

    private var fallbackPicker: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(identifier)
    }

    /// The committed selection's index, or 0 when the binding holds a value the
    /// bar does not offer.
    private var committedIndex: Int {
        options.firstIndex { $0.value == selection } ?? 0
    }

    /// The segment that should look active: the one under the lens while a
    /// press-and-drag runs, otherwise the committed selection.
    private var activeIndex: Int {
        if let dragIndex, options.indices.contains(dragIndex) {
            return dragIndex
        }
        return committedIndex
    }

    @available(iOS 26.0, *)
    private var glassBar: some View {
        GeometryReader { proxy in
            bar(width: proxy.size.width)
        }
        .frame(height: glassBarHeight)
        .sensoryFeedback(.selection, trigger: activeIndex)
    }

    @available(iOS 26.0, *)
    private func bar(width: CGFloat) -> some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: glassBarGap) {
                ForEach(Array(options.enumerated()), id: \.element.value) { index, option in
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            selection = option.value
                        }
                    } label: {
                        segmentLabel(option, index: index)
                    }
                    .buttonStyle(.plain)
                    .background {
                        if index == committedIndex {
                            Capsule()
                                .fill(Color.primary.opacity(0.12))
                                .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                        }
                    }
                    .accessibilityAddTraits(index == committedIndex ? .isSelected : [])
                }
            }
            .padding(glassBarPadding)
            .frame(width: max(width, 1), height: glassBarHeight)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .overlay {
            if let dragIndex {
                lens(index: dragIndex, width: width)
                    .transition(.scale(scale: 0.72).combined(with: .opacity))
            }
        }
        .simultaneousGesture(pressAndDrag(width: width))
    }

    /// The lens that rides over the bar while the finger is down: a glass
    /// capsule with a magnified copy of the labels clipped to its shape.
    @available(iOS 26.0, *)
    private func lens(index: Int, width: CGFloat) -> some View {
        let segWidth = segmentWidth(width: width)
        let centerX = segmentCenterX(index, width: width)
        let lensWidth = segWidth + 12
        let lensHeight = glassBarHeight - 6
        let dx = centerX - width / 2
        return ZStack {
            Capsule()
                .fill(.clear)
                .frame(width: lensWidth, height: lensHeight)
                .glassEffect(.regular, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .offset(x: dx)
            // Scaled about the lens centre, then clipped to the lens: the text
            // under the finger grows in place instead of sliding around.
            labelRow(width: width)
                .scaleEffect(
                    lensMagnification,
                    anchor: UnitPoint(x: centerX / max(width, 1), y: 0.5)
                )
                .mask {
                    Capsule()
                        .frame(width: lensWidth, height: lensHeight)
                        .offset(x: dx)
                }
            Capsule()
                .strokeBorder(Color.white.opacity(0.38), lineWidth: 0.6)
                .frame(width: lensWidth, height: lensHeight)
                .offset(x: dx)
        }
        .frame(width: max(width, 1), height: glassBarHeight)
        .allowsHitTesting(false)
    }

    /// A hit-test-free copy of the segments, laid out exactly like the bar so
    /// the magnified copy lines up with what it magnifies.
    private func labelRow(width: CGFloat) -> some View {
        HStack(spacing: glassBarGap) {
            ForEach(Array(options.enumerated()), id: \.element.value) { index, option in
                segmentLabel(option, index: index)
            }
        }
        .padding(glassBarPadding)
        .frame(width: max(width, 1), height: glassBarHeight)
    }

    private func segmentLabel(_ option: GlassPickerOption<Value>, index: Int) -> some View {
        let isActive = index == activeIndex
        return Text(option.label)
            .font(.subheadline.weight(isActive ? .semibold : .regular))
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, minHeight: 32)
            .contentShape(Capsule())
    }

    /// Hold the bar, then slide: the lens rides the finger segment by segment
    /// and the selection lands where the lens is when the finger lifts.
    /// Attached as a simultaneous gesture so a plain tap still reaches the
    /// segment's button.
    @available(iOS 26.0, *)
    private func pressAndDrag(width: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.22)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                switch value {
                case .first(true):
                    // The hold registered but the finger has not moved yet:
                    // lift the lens over the current selection so the bar
                    // answers the press before any dragging happens.
                    guard dragIndex == nil else { return }
                    withAnimation(.snappy(duration: 0.18)) {
                        dragIndex = committedIndex
                    }
                case .second(true, let drag?):
                    let index = segmentIndex(atX: drag.location.x, width: width)
                    guard index != dragIndex else { return }
                    withAnimation(.snappy(duration: 0.18)) {
                        dragIndex = index
                    }
                default:
                    break
                }
            }
            .onEnded { _ in
                // Commit from the segment the lens was last over rather than
                // from the end payload: a cancelled sequence still reports
                // where the lens sat, and dropping that made a drag look like
                // it did nothing at all.
                guard let hovered = dragIndex, options.indices.contains(hovered) else {
                    withAnimation(.snappy(duration: 0.2)) { dragIndex = nil }
                    return
                }
                withAnimation(.snappy(duration: 0.22)) {
                    selection = options[hovered].value
                    dragIndex = nil
                }
            }
    }

    /// Width of one segment inside the bar, mirroring its padding and gaps.
    private func segmentWidth(width: CGFloat) -> CGFloat {
        let count = max(options.count, 1)
        let content = max(width - glassBarPadding * 2, 1)
        let gaps = CGFloat(count - 1) * glassBarGap
        return max((content - gaps) / CGFloat(count), 1)
    }

    /// Horizontal centre of a segment, in the bar's own coordinate space.
    private func segmentCenterX(_ index: Int, width: CGFloat) -> CGFloat {
        let segWidth = segmentWidth(width: width)
        return glassBarPadding + CGFloat(index) * (segWidth + glassBarGap) + segWidth / 2
    }

    /// Maps a point in the bar to a segment, mirroring the 3 pt padding and the
    /// 2 pt gap the segments are laid out with.
    private func segmentIndex(atX x: CGFloat, width: CGFloat) -> Int {
        let count = options.count
        guard count > 0 else { return 0 }
        let content = max(width - glassBarPadding * 2, 1)
        let gaps = CGFloat(count - 1) * glassBarGap
        let segment = max((content - gaps) / CGFloat(count), 1)
        let local = min(max(x - glassBarPadding, 0), content - 0.5)
        let raw = Int(local / (segment + glassBarGap))
        return min(max(raw, 0), count - 1)
    }
}
