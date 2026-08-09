import SwiftUI

/// A SecureField with an eye button that toggles the text visible — for keys
/// the user pastes and needs to verify (fleet keys, join keys). Plain
/// SecureFields made key typos undiagnosable (smart punctuation mangled a
/// pasted fleet key once and nobody could see it).
///
/// Matches the trailing-aligned mono style of the form rows it lives in.
/// Reveal state is ephemeral: always starts hidden, never persisted.
struct RevealableSecureField: View {
    let placeholder: String
    @Binding var text: String
    let alignment: TextAlignment
    @State private var revealed = false
    @FocusState private var focused: Bool

    init(_ placeholder: String, text: Binding<String>, alignment: TextAlignment = .trailing) {
        self.placeholder = placeholder
        self._text = text
        self.alignment = alignment
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .font(.mono(12))
            .foregroundStyle(Color.consoleText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .multilineTextAlignment(alignment)
            .focused($focused)

            Button {
                // Keep focus across the SecureField/TextField swap so the
                // keyboard doesn't dismiss mid-edit.
                let wasFocused = focused
                revealed.toggle()
                if wasFocused {
                    DispatchQueue.main.async { focused = true }
                }
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.consoleDim)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealed ? "Hide value" : "Show value")
        }
    }
}
