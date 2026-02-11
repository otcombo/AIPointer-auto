import Foundation

enum PointerState: Equatable {
    case idle
    case input
    case thinking
    case responding(text: String)
    case response(text: String)

    var isFixed: Bool {
        switch self {
        case .idle: return false
        default: return true
        }
    }
}
