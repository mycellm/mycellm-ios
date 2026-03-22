import SwiftUI

/// Animated splash: fast color-cycling mushroom with boot sequence text.
struct SplashView: View {
    @State private var colorIndex = 0
    @State private var bootLines: [String] = []
    @State private var bootPhase = 0

    private static let logos = [
        "MycellmLogo-red", "MycellmLogo-green", "MycellmLogo-blue",
        "MycellmLogo-gold", "MycellmLogo-purple",
    ]

    private static let bootMessages = [
        "initializing identity…",
        "generating device keypair",
        "loading keychain",
        "protocol v1 ready",
        "scanning models directory",
        "metal backend available",
        "node service starting",
        "ready",
    ]

    // Fast cycle: ~12fps color swap
    private let colorTimer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()
    private let bootTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color(red: 10/255, green: 10/255, blue: 10/255)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Color-cycling mushroom
                ZStack {
                    ForEach(Array(Self.logos.enumerated()), id: \.offset) { idx, logo in
                        Image(logo)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80, height: 80)
                            .opacity(idx == colorIndex ? 1 : 0)
                    }
                }

                Spacer()

                // Boot sequence text
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(bootLines.enumerated()), id: \.offset) { idx, line in
                        HStack(spacing: 4) {
                            Text(">")
                                .foregroundStyle(Color(red: 74/255, green: 222/255, blue: 128/255).opacity(0.5))
                            Text(line)
                                .foregroundStyle(idx == bootLines.count - 1
                                    ? Color(red: 74/255, green: 222/255, blue: 128/255)
                                    : Color(white: 0.4))
                        }
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 100, alignment: .bottom)
                .clipped()
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
        .onReceive(colorTimer) { _ in
            colorIndex = (colorIndex + 1) % Self.logos.count
        }
        .onReceive(bootTimer) { _ in
            if bootPhase < Self.bootMessages.count {
                bootLines.append(Self.bootMessages[bootPhase])
                bootPhase += 1
                if bootLines.count > 6 {
                    bootLines.removeFirst()
                }
            }
        }
    }
}
