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

/// The section switcher used at the top of the feed, messages, favorites,
/// history and search screens.
///
/// On iOS 26 and later it draws a real Liquid Glass bar: one glass capsule with
/// a translucent selection capsule sliding inside it. The selection is a plain
/// tinted capsule instead of a second `.glassEffect` because stacking glass on
/// glass turns the selected segment muddy instead of reading as a raised lens.
///
/// The bar answers a press-and-drag the way the system tab bar does: holding it
/// lifts a translucent lens over the segment under the finger and dragging
/// carries the selection along, with a selection haptic per segment. Without
/// that, switching sections meant aiming at a 32 pt target; with it the whole
/// bar is draggable and the lens says where the selection will land before the
/// finger lifts. `.interactive()` gives the glass itself the press response, so
/// the bar reads as liquid rather than as a static frosted panel.
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
    /// The segment a press-and-drag is hovering, or `nil` when the bar is idle.
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

    /// The segment that should look selected: the one under the finger while a
    /// press-and-drag runs, otherwise the committed selection.
    private var activeIndex: Int {
        if let dragIndex, options.indices.contains(dragIndex) {
            return dragIndex
        }
        return options.firstIndex { $0.value == selection } ?? 0
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
            HStack(spacing: 2) {
                ForEach(Array(options.enumerated()), id: \.element.value) { index, option in
                    segment(option, index: index)
                }
            }
            .padding(3)
            .frame(width: max(width, 1), height: glassBarHeight)
            .glassEffect(.regular.interactive(), in: Capsule())
            .simultaneousGesture(pressAndDrag(width: width))
        }
    }

    @available(iOS 26.0, *)
    private func segment(_ option: GlassPickerOption<Value>, index: Int) -> some View {
        let isActive = index == activeIndex
        return Button {
            withAnimation(.snappy(duration: 0.22)) {
                selection = option.value
            }
        } label: {
            Text(option.label)
                .font(.subheadline.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            ZStack {
                if isActive {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                        .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                }
                if dragIndex == index {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .overlay {
                            Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5)
                        }
                        .matchedGeometryEffect(id: "dragLens", in: selectionNamespace)
                }
            }
        }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    /// Hold the bar, then slide: the selection follows the finger segment by
    /// segment and lands where the lens is when the finger lifts. Attached as a
    /// simultaneous gesture so a plain tap still reaches the segment's button.
    @available(iOS 26.0, *)
    private func pressAndDrag(width: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.2)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                let index = segmentIndex(atX: drag.location.x, width: width)
                guard index != dragIndex else { return }
                withAnimation(.snappy(duration: 0.18)) {
                    dragIndex = index
                }
            }
            .onEnded { value in
                guard case .second(true, let drag?) = value,
                      options.indices.contains(segmentIndex(atX: drag.location.x, width: width))
                else {
                    withAnimation(.snappy(duration: 0.18)) { dragIndex = nil }
                    return
                }
                let index = segmentIndex(atX: drag.location.x, width: width)
                // Move the selection and drop the lens in one step, so the
                // capsule stays put instead of snapping back to the old value.
                withAnimation(.snappy(duration: 0.2)) {
                    selection = options[index].value
                    dragIndex = nil
                }
            }
    }

    /// Maps a point in the bar to a segment, mirroring the 3 pt padding and the
    /// 2 pt gap the segments are laid out with.
    private func segmentIndex(atX x: CGFloat, width: CGFloat) -> Int {
        let count = options.count
        guard count > 0 else { return 0 }
        let content = max(width - 6, 1)
        let gaps = CGFloat(count - 1) * 2
        let segment = max((content - gaps) / CGFloat(count), 1)
        let local = min(max(x - 3, 0), content - 0.5)
        let raw = Int(local / (segment + 2))
        return min(max(raw, 0), count - 1)
    }
}
