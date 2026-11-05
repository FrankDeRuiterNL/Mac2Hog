#if os(macOS)
import SwiftUI
import Mac2HogCore

/// Text field for seconds that accepts "0.1", "0,10", "1.15" (dot or comma, up to two decimals).
/// The typed text is kept while editing and applied on Return or when the field loses focus.
struct SecondsField: View {
    @Binding var value: Double
    var width: CGFloat = 60
    var minimum: Double = 0

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { isFocused in if !isFocused { commit() } }
            .onChange(of: value) { _ in if !focused { text = SecondsText.format(value) } }
            .onAppear { text = SecondsText.format(value) }
            .help("Seconds, up to two decimals (e.g. 0.1 or 1,15)")
    }

    private func commit() {
        if let v = SecondsText.parse(text) { value = max(minimum, v) }
        text = SecondsText.format(value)
    }
}
#endif
