import Foundation

enum SSEEvent {
    case status(String)
    case delta(String)
    case done(String)
    case error(String)
}

class ClaudeAPIService: NSObject, URLSessionDataDelegate {
    private var baseURL = ""
    private var authToken = ""
    private var agentId = "main"
    private var messages: [[String: String]] = []
    private var activeSession: URLSession?

    func configure(baseURL: String, authToken: String, agentId: String) {
        // Strip trailing slashes to avoid double-slash in URL path
        var url = baseURL
        while url.hasSuffix("/") { url.removeLast() }
        self.baseURL = url
        self.authToken = authToken
        // Strip "openclaw:" prefix if user included it in the agent ID
        var agent = agentId
        if agent.hasPrefix("openclaw:") { agent = String(agent.dropFirst(9)) }
        self.agentId = agent
    }

    func cancel() {
        activeSession?.invalidateAndCancel()
        activeSession = nil
    }

    func clearHistory() {
        messages = []
    }

    func chat(message: String, conversationId: String?) -> AsyncThrowingStream<SSEEvent, Error> {
        messages.append(["role": "user", "content": message])

        return AsyncThrowingStream { continuation in
            Task {
                guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
                    self.messages.removeLast()
                    continuation.finish(throwing: URLError(.badURL))
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("agent:\(agentId):\(agentId)", forHTTPHeaderField: "x-openclaw-session-key")

                let body: [String: Any] = [
                    "model": "openclaw:\(agentId)",
                    "messages": messages,
                    "stream": true,
                    "user": "aipointer"
                ]
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                self.activeSession?.invalidateAndCancel()
                let session = URLSession(configuration: .default)
                self.activeSession = session

                do {
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        self.messages.removeLast()
                        continuation.finish(throwing: URLError(.badServerResponse))
                        return
                    }

                    if httpResponse.statusCode != 200 {
                        self.messages.removeLast()
                        continuation.yield(.error("HTTP \(httpResponse.statusCode)"))
                        continuation.finish()
                        return
                    }

                    continuation.yield(.status("thinking"))

                    var fullResponse = ""
                    var firstChunk = true

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        if payload == "[DONE]" {
                            break
                        }

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let choice = choices.first,
                              let delta = choice["delta"] as? [String: Any],
                              let content = delta["content"] as? String else {
                            continue
                        }

                        if firstChunk {
                            continuation.yield(.status("responding"))
                            firstChunk = false
                        }

                        fullResponse += content
                        continuation.yield(.delta(content))
                    }

                    self.messages.append(["role": "assistant", "content": fullResponse])
                    continuation.yield(.done("openclaw"))
                    continuation.finish()
                } catch {
                    self.messages.removeLast()
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
