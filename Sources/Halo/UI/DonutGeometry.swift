import CoreGraphics
import Foundation

/// Layout constants and math for the donut. All values in points, relative to
/// the donut center (which sits under the cursor at open time).
struct DonutGeometry {
    var iconSize: CGFloat = 60
    var ringRadius: CGFloat = 104   // distance from center to each icon's center
    var holeRadius: CGFloat = 58    // inside this = neutral (the cursor's home)
    var outerRadius: CGFloat = 150  // beyond this (toward an icon) = into the previews
    var floatOffset: CGFloat = 18   // how far the hovered icon pops outward
    var bandThickness: CGFloat = 92 // visual thickness of the glass ring

    var previewSize: CGSize = CGSize(width: 240, height: 150)
    var previewGap: CGFloat = 14    // distance from ring edge to the preview stack
    var stackPeek: CGFloat = 10     // offset between stacked (un-fanned) cards
    var fanSpacing: CGFloat = 16    // gap between fanned cards

    /// Position of icon `i` of `n`, placed clockwise starting at the top.
    /// `angleOffset` lets the no-ring mode push neighbors away from the hovered
    /// icon.
    func iconCenter(index i: Int, count n: Int, donutCenter c: CGPoint,
                    floated: Bool, angleOffset: CGFloat = 0) -> CGPoint {
        let angle = self.angle(index: i, count: n) + angleOffset
        let r = ringRadius + (floated ? floatOffset : 0)
        return CGPoint(x: c.x + r * cos(angle), y: c.y + r * sin(angle))
    }

    /// Angle (radians, SwiftUI/top-left space) for icon `i`. 0 index = straight up.
    func angle(index i: Int, count n: Int) -> CGFloat {
        guard n > 0 else { return -.pi / 2 }
        return -.pi / 2 + (2 * .pi) * CGFloat(i) / CGFloat(n)
    }

    /// Outward unit direction for icon `i` (from donut center toward the icon).
    func outwardDirection(index i: Int, count n: Int) -> CGVector {
        let a = angle(index: i, count: n)
        return CGVector(dx: cos(a), dy: sin(a))
    }
}

/// What the cursor is currently pointing at, derived purely from geometry.
enum HoverTarget: Equatable {
    case neutral                       // in the hole / nothing selected
    case icon(Int)                     // hovering app slot i (stack shown)
    case fanned(app: Int, window: Int?) // moved onto the previews (fanned out)
}
