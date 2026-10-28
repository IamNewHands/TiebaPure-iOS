import SwiftUI

/// One choice offered by `GlassSegmentedPicker`. A named type rather than a
/// tuple so `ForEach` can key on the value and the call sites stay readable.
struct GlassPickerOption<Value: Hashable> {
    let value: Value
    let label: String

    init(value: Value, label: String) {
        self.value = value
        self.label = label
    }
}

/// The section switcher at the top of the feed, messages, favorites, history and
/// search screens.
///
/// It is the system `Picker` in its segmented style — nothing drawn by hand and
/// no glass imitated in code. On iOS 26 the system segmented control is itself a
/// Liquid Glass element, and the draggable handle it grows on a press is Apple's
/// own behaviour, so using the control is how a screen gets that look and that
/// interaction without guessing at either.
///
/// This type only exists to keep the five call sites and the UI tests addressing
/// the same shape: the same options, the same `selection` binding and the same
/// accessibility identifier the screens already used.
///
/// The type and the file still carry the "glass" name they were given while the
/// control was hand-built; renaming them would mean editing the Xcode project
/// file for no behavioural gain.
struct GlassSegmentedPicker<Value: Hashable>: View {
    private let title: String
    private let options: [GlassPickerOption<Value>]
    @Binding private var selection: Value
    private let identifier: String

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
        Picker(title, selection: $selection) {
            ForEach(options, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(identifier)
    }
}
