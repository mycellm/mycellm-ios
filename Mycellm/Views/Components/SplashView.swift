import SwiftUI

/// Animated splash screen: mushroom cycling through brand colors.
struct SplashView: View {
    @State private var colorIndex = 0
    @State private var opacity: Double = 1.0

    private static let logos = [
        "MycellmLogo-red", "MycellmLogo-green", "MycellmLogo-blue",
        "MycellmLogo-gold", "MycellmLogo-purple",
    ]

    private let colorTimer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color(red: 10/255, green: 10/255, blue: 10/255)
                .ignoresSafeArea()

            Image(Self.logos[colorIndex])
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .animation(.easeInOut(duration: 0.25), value: colorIndex)
        }
        .opacity(opacity)
        .onReceive(colorTimer) { _ in
            colorIndex = (colorIndex + 1) % Self.logos.count
        }
    }

    /// Fade out and call completion.
    func dismiss(completion: @escaping () -> Void) {
        withAnimation(.easeOut(duration: 0.4)) {
            opacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            completion()
        }
    }
}
