import SwiftUI
import AVKit

/// Native AirPlay control. `AVRoutePickerView` is Apple's real AirPlay button
/// and route picker, so this is as native as it gets.
struct AirPlayButton: NSViewRepresentable {
    var tint: NSColor = NSColor.white.withAlphaComponent(0.6)
    var activeTint: NSColor = .white

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.setRoutePickerButtonColor(tint, for: .normal)
        picker.setRoutePickerButtonColor(activeTint, for: .activeHighlighted)
        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        nsView.setRoutePickerButtonColor(tint, for: .normal)
    }
}
