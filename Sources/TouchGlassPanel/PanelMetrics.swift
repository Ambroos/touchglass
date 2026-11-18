import AppKit

public enum PanelMetrics {
    /// The visible panel. Fixed for every state.
    public static let size = CGSize(width: 320, height: 264)
    public static let cornerRadius: CGFloat = 26
    /// Transparent room around the panel inside the window for the glass's own edge effects and the entrance spring.
    /// The window never resizes; the panel animates inside it.
    public static let margin: CGFloat = 64
    public static let windowSize = CGSize(width: size.width + 2 * margin, height: size.height + 2 * margin)

    /// The smoke over the clear glass: a warm near-black. A plain fill reads darker than the
    /// same opacity as a glass tint, so it is lighter than sample H's 65% tint.
    static let smokeColor = NSColor(srgbRed: 0.13, green: 0.12, blue: 0.11, alpha: 0.5)

    static let ringDiameter: CGFloat = 96
    static let ringStroke: CGFloat = 4
    static let ringGlyphSize: CGFloat = 36
}
