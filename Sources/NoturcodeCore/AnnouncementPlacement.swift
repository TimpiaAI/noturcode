import CoreGraphics
import Foundation

public enum AnnouncementScreenEdge: Sendable {
    case top
    case bottom
}

public enum AnnouncementPlacement {
    public static func edge(cursor: CGPoint, screenFrame: CGRect) -> AnnouncementScreenEdge {
        cursor.y >= screenFrame.midY ? .top : .bottom
    }

    public static func origin(
        cursor: CGPoint,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        size: CGSize
    ) -> CGPoint {
        let x = min(
            max(cursor.x - size.width / 2, visibleFrame.minX + 22),
            visibleFrame.maxX - size.width - 22
        )
        let y = edge(cursor: cursor, screenFrame: screenFrame) == .top
            ? visibleFrame.maxY - size.height - 30
            : visibleFrame.minY + 42
        return CGPoint(x: x, y: y)
    }
}
