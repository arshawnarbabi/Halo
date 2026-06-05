import SwiftUI

/// A single app icon on the ring. Floats outward and scales up when selected;
/// the glass "bump" behind it is drawn (and morphed) by DonutView's glass layer.
/// Motion is driven by the spring-wrapped hover update in DonutView.
struct RingIconView: View {
    let model: SwitcherViewModel
    let index: Int

    private var isSelected: Bool { model.isSelected(appIndex: index) }

    var body: some View {
        if model.slots.indices.contains(index) {
            iconBody
        }
    }

    @ViewBuilder
    private var iconBody: some View {
        let g = model.geometry
        let a = model.appearance
        // When an icon is hovered, neighbors gently push away to make room
        // (applies in both ring and no-ring modes).
        let push = neighborPush()
        let orbit = g.iconCenter(index: index, count: model.count,
                                 donutCenter: model.center, floated: isSelected,
                                 angleOffset: push)
        // Open animation: icons start compressed at the donut center and spring
        // out to their orbit. openProgress is 0 or 1; SwiftUI interpolates the
        // .position / .scale / .opacity between the two endpoints along the spring.
        let p = max(0, model.openProgress)
        let center = CGPoint(x: model.center.x + (orbit.x - model.center.x) * p,
                             y: model.center.y + (orbit.y - model.center.y) * p)
        let openScale = 0.35 + 0.65 * p
        let slot = model.slots[index]

        // Icons get a heavier shadow when the ring is hidden (no backing plate).
        let heavy = a.ringHidden
        let shRadius = a.iconShadowRadius * (heavy ? 1.9 : 1) + (isSelected ? 3 : 0)
        let shOpacity = min(0.9, a.iconShadowOpacity * (heavy ? 1.8 : 1) + (isSelected ? 0.1 : 0))
        let shY = a.iconShadowY * (heavy ? 1.7 : 1)

        Group {
            if let icon = slot.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: g.iconSize, height: g.iconSize)
                    .shadow(color: .black.opacity(shOpacity), radius: shRadius, y: shY)
            } else {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.gray.opacity(0.5))
                    .frame(width: g.iconSize, height: g.iconSize)
                    .overlay(Text(String(slot.name.prefix(1)))
                        .font(.title).bold().foregroundStyle(.white))
            }
        }
        .scaleEffect((isSelected ? a.iconSelectedScale : 1.0) * openScale)
        .opacity(Double(p))
        .position(center)
        .zIndex(isSelected ? 2 : 1)
    }

    /// Subtle, smooth angular shift away from the hovered icon. A continuous
    /// `sin` field (no discontinuity → nothing jumps). Strength is DYNAMIC: it's
    /// how much the natural spacing falls short of the room the hovered icon
    /// wants — so with few icons (already roomy) there's little/no push, and with
    /// many icons (crowded) it pushes more. Scaled by the editor's intensity.
    private func neighborPush() -> CGFloat {
        let count = model.count
        guard count > 2, let s = model.selectedIndex, s != index else { return 0 }
        let g = model.geometry
        let a = model.appearance
        let naturalGap = 2 * .pi / CGFloat(count)
        let wanted = (g.iconSize * (1 + a.iconSelectedScale) / 2 + 14) / g.ringRadius
        let deficit = max(0, wanted - naturalGap)        // 0 when there's already room
        let strength = min(0.24, deficit * CGFloat(a.pushIntensity))
        let delta = g.angle(index: index, count: count) - g.angle(index: s, count: count)
        return strength * sin(delta)
    }
}
