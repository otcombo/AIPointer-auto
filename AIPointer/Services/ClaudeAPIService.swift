import Foundation

enum SSEEvent {
    case status(String)
    case delta(String)
    case done(String) // conversation_id
    case error(String)
}

class ClaudeAPIService: NSObject, URLSessionDataDelegate {
    // TODO: Move to settings/keychain
    private var baseURL = "https://claude.otcombo.com"
    private var authToken = ""

    func configure(baseURL: String, authToken: String) {
        self.baseURL = baseURL
        self.authToken = authToken
    }

    func chat(message: String, conversationId: String?) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let url = URL(string: "\(baseURL)/api/chat") else {
                    continuation.finish(throwing: URLError(.badURL))
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                var body: [String: Any] = ["message": message]
                if let conversationId {
                    body["conversation_id"] = conversationId
                }
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                let session = URLSession(configuration: .default)

                do {
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: URLError(.badServerResponse))
                        return
                    }

                    if httpResponse.statusCode != 200 {
                        continuation.yield(.error("HTTP \(httpResponse.statusCode)"))
                        continuation.finish()
                        return
                    }

                    var currentEvent = ""
                    var currentData = ""

                    for try await line in bytes.lines {
                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst(7))
                        } else if line.hasPrefix("data: ") {
                            currentData = String(line.dropFirst(6))

                            // Process event
                            if let data = currentData.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                switch currentEvent {
                                case "status":
                                    if let status = json["status"] as? String {
                                        continuation.yield(.status(status))
                                    }
                                case "delta":
                                    if let text = json["text"] as? String {
                                        continuation.yield(.delta(text))
                                    }
                                case "done":
                                    if let convId = json["conversation_id"] as? String {
                                        continuation.yield(.done(convId))
                                    }
                                case "error":
                                    if let error = json["error"] as? String {
                                        continuation.yield(.error(error))
                                    }
                                default:
                                    break
                                }
                            }

                            currentEvent = ""
                            currentData = ""
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
