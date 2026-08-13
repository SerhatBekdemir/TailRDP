import Foundation

/// Tokenizes and sanitizes the editable FreeRDP command shown in Connection settings.
/// The command is executed directly with Process, never through a shell.
enum FreeRDPCommandLine {
    static let passwordPlaceholder = "••••••"

    static func tokens(from command: String) -> [String]? {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var tokenStarted = false

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                tokenStarted = true
                continue
            }

            if quote != nil {
                if character == quote {
                    quote = nil
                } else {
                    current.append(character)
                }
                tokenStarted = true
                continue
            }

            switch character {
            case "\\":
                escaping = true
                tokenStarted = true
            case "'", "\"":
                quote = character
                tokenStarted = true
            case " ", "\t", "\n", "\r":
                if tokenStarted {
                    result.append(current)
                    current = ""
                    tokenStarted = false
                }
            default:
                current.append(character)
                tokenStarted = true
            }
        }

        guard !escaping, quote == nil else { return nil }
        if tokenStarted { result.append(current) }
        return result
    }

    static func sanitized(_ command: String) -> String? {
        guard let tokens = tokens(from: command), !tokens.isEmpty else { return nil }
        return tokens
            .map { $0.hasPrefix("/p:") ? "/p:\(passwordPlaceholder)" : $0 }
            .map(quoteIfNeeded)
            .joined(separator: " ")
    }

    static func arguments(from command: String, password: String?) -> [String]? {
        guard var tokens = tokens(from: command), !tokens.isEmpty else { return nil }
        if let first = tokens.first, isExecutable(first) {
            tokens.removeFirst()
        }
        guard !tokens.isEmpty else { return nil }

        var result: [String] = []
        var replacedPassword = false
        for token in tokens {
            if token.hasPrefix("/p:") {
                guard let password, !password.isEmpty else { continue }
                result.append("/p:\(password)")
                replacedPassword = true
            } else {
                result.append(token)
            }
        }

        if let password, !password.isEmpty, !replacedPassword {
            result.append("/p:\(password)")
        }
        return result
    }

    static func validationError(for command: String) -> String? {
        guard let tokens = tokens(from: command) else {
            return "Command line has an unmatched quote or trailing escape."
        }
        guard !tokens.isEmpty else { return "Command line cannot be empty." }

        var arguments = tokens
        if let first = arguments.first, isExecutable(first) {
            arguments.removeFirst()
        }
        guard arguments.contains(where: { $0.hasPrefix("/v:") && $0.count > 3 }) else {
            return "Command line must include a /v:host:port target."
        }
        return nil
    }

    private static func isExecutable(_ token: String) -> Bool {
        token == "sdl-freerdp"
            || token == "xfreerdp"
            || token.hasSuffix("/sdl-freerdp")
            || token.hasSuffix("/xfreerdp")
    }

    private static func quoteIfNeeded(_ token: String) -> String {
        guard !token.isEmpty else { return "''" }
        guard token.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
                || token.contains("'")
                || token.contains("\"")
                || token.contains("\\") else {
            return token
        }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
