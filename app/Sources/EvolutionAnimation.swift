import AppKit
import SwiftUI

/// The classic evolution sequence, played inside the panel.
///
/// Three phases: the Pokemon becomes a white silhouette that alternates with
/// the silhouette of its next form, faster and faster; the screen flashes; the
/// new form is revealed in colour. The evolution is only committed once this
/// finishes, so the animation is the moment it happens rather than a replay.
struct EvolutionAnimation: View {
    let fromPath: String
    let toPath: String
    let onFinished: () -> Void

    /// Interval between silhouette swaps, in seconds. Shrinking intervals are
    /// what make the sequence feel like it is building to something.
    private static let swapIntervals: [Double] = [
        0.34, 0.34, 0.28, 0.28, 0.22, 0.22, 0.17, 0.17,
        0.13, 0.13, 0.10, 0.10, 0.08, 0.08, 0.06, 0.06,
    ]

    @State private var step = 0
    @State private var showingTarget = false
    @State private var flashing = false
    @State private var revealed = false
    /// Closing the panel mid-sequence must not commit the evolution: the timers
    /// keep firing after the view is gone, so without this the Pokemon would
    /// evolve behind the trainer's back — the exact thing deferring it avoids.
    @State private var abandoned = false

    var body: some View {
        ZStack {
            if revealed {
                AnimatedSprite(path: toPath)
                    .frame(width: 96, height: 96)
                    .transition(.opacity)
            } else if let silhouette = Sprites.silhouette(showingTarget ? toPath : fromPath) {
                Image(nsImage: silhouette)
                    .resizable().interpolation(.none)
                    .scaledToFit()
                    .frame(width: 96, height: 96)
            }

            if flashing {
                Circle()
                    .fill(Color.white)
                    .frame(width: 150, height: 150)
                    .blur(radius: 18)
                    .opacity(0.95)
            }
        }
        .frame(width: 120, height: 110)
        .onAppear { advance() }
        .onDisappear { abandoned = true }
    }

    private func advance() {
        guard !abandoned else { return }
        guard step < Self.swapIntervals.count else {
            flash()
            return
        }
        let interval = Self.swapIntervals[step]
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            guard !abandoned else { return }
            showingTarget.toggle()
            step += 1
            advance()
        }
    }

    private func flash() {
        withAnimation(.easeIn(duration: 0.18)) { flashing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.easeOut(duration: 0.3)) {
                flashing = false
                revealed = true
            }
            // Committed only after the reveal, so what the trainer just watched
            // and what the state records are the same event.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard !abandoned else { return }
                onFinished()
            }
        }
    }
}
