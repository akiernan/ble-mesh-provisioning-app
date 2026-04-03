import SwiftUI

/// A linear progress bar with a configurable gradient fill and explicit height.
/// Replaces the .scaleEffect(x:1, y:1.5) workaround used on the default style.
struct GradientProgressStyle: ProgressViewStyle {
    let gradient: LinearGradient
    var height: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        let fraction = max(0, min(1, configuration.fractionCompleted ?? 0))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.systemGray5))
                Capsule()
                    .fill(gradient)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: height)
    }
}
