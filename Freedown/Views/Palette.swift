import SwiftUI

/// The colors that tell series apart in the app's charts, always given in this order. Each one has a step for light
/// mode and one for dark mode, and the eight were checked for color blindness side by side in both.
enum Palette {
    private static let slots: [(light: UInt32, dark: UInt32)] = [
        (0x2a78d6, 0x3987e5), (0xeb6834, 0xd95926), (0x1baf7a, 0x199e70), (0xeda100, 0xc98500),
        (0xe87ba4, 0xd55181), (0x008300, 0x008300), (0x6250d6, 0x9085e9), (0xe34948, 0xe66767),
    ]

    static func color(_ slot: Int) -> Color {
        let (light, dark) = slots[slot % slots.count]
        return Color(
            nsColor: NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255,
                    alpha: 1)
            })
    }
}
