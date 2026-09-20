import CoreGraphics

public enum PickerPlacement {
    public static func frame(pointer: CGPoint, screen: CGRect, targetCount: Int,
                             hasMessage: Bool, previousOrigin: CGPoint? = nil) -> CGRect {
        let available = screen.insetBy(dx: 16, dy: 16)
        let width = min(max(380, CGFloat(targetCount) * 100 + 36), min(836, available.width))
        let height = min(hasMessage ? 320.0 : 272.0, available.height)
        var origin = previousOrigin ?? CGPoint(x: pointer.x - width / 2, y: pointer.y - height - 12)
        origin.x = max(available.minX, min(origin.x, available.maxX - width))
        origin.y = max(available.minY, min(origin.y, available.maxY - height))
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }
}
