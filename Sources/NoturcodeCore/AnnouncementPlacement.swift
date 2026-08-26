import CoreGraphics
import Foundation

public enum AnnouncementScreenEdge: Sendable {
    case top
    case bottom
}

public enum AnnouncementPlacement {
    private static let cursorGap: CGFloat = 18

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
        let minimumY = visibleFrame.minY + cursorGap
        let maximumY = visibleFrame.maxY - size.height - cursorGap
        let desiredY: CGFloat
        switch edge(cursor: cursor, screenFrame: screenFrame) {
        case .top:
            // Keep the banner below a top-half cursor so the entrance motion moves toward it.
            desiredY = cursor.y - size.height - cursorGap
        case .bottom:
            // Keep the banner above a bottom-half cursor so it remains visible and clickable.
            desiredY = cursor.y + cursorGap
        }
        let y = min(max(desiredY, minimumY), maximumY)
        return CGPoint(x: x, y: y)
    }
}
