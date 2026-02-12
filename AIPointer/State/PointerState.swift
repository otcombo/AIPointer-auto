import Foundation

enum PointerState: Equatable {
    case idle
    case input
    case thinking
    case responding(text: String)
    case response(text: String)

    // Verification code states
    case monitoring              // OTP field detected, watching for code
    case codeReady(code: String) // Code found, displaying before auto-fill

    var isFixed: Bool {
        switch self {
        case .idle, .monitoring, .codeReady:
            return false
        default:
            return true
        }
    }
}
