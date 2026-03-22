import UIKit

/// Pre-warms the keyboard so the first tap is instant.
/// Creates a hidden text field, makes it first responder to
/// trigger keyboard infrastructure loading, then removes it.
enum KeyboardWarmer {
    @MainActor
    static func warm() {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let window = windowScene.windows.first else { return }

        let field = UITextField(frame: .zero)
        field.autocorrectionType = .no
        field.alpha = 0
        window.addSubview(field)
        field.becomeFirstResponder()
        field.resignFirstResponder()
        field.removeFromSuperview()
    }
}
