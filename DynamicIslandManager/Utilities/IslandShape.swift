import SwiftUI

// size and corners of the island in one state, every value animates
struct IslandMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
    var bottomRadius: CGFloat
    var earRadius: CGFloat
}

// one shape from the notch to the open island, hangs from the top edge
// concave ears where it meets the top so it flows out of the notch
struct IslandShape: Shape {
    var metrics: IslandMetrics

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(AnimatablePair(metrics.width, metrics.height), AnimatablePair(metrics.bottomRadius, metrics.earRadius))
        }
        set {
            metrics = IslandMetrics(width: newValue.first.first, height: newValue.first.second,
                                    bottomRadius: newValue.second.first, earRadius: newValue.second.second)
            #if DEBUG
            GrowthStamp.shared.note(width: newValue.first.first)
            #endif
        }
    }

    // continuous corner, a corner of radius r starts this far from it along each edge
    static let cornerReach: CGFloat = 1.52866483

    // centered at the top of rect, one outline so fill, clip and stroke all match
    func path(in rect: CGRect) -> Path {
        let width = max(0, metrics.width)
        let height = max(0, metrics.height)
        guard width > 1, height > 1 else { return Path() }
        let reach = Self.cornerReach
        let r = min(max(0, metrics.bottomRadius), width / (2 * reach), height / reach)
        let k = r * reach
        let e = min(max(0, metrics.earRadius), height - k, width / 4)
        let left = rect.midX - width / 2
        let right = rect.midX + width / 2
        let top = rect.minY
        let bottom = top + height

        var path = Path()
        path.move(to: CGPoint(x: left - e, y: top))
        path.addLine(to: CGPoint(x: right + e, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: top + e), control: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: bottom - k))
        // bottom right, apple's continuous corner as three curves
        path.addCurve(to: CGPoint(x: right - 0.07491100 * r, y: bottom - 0.63149399 * r),
                      control1: CGPoint(x: right, y: bottom - 1.08849296 * r),
                      control2: CGPoint(x: right, y: bottom - 0.86840694 * r))
        path.addCurve(to: CGPoint(x: right - 0.63149399 * r, y: bottom - 0.07491100 * r),
                      control1: CGPoint(x: right - 0.16905899 * r, y: bottom - 0.37282392 * r),
                      control2: CGPoint(x: right - 0.37282392 * r, y: bottom - 0.16905899 * r))
        path.addCurve(to: CGPoint(x: right - k, y: bottom),
                      control1: CGPoint(x: right - 0.86840694 * r, y: bottom),
                      control2: CGPoint(x: right - 1.08849296 * r, y: bottom))
        path.addLine(to: CGPoint(x: left + k, y: bottom))
        // bottom left
        path.addCurve(to: CGPoint(x: left + 0.63149399 * r, y: bottom - 0.07491100 * r),
                      control1: CGPoint(x: left + 1.08849296 * r, y: bottom),
                      control2: CGPoint(x: left + 0.86840694 * r, y: bottom))
        path.addCurve(to: CGPoint(x: left + 0.07491100 * r, y: bottom - 0.63149399 * r),
                      control1: CGPoint(x: left + 0.37282392 * r, y: bottom - 0.16905899 * r),
                      control2: CGPoint(x: left + 0.16905899 * r, y: bottom - 0.37282392 * r))
        path.addCurve(to: CGPoint(x: left, y: bottom - k),
                      control1: CGPoint(x: left, y: bottom - 0.86840694 * r),
                      control2: CGPoint(x: left, y: bottom - 1.08849296 * r))
        path.addLine(to: CGPoint(x: left, y: top + e))
        path.addQuadCurve(to: CGPoint(x: left - e, y: top), control: CGPoint(x: left, y: top))
        path.closeSubpath()
        return path
    }
}
