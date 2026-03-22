import SwiftUI

/// OLED-safe screensaver: mushroom logo drifting through brand colors
/// with green spore particles that float and link — matching the website.
struct ScreenSaverView: View {
    let onTap: () -> Void

    @State private var logoPosition = CGPoint(x: 0.5, y: 0.5)
    @State private var logoScale: CGFloat = 1.0
    @State private var spores: [Spore] = []

    // Brand logo assets to crossfade
    private static let logoAssets = [
        "MycellmLogo-red", "MycellmLogo-green", "MycellmLogo-blue",
        "MycellmLogo-gold", "MycellmLogo-purple",
    ]
    private static let brandColors: [Color] = [
        .computeRed, .sporeGreen, .relayBlue, .ledgerGold, .poisonPurple,
    ]

    // Spore green from website: #4ADE80
    private static let sporeGlow = Color(red: 74/255, green: 222/255, blue: 128/255)

    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    // Logo drift
    @State private var velocityX: CGFloat = 0.0008
    @State private var velocityY: CGFloat = 0.0006
    @State private var zoomPhase: Double = 0.0

    // Color transition
    @State private var colorIndex: Int = 0
    @State private var colorProgress: Double = 0.0

    // Connection line distance threshold (normalized 0-1 coords)
    private let linkThreshold: CGFloat = 0.12

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                // Draw connection lines between nearby spores
                for i in 0..<spores.count {
                    for j in (i+1)..<spores.count {
                        let dx = spores[i].x - spores[j].x
                        let dy = spores[i].y - spores[j].y
                        let dist = sqrt(dx * dx + dy * dy)
                        if dist < linkThreshold {
                            let alpha = Double(1.0 - dist / linkThreshold) * 0.25
                            var path = Path()
                            path.move(to: CGPoint(x: spores[i].x * size.width, y: spores[i].y * size.height))
                            path.addLine(to: CGPoint(x: spores[j].x * size.width, y: spores[j].y * size.height))
                            context.stroke(path, with: .color(Self.sporeGlow.opacity(alpha)), lineWidth: 0.5)
                        }
                    }
                }

                // Draw spores
                for spore in spores {
                    let pulsedRadius = max(0.3, spore.radius + CGFloat(sin(spore.phase)) * 0.8)
                    let pulsedAlpha = 0.5 + sin(spore.phase) * 0.3
                    let rect = CGRect(
                        x: spore.x * size.width - pulsedRadius,
                        y: spore.y * size.height - pulsedRadius,
                        width: pulsedRadius * 2,
                        height: pulsedRadius * 2
                    )
                    context.fill(Circle().path(in: rect), with: .color(Self.sporeGlow.opacity(pulsedAlpha)))
                }
            }

            // Logo overlay — crossfade colored mushrooms
            ZStack {
                ForEach(Array(Self.logoAssets.enumerated()), id: \.offset) { idx, asset in
                    Image(asset)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 140, height: 140)
                        .opacity(logoOpacity(for: idx))
                }
            }
            .scaleEffect(logoScale)
            .position(
                x: logoPosition.x * geo.size.width,
                y: logoPosition.y * geo.size.height
            )
            .shadow(color: currentColor.opacity(0.5), radius: 24)

            // Invisible layer to capture taps
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onTap() }
                .onAppear { seedSpores() }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .onReceive(timer) { _ in tick() }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - Tick

    private func tick() {
        // Move logo — gentle drift, bounce off edges
        logoPosition.x += velocityX
        logoPosition.y += velocityY

        let margin: CGFloat = 0.1
        if logoPosition.x < margin || logoPosition.x > 1.0 - margin {
            velocityX *= -1
            velocityY += CGFloat.random(in: -0.0002...0.0002)
        }
        if logoPosition.y < margin || logoPosition.y > 1.0 - margin {
            velocityY *= -1
            velocityX += CGFloat.random(in: -0.0002...0.0002)
        }
        velocityX = clamp(velocityX, -0.002, 0.002)
        velocityY = clamp(velocityY, -0.002, 0.002)

        // Zoom breathe
        zoomPhase += 0.003
        logoScale = 1.0 + 0.15 * CGFloat(sin(zoomPhase))

        // Color cycle (~8s per color)
        colorProgress += 1.0 / (30.0 * 8.0)
        if colorProgress >= 1.0 {
            colorProgress = 0.0
            colorIndex = (colorIndex + 1) % Self.logoAssets.count
        }

        // Move spores — gassy float, bounce off edges (matching website)
        for i in spores.indices {
            spores[i].x += spores[i].vx
            spores[i].y += spores[i].vy

            if spores[i].x < 0 || spores[i].x > 1 { spores[i].vx *= -1 }
            if spores[i].y < 0 || spores[i].y > 1 { spores[i].vy *= -1 }

            spores[i].phase += spores[i].phaseSpeed
        }
    }

    // MARK: - Logo crossfade

    private func logoOpacity(for index: Int) -> Double {
        let next = (colorIndex + 1) % Self.logoAssets.count
        if index == colorIndex { return 1.0 - colorProgress }
        if index == next { return colorProgress }
        return 0.0
    }

    private var currentColor: Color {
        Self.brandColors[colorIndex]
    }

    // MARK: - Spore setup

    private func seedSpores() {
        let count = min(Int(UIScreen.main.bounds.width / 16), 90)
        spores = (0..<count).map { _ in
            Spore(
                x: CGFloat.random(in: 0...1),
                y: CGFloat.random(in: 0...1),
                vx: CGFloat.random(in: -0.5...0.5) * 0.001,
                vy: CGFloat.random(in: -0.5...0.5) * 0.001,
                radius: CGFloat.random(in: 0.5...2.5),
                phase: Double.random(in: 0...(Double.pi * 2)),
                phaseSpeed: 0.012
            )
        }
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), hi)
    }
}

// MARK: - Spore

struct Spore: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat
    var vy: CGFloat
    var radius: CGFloat
    var phase: Double
    var phaseSpeed: Double
}
