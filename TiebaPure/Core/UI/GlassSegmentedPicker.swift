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

/// The section switcher used at the top of the feed, messages, favorites,
/// history and search screens.
///
/// On iOS 26 and later it is built out of Liquid Glass itself, not imitated:
/// the bar is one `.glassEffect(.regular)` capsule and the selected segment is a
/// second, tinted `.interactive()` glass capsule that rides above the first and
/// slides between segments. Both are plain Apple glass — there is no hand-drawn
/// capsule, no hand-made blur and no hand-rolled magnification. The knob is a
/// sibling of the container rather than a child, because glass placed inside a
/// `GlassEffectContainer` merges with its neighbours and a knob drawn inside
/// the bar would dissolve into the bar's own shape instead of reading as raised.
///
/// The whole bar is one drag surface instead of a row of buttons. A `DragGesture`
/// with no minimum distance answers a tap and a drag with the same recogniser,
/// and its position is held in `@GestureState`, which SwiftUI resets by itself
/// when the touch ends or is cancelled — so the knob cannot be left stranded
/// under the finger and the labels cannot be left styled as if a press were
/// still running. The segment labels only change weight for the committed
/// selection, never for a hovered one, for the same reason.
///
/// What this cannot do: the system tab bar's long-press lens refracts and
/// magnifies whatever is underneath it. That is a private effect of `TabView`;
/// no public API exposes it. The nearest public equivalent is what this control
/// does — a raised, tinted, interactive glass element that follows the finger.
///
/// Below iOS 26 — the deployment floor is still 16.4 — it falls back to the
/// system segmented control, so the screen keeps a familiar and accessible
/// switcher on older systems.
///
/// Both branches keep `identifier` on the switcher and expose each choice as a
/// button labelled with its title, so callers and UI tests address the control
/// the same way on either OS.
struct GlassSegmentedPicker<Value: Hashable>: View {
    private let title: String
    private let options: [GlassPickerOption<Value>]
    @Binding private var selection: Value
    private let identifier: String

    /// Where the finger is while the bar is touched, in the bar's own
    /// coordinates. `@GestureState` clears it automatically when the gesture
    /// ends, so no visual state outlives the touch that produced it.
    @GestureState private var dragX: CGFloat?

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

    @available(iOS 26.0, *)
    private var glassBar: some View {
        GeometryReader { proxy in
            bar(width: proxy.size.width)
        }
        .frame(height: glassBarHeight)
        .sensoryFeedback(.selection, trigger: committedIndex)
    }

    @available(iOS 26.0, *)
    private func bar(width: CGFloat) -> some View {
        GlassEffectContainer(spacing: 0) {
            Color.clear
                .frame(width: max(width, 1), height: glassBarHeight)
                .glassEffect(.regular, in: Capsule())
        }
        .overlay(alignment: .topLeading) {
            selectionKnob(width: width)
        }
        .overlay {
            labelRow(width: width)
        }
        .contentShape(Capsule())
        .gesture(selectOrDrag(width: width))
    }

    /// The raised glass capsule that marks the selection. Tinted so it reads as
    /// distinct from the bar it sits on, and `.interactive()` so the glass
    /// itself answers the touch instead of waiting for a colour change.
    @available(iOS 26.0, *)
    private func selectionKnob(width: CGFloat) -> some View {
        Capsule()
            .fill(.clear)
            .frame(
                width: segmentWidth(width: width),
                height: glassBarHeight - glassBarPadding * 2
            )
            .glassEffect(
                .regular.tint(Color.accentColor.opacity(0.45)).interactive(),
                in: Capsule()
            )
            .offset(x: knobLeadingX(width: width), y: glassBarPadding)
            .allowsHitTesting(false)
    }

    /// Leading edge of the knob: the finger's position while touched, clamped so
    /// the knob stays inside the bar, otherwise the committed segment.
    private func knobLeadingX(width: CGFloat) -> CGFloat {
        let segWidth = segmentWidth(width: width)
        let half = segWidth / 2
        let lowest = glassBarPadding + half
        let highest = max(width - glassBarPadding - half, lowest)
        guard let dragX else {
            return glassBarPadding + CGFloat(committedIndex) * (segWidth + glassBarGap)
        }
        return min(max(dragX, lowest), highest) - half
    }

    private func labelRow(width: CGFloat) -> some View {
        HStack(spacing: glassBarGap) {
            ForEach(Array(options.enumerated()), id: \.element.value) { index, option in
                segmentLabel(option, index: index)
            }
        }
        .padding(glassBarPadding)
        .frame(width: max(width, 1), height: glassBarHeight)
    }

    /// Weight and colour follow the committed selection only. Reading them from
    /// the touch state is what used to leave a hovered label bold for good.
    private func segmentLabel(_ option: GlassPickerOption<Value>, index: Int) -> some View {
        let isSelected = index == committedIndex
        return Text(option.label)
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, minHeight: 32)
            .accessibilityElement()
            .accessibilityLabel(option.label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction { selection = option.value }
    }

    /// One recogniser for both gestures: a tap lands on the segment under the
    /// finger, and a press that slides repositions the knob as it goes, so the
    /// release commits whatever the knob is over. Because nothing else competes
    /// for the touch, `onEnded` always runs and the selection always follows.
    @available(iOS 26.0, *)
    private func selectOrDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($dragX) { value, state, _ in
                state = value.location.x
            }
            .onEnded { value in
                let index = segmentIndex(atX: value.location.x, width: width)
                guard options.indices.contains(index) else { return }
                guard options[index].value != selection else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    selection = options[index].value
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

    /// Maps a point in the bar to a segment, mirroring the padding and gap the
    /// segments are laid out with.
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
