import SwiftUI

/// The window previews for the selected app: a stacked deck when hovering the
/// icon, fanned out into a readable row when the cursor moves onto them.
/// Transitions animate via the spring-wrapped hover update in DonutView.
struct PreviewStackView: View {
    let model: SwitcherViewModel
    let appIndex: Int

    private var isFanned: Bool { model.fannedAppIndex == appIndex }

    private var selectedWindow: Int? {
        if case .fanned(let app, let w) = model.target, app == appIndex { return w }
        return nil
    }

    var body: some View {
        let layout = model.previewLayout(appIndex: appIndex, fanned: isFanned)
        ZStack {
            ForEach(layout) { card in
                PreviewCardView(model: model,
                                card: card,
                                highlighted: selectedWindow == card.id)
                    .position(card.center)
                    .zIndex(card.z)
            }
        }
    }
}

/// One window preview card: a live thumbnail (or icon fallback) on glass.
struct PreviewCardView: View {
    let model: SwitcherViewModel
    let card: PreviewCardLayout
    let highlighted: Bool

    var body: some View {
        let a = model.appearance
        let size = model.geometry.previewSize
        let shape = RoundedRectangle(cornerRadius: a.previewCornerRadius, style: .continuous)

        // Each pane is its own independent glass card (no connection to the
        // bulge): glass backing + the window screenshot inset so the glass frame
        // shows + border + shadow.
        content
            .frame(width: size.width - 6, height: size.height - 6)
            .clipShape(RoundedRectangle(cornerRadius: max(0, a.previewCornerRadius - 3), style: .continuous))
            .frame(width: size.width, height: size.height)
            .background(Color.clear.donutGlass(a.paneGlass(), in: shape))
            .overlay(
                shape.stroke(highlighted ? Color.accentColor : a.borderColor,
                             lineWidth: highlighted ? max(2, a.borderWidth + 1.5) : a.borderWidth)
            )
            .scaleEffect(card.scale * (highlighted ? 1.04 : 1.0))
            .rotationEffect(card.rotation)
            .shadow(color: .black.opacity(highlighted ? a.shadowOpacity + 0.1 : a.shadowOpacity),
                    radius: highlighted ? a.shadowRadius * 1.6 : a.shadowRadius, y: a.shadowY)
    }

    @ViewBuilder
    private var content: some View {
        if let thumb = model.thumbs[card.window.id] {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(.black.opacity(0.12))
                if let icon = model.slots.first(where: { $0.id == card.window.pid })?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .opacity(0.85)
                }
                if !card.window.title.isEmpty {
                    VStack {
                        Spacer()
                        Text(card.window.title)
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.4), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(.bottom, 6)
                    }
                }
            }
        }
    }
}
