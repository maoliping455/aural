import Foundation

public enum TranscriptionStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case running
    case paused
    case done
    case failed

    public var displayName: String {
        switch self {
        case .pending:
            "未开始"
        case .running:
            "转写中"
        case .paused:
            "已暂停"
        case .done:
            "转写完成"
        case .failed:
            "转写失败"
        }
    }
}
