import Foundation

/// Lightweight error carrying a user-facing message.
struct AppError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

extension Result where Failure == AppError {
    static func fail(_ message: String) -> Result {
        .failure(AppError(message: message))
    }
}
