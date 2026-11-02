import NautKit
import SwiftUI

/// One mode's row of built-in themes. The card is the preview: choosing a
/// theme repaints the app, so the row already shows the result.
struct ThemeSection: View {
    let title: String
    let themes: [ThemePalette]
    @Binding var selection: String
    let active: Bool

    var body: some View {
        SettingsGroup(title: title, badge: active ? "— Active" : nil) {
            VStack(alignment: .leading, spacing: ThemePickerMetrics.captionGap) {
                Text("Built-in")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.fgDim)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: ThemePickerMetrics.gap) {
                            ForEach(themes) { theme in
                                ThemeCard(theme: theme, selected: selection == theme.id) {
                                    withAnimation(.snappy(duration: ThemePickerMetrics.selectionDuration)) {
                                        selection = theme.id
                                    }
                                }
                                .id(theme.id)
                            }
                        }
                        // Room for the selection ring, which sits outside the card.
                        .padding(.vertical, 3)
                        .padding(.horizontal, 3)
                    }
                    .scrollIndicators(.hidden)
                    // A saved theme may be off-screen; show what is selected.
                    // Wait for the first layout, or the content size is not
                    // known yet and the scroll lands short.
                    .onAppear {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(30))
                            proxy.scrollTo(selection, anchor: .center)
                        }
                    }
                    .onChange(of: selection) { _, id in
                        withAnimation(.snappy(duration: ThemePickerMetrics.selectionDuration)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
            .padding(ThemePickerMetrics.padding)
        }
    }
}

/// A theme at a glance: the page ink and paper, the cursor and the eight
/// character colours, on the theme's own background.
private struct ThemeCard: View {
    let theme: ThemePalette
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.themeRevision) private var themeRevision

    var body: some View {
        let _ = themeRevision
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                Text(theme.name)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.fg : Theme.fgDim)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: ThemePickerMetrics.hoverDuration), value: hovering)
        .scaleEffect(hovering ? 1.01 : 1)
        .accessibilityLabel("\(theme.name) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Aa")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(color(.fg))
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(theme: theme.cursor))
                    .frame(
                        width: ThemePickerMetrics.cursorWidth,
                        height: ThemePickerMetrics.cursorHeight
                    )
            }

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                ForEach(theme.swatches.indices, id: \.self) { i in
                    Circle()
                        .fill(Color(theme: theme.swatches[i]))
                        .frame(width: 9, height: 9)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(10)
        .frame(
            width: ThemePickerMetrics.cardWidth,
            height: ThemePickerMetrics.previewHeight,
            alignment: .topLeading
        )
        .background(
            color(.bg),
            in: RoundedRectangle(cornerRadius: ThemePickerMetrics.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ThemePickerMetrics.cardRadius, style: .continuous)
                .strokeBorder(color(.edgeTop), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ThemePickerMetrics.cardRadius + 3, style: .continuous)
                .strokeBorder(Color(theme: theme.cursor), lineWidth: selected ? 2 : 0)
                .padding(-3)
        )
        .shadow(color: .black.opacity(hovering ? 0.08 : 0.04), radius: hovering ? 4 : 2, y: 1)
    }

    private func color(_ token: ThemeToken) -> Color {
        Color(theme: theme.color(token)!)
    }
}

enum ThemePickerMetrics {
    // MARK: - Sizing
    static let cardWidth: CGFloat = 140
    static let previewHeight: CGFloat = 86
    static let cardRadius: CGFloat = 9
    static let cursorWidth: CGFloat = 7
    static let cursorHeight: CGFloat = 24
    static let gap: CGFloat = 16
    static let padding: CGFloat = 14
    static let captionGap: CGFloat = 10

    // MARK: - Animation
    static let selectionDuration = 0.15 // fast enough to feel like a direct choice
    static let hoverDuration = 0.12
}
