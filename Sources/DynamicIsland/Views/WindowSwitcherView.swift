import SwiftUI

/// The Alt+Tab overlay: a dark, rounded panel centred on screen holding a GRID of
/// window cells (thumbnail-or-icon + title), the selected one ringed in the accent
/// colour. Too many to fit a row WRAP onto further rows (no horizontal scrolling).
/// Driven by the keyboard (`selectedIndex`) and by the mouse — hovering a cell
/// highlights it, clicking it focuses that window, clicking off the grid dismisses.
struct WindowSwitcherView: View {
    @ObservedObject var switcher: WindowSwitcher

    private let accent = Palette.blue
    private let cellWidth: CGFloat = 224
    private let cellSpacing: CGFloat = 14
    private let rowSpacing: CGFloat = 16
    private let outerPadding: CGFloat = 20
    private let thumbHeight: CGFloat = 116
    private let maxColumns = 6

    var body: some View {
        GeometryReader { geo in
            let cols = columns(availableWidth: geo.size.width)
            ZStack {
                if switcher.isActive {
                    // A click anywhere off the grid dismisses (also a mouse escape
                    // hatch if the overlay is ever left up).
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { switcher.cancel() }

                    // No transition/animation on open: the grid appears instantly so
                    // there's zero lag between Option+Tab and interacting with it.
                    card(columns: cols)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // Report the grid width to the switcher so Up/Down can move by a row.
            .onChange(of: cols) { switcher.setColumns($0) }
            .onChange(of: switcher.isActive) { active in if active { switcher.setColumns(cols) } }
        }
    }

    /// Columns: as many as fit the screen, capped at `maxColumns` and the window
    /// count. Remaining windows wrap onto the next row.
    private func columns(availableWidth: CGFloat) -> Int {
        let fit = max(1, Int((availableWidth - 120) / (cellWidth + cellSpacing)))
        return max(1, min(switcher.windows.count, min(maxColumns, fit)))
    }

    private func card(columns cols: Int) -> some View {
        let gridColumns = Array(
            repeating: GridItem(.fixed(cellWidth), spacing: cellSpacing, alignment: .top),
            count: cols)
        let cardWidth = CGFloat(cols) * cellWidth
            + CGFloat(cols - 1) * cellSpacing + outerPadding * 2

        return LazyVGrid(columns: gridColumns, alignment: .leading, spacing: rowSpacing) {
            ForEach(Array(switcher.windows.enumerated()), id: \.element.id) { index, window in
                cell(window, selected: index == switcher.selectedIndex)
            }
        }
        .padding(outerPadding)
        .frame(width: cardWidth)
        .background(
            RoundedRectangle(cornerRadius: Radius.popup, style: .continuous)
                .fill(Palette.background.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.popup, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: 1)
        )
        .shellShadow()
    }

    private func cell(_ window: WindowInfo, selected: Bool) -> some View {
        VStack(spacing: Spacing.lg) {
            HStack(spacing: Spacing.sm) {
                if let icon = window.icon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                }
                Text(window.displayTitle)
                    .font(Typography.caption)
                    .foregroundStyle(selected ? Palette.textPrimary : Palette.textHigh)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            ZStack {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(Palette.surfaceSubtle)
                if let thumb = window.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                } else if let icon = window.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 72)
                        .opacity(0.9)
                }
            }
            .frame(height: thumbHeight)
            .frame(maxWidth: .infinity)
        }
        .padding(Spacing.lg)
        .frame(width: cellWidth)
        .background(
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .fill(selected ? accent.opacity(0.20) : Palette.surfaceSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .strokeBorder(selected ? accent : .clear, lineWidth: 3)
        )
        .contentShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .onHover { hovering in if hovering { switcher.select(window) } }
        .onTapGesture { switcher.choose(window) }
    }
}
