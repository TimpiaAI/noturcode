import Foundation

public enum NotificationRoute {
    public static let sourceKey = "noturcode.source"
    public static let sessionIDKey = "noturcode.sessionID"

    public static func metadata(for key: SessionKey) -> [String: String] {
        [sourceKey: key.source.rawValue, sessionIDKey: key.sessionID]
    }

    public static func sessionKey(source: String?, sessionID: String?) -> SessionKey? {
        guard let source,
              let parsedSource = AgentSource(rawValue: source),
              let sessionID,
              !sessionID.isEmpty else {
            return nil
        }
        return SessionKey(source: parsedSource, sessionID: sessionID)
    }
}
