import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Capture thumbnails as DynamicLake image assets. A host holds at most 16 per plugin and forgets them when the plugin
/// disconnects, so slots are reused oldest first, and a thumbnail is sent again only when its file changed (an edit).
///
/// Each one is a square: the lake shows pictures square (`contentMode: fill`), and cropping here decides what stays, the top of
/// a tall screenshot (where its title is) rather than its middle. Videos and GIFs carry a small dark badge, like Quick Access's,
/// so the filmstrip tells them from screenshots.
public final class ThumbnailAssets {
    /// With the blank square, 15 of the host's 16.
    public static let slotCount = 14
    /// The lake's largest picture is 72 pt: 144 px on a Retina screen. Far below the host's 192 KB as a JPEG.
    static let side = 160

    private struct Slot { var id: String; var key: String; var lastUse: Int }
    private var slots: [UUID: Slot] = [:]
    private var useCounter = 0
    private let encode: (String, ShotboltStatus.Capture.Kind) -> Data?
    /// The `asset` commands to send before anything that references them.
    public private(set) var pending: [JSON] = []

    public init(encode: @escaping (String, ShotboltStatus.Capture.Kind) -> Data? = ThumbnailAssets.jpeg(path:kind:)) {
        self.encode = encode
    }

    /// The asset id for the capture's thumbnail, registering it when needed; nil without a thumbnail file.
    public func assetID(for capture: ShotboltStatus.Capture) -> String? {
        guard let path = capture.thumbnail else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        let key = "\(path)|\(modified?.timeIntervalSince1970 ?? 0)"
        useCounter += 1
        if var slot = slots[capture.id], slot.key == key {
            slot.lastUse = useCounter
            slots[capture.id] = slot
            return slot.id
        }
        guard let data = encode(path, capture.kind) else { return nil }
        let id = slots[capture.id]?.id ?? freeSlotID()
        slots[capture.id] = Slot(id: id, key: key, lastUse: useCounter)
        pending.append(["schemaVersion": pluginSchemaVersion, "type": "asset",
                        "asset": ["id": id, "mimeType": "image/jpeg", "base64Data": data.base64EncodedString()]])
        return id
    }

    /// A plain dark square, registered once: what a picture that is not written yet sits on, so the filmstrip keeps its rhythm.
    public func blankID() -> String {
        if !blankSent, let data = Self.blankJPEG() {
            blankSent = true
            pending.append(["schemaVersion": pluginSchemaVersion, "type": "asset",
                            "asset": ["id": Self.blankAssetID, "mimeType": "image/jpeg", "base64Data": data.base64EncodedString()]])
        }
        return Self.blankAssetID
    }

    static let blankAssetID = "blank"
    private var blankSent = false

    static func blankJPEG() -> Data? {
        guard let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Hands over the `asset` commands collected since the last call.
    public func takePending() -> [JSON] {
        defer { pending.removeAll() }
        return pending
    }

    private func freeSlotID() -> String {
        let used = Set(slots.values.map(\.id))
        if let free = (0..<Self.slotCount).map({ "thumb-\($0)" }).first(where: { !used.contains($0) }) { return free }
        let oldest = slots.min { $0.value.lastUse < $1.value.lastUse }!
        slots[oldest.key] = nil
        return oldest.value.id
    }

    /// A square JPEG of the PNG thumbnail Shotbolt wrote. Transparent window shots get a dark backdrop, like the notch.
    public static func jpeg(path: String, kind: ShotboltStatus.Capture.Kind) -> Data? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, width > 0, height > 0 else { return nil }
        // Decode just big enough that the short side fills the square.
        let longest = (Double(side) * max(width, height) / min(width, height)).rounded(.up)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: min(longest, 2048),
              ] as CFDictionary),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(square)
        let scale = Double(side) / Double(min(image.width, image.height))
        let drawn = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        // Centered across; a tall picture keeps its top (Core Graphics counts y from the bottom).
        let y = kind == .screenshot && drawn.height > drawn.width ? Double(side) - drawn.height : (Double(side) - drawn.height) / 2
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (Double(side) - drawn.width) / 2, y: y, width: drawn.width, height: drawn.height))
        if kind == .video || kind == .gif { drawBadge(kind, in: context) }
        guard let flat = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// A dark capsule in the bottom-left corner with a play triangle (video) or "GIF", sized for the 52 pt filmstrip tile.
    static func drawBadge(_ kind: ShotboltStatus.Capture.Kind, in context: CGContext) {
        let height = Double(side) * 0.24, inset = Double(side) * 0.08
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "GIF", attributes: [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateUIFontForLanguage(.emphasizedSystem, height * 0.56, nil) as Any,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
        ]))
        let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        let width = kind == .gif ? textWidth + height * 0.7 : height * 1.25
        let badge = CGRect(x: inset, y: inset, width: width, height: height)
        context.addPath(CGPath(roundedRect: badge, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        context.setFillColor(CGColor(gray: 0, alpha: 0.62))
        context.fillPath()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        if kind == .gif {
            context.textPosition = CGPoint(x: badge.midX - textWidth / 2, y: badge.minY + height * 0.3)
            CTLineDraw(line, context)
        } else {
            let triangle = CGMutablePath(), size = height * 0.42
            triangle.move(to: CGPoint(x: badge.midX - size * 0.4, y: badge.midY - size / 2))
            triangle.addLine(to: CGPoint(x: badge.midX - size * 0.4, y: badge.midY + size / 2))
            triangle.addLine(to: CGPoint(x: badge.midX + size * 0.55, y: badge.midY))
            triangle.closeSubpath()
            context.addPath(triangle)
            context.fillPath()
        }
    }
}
