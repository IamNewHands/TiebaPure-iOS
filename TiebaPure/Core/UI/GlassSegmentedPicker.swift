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

/// The section switcher used at the top of the feed, messages, favorites,
/// history and search screens.
///
/// On iOS 26 and later it draws a real Liquid Glass bar: one glass capsule with
/// a translucent selection capsule sliding inside it. The selection is a plain
/// tinted capsule instead of a second `.glassEffect` because stacking glass on
/// glass turns the selected segment muddy instead of reading as a raised lens.
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

    @available(iOS 26.0, *)
    private var glassBar: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                segment(option)
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: Capsule())
    }

    @available(iOS 26.0, *)
    private func segment(_ option: GlassPickerOption<Value>) -> some View {
        let isSelected = option.value == selection
        return Button {
            guard option.value != selection else { return }
            withAnimation(.snappy(duration: 0.22)) {
                selection = option.value
            }
        } label: {
            Text(option.label)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .matchedGeometryEffect(id: "selection", in: selectionNamespace)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
