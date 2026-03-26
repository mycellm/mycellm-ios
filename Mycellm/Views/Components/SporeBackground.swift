import SwiftUI

/// Subtle spore particle background — a dimmed version of the screensaver particles.
/// Uses fewer particles and a slower tick for minimal CPU impact.
struct SporeBackground: View {
    @State private var spores: [Spore] = []
    @State private var seeded = false

    private static let sporeGlow = Color(red: 74/255, green: 222/255, blue: 128/255)
    private let linkThreshold: CGFloat = 0.14
    private let opacity: Double

    init(opacity: Double = 0.2) {
        self.opacity = opacity
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                // Connection lines
                for i in 0..<spores.count {
                    for j in (i+1)..<spores.count {
                        let dx = spores[i].x - spores[j].x
                        let dy = spores[i].y - spores[j].y
                        let dist = sqrt(dx * dx + dy * dy)
                        if dist < linkThreshold {
                            let alpha = Double(1.0 - dist / linkThreshold) * 0.3
                            var path = Path()
                            path.move(to: CGPoint(x: spores[i].x * size.width, y: spores[i].y * size.height))
                            path.addLine(to: CGPoint(x: spores[j].x * size.width, y: spores[j].y * size.height))
                            context.stroke(path, with: .color(Self.sporeGlow.opacity(alpha)), lineWidth: 0.5)
                        }
                    }
                }

                // Spore dots
                for spore in spores {
                    let pulsedRadius = max(0.3, spore.radius + CGFloat(sin(spore.phase)) * 0.5)
                    let pulsedAlpha = 0.4 + sin(spore.phase) * 0.2
                    let rect = CGRect(
                        x: spore.x * size.width - pulsedRadius,
                        y: spore.y * size.height - pulsedRadius,
                        width: pulsedRadius * 2,
                        height: pulsedRadius * 2
                    )
                    context.fill(Circle().path(in: rect), with: .color(Self.sporeGlow.opacity(pulsedAlpha)))
                }
            }
            .opacity(opacity)
            .onAppear {
                guard !seeded else { return }
                seeded = true
                // Fewer particles than screensaver for perf
                let count = min(Int(geo.size.width / 24), 40)
                spores = (0..<count).map { _ in
                    Spore(
                        x: CGFloat.random(in: 0...1),
                        y: CGFloat.random(in: 0...1),
                        vx: CGFloat.random(in: -0.3...0.3) * 0.001,
                        vy: CGFloat.random(in: -0.3...0.3) * 0.001,
                        radius: CGFloat.random(in: 0.5...2.0),
                        phase: Double.random(in: 0...(Double.pi * 2)),
                        phaseSpeed: 0.008
                    )
                }
            }
            .task {
                // ~15 fps tick — half the screensaver rate
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(66))
                    guard !Task.isCancelled else { break }
                    for i in spores.indices {
                        spores[i].x += spores[i].vx
                        spores[i].y += spores[i].vy
                        if spores[i].x < 0 || spores[i].x > 1 { spores[i].vx *= -1 }
                        if spores[i].y < 0 || spores[i].y > 1 { spores[i].vy *= -1 }
                        spores[i].phase += spores[i].phaseSpeed
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
