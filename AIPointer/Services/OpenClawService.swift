import Foundation
import Cocoa

enum SSEEvent {
    case status(String)
    case delta(String)
    case done(String)
    case error(String)
}

enum APIFormat: String {
    case openai     // OpenClaw /v1/chat/completions (no image support)
    case anthropic  // Anthropic Messages API /v1/messages (supports images)
}

class OpenClawService: NSObject, URLSessionDataDelegate {
    private var baseURL = ""
    private var authToken = ""
    private var agentId = "main"
    private var modelName = "anthropic/claude-sonnet-4-5"
    private var apiFormat: APIFormat = .anthropic
    private var messages: [[String: Any]] = []
    private var activeSession: URLSession?

    func cancel() {
        activeSession?.invalidateAndCancel()
        activeSession = nil
    }

    func configure(baseURL: String, authToken: String, agentId: String, modelName: String = "", apiFormat: APIFormat = .anthropic) {
        self.baseURL = baseURL
        self.authToken = authToken
        self.agentId = agentId
        self.apiFormat = apiFormat
        if !modelName.isEmpty {
            self.modelName = modelName
        }
        NSLog("[API] configured: format=%@ url=%@ model=%@", apiFormat.rawValue, baseURL, self.modelName)
    }

    func clearHistory() {
        messages = []
    }

    /// Convert NSImage to base64-encoded PNG string.
    static func toBase64PNG(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        // If larger than 1MB, scale down and re-encode
        if png.count > 1_048_576 {
            let scale = sqrt(1_048_576.0 / Double(png.count))
            let newWidth = Int(Double(bitmap.pixelsWide) * scale)
            let newHeight = Int(Double(bitmap.pixelsHigh) * scale)

            let resized = NSImage(size: NSSize(width: newWidth, height: newHeight))
            resized.lockFocus()
            image.draw(in: NSRect(x: 0, y: 0, width: newWidth, height: newHeight),
                       from: .zero, operation: .copy, fraction: 1.0)
            resized.unlockFocus()

            if let resizedTiff = resized.tiffRepresentation,
               let resizedBitmap = NSBitmapImageRep(data: resizedTiff),
               let resizedPng = resizedBitmap.representation(using: .png, properties: [:]) {
                return resizedPng.base64EncodedString()
            }
        }

        return png.base64EncodedString()
    }

    func chat(message: String, conversationId: String?, images: [(NSImage, String)] = []) -> AsyncThrowingStream<SSEEvent, Error> {
        switch apiFormat {
        case .openai:
            return chatOpenAI(message: message, conversationId: conversationId, images: images)
        case .anthropic:
            return chatAnthropic(message: message, conversationId: conversationId, images: images)
        }
    }

    // MARK: - OpenAI format (OpenClaw)

    private func chatOpenAI(message: String, conversationId: String?, images: [(NSImage, String)] = []) -> AsyncThrowingStream<SSEEvent, Error> {
        let userMessage: [String: Any]
        if images.isEmpty {
            userMessage = ["role": "user", "content": message]
        } else {
            var content: [[String: Any]] = []
            content.append(["type": "text", "text": message])
            for (image, label) in images {
                content.append(["type": "text", "text": label])
                if let base64 = Self.toBase64PNG(image) {
                    content.append([
                        "type": "image_url",
                        "image_url": ["url": "data:image/png;base64,\(base64)"]
                    ])
                }
            }
            userMessage = ["role": "user", "content": content]
        }
        messages.append(userMessage)

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
                        if payload == "[DONE]" { break }

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

    // MARK: - Anthropic Messages API format

    private func chatAnthropic(message: String, conversationId: String?, images: [(NSImage, String)] = []) -> AsyncThrowingStream<SSEEvent, Error> {
        // Build user message in Anthropic format
        let userMessage: [String: Any]
        if images.isEmpty {
            userMessage = ["role": "user", "content": message]
        } else {
            var content: [[String: Any]] = []
            content.append(["type": "text", "text": message])
            for (image, label) in images {
                content.append(["type": "text", "text": label])
                if let base64 = Self.toBase64PNG(image) {
                    content.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/png",
                            "data": base64
                        ]
                    ])
                }
            }
            userMessage = ["role": "user", "content": content]
        }
        messages.append(userMessage)

        return AsyncThrowingStream { continuation in
            Task {
                guard let url = URL(string: "\(baseURL)/v1/messages") else {
                    self.messages.removeLast()
                    continuation.finish(throwing: URLError(.badURL))
                    return
                }

                NSLog("[Anthropic] POST %@", url.absoluteString)
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(authToken, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                // Convert stored messages: strip image data from history to save tokens
                let apiMessages = self.messages.map { msg -> [String: Any] in
                    guard let content = msg["content"] else { return msg }
                    if content is String { return msg }
                    // For array content, keep images only in the latest message
                    if let arr = content as? [[String: Any]], msg as NSDictionary != self.messages.last! as NSDictionary {
                        let textOnly = arr.filter { ($0["type"] as? String) == "text" }
                        return ["role": msg["role"] as Any, "content": textOnly]
                    }
                    return msg
                }

                let body: [String: Any] = [
                    "model": modelName,
                    "max_tokens": 8192,
                    "messages": apiMessages,
                    "stream": true
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
                        // Try to read error body
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                            if errorBody.count > 500 { break }
                        }
                        NSLog("[Anthropic] HTTP %d: %@", httpResponse.statusCode, errorBody)
                        self.messages.removeLast()
                        continuation.yield(.error("HTTP \(httpResponse.statusCode)"))
                        continuation.finish()
                        return
                    }

                    continuation.yield(.status("thinking"))
                    var fullResponse = ""
                    var firstChunk = true

                    for try await line in bytes.lines {
                        // Anthropic SSE: "event: ..." then "data: {...}"
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = json["type"] as? String else {
                            continue
                        }

                        switch type {
                        case "content_block_delta":
                            guard let delta = json["delta"] as? [String: Any],
                                  let text = delta["text"] as? String else { continue }
                            if firstChunk {
                                continuation.yield(.status("responding"))
                                firstChunk = false
                            }
                            fullResponse += text
                            continuation.yield(.delta(text))

                        case "message_stop":
                            break

                        case "error":
                            let errorMsg = (json["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                            continuation.yield(.error(errorMsg))

                        default:
                            break
                        }
                    }

                    // Store assistant response (text only, no images)
                    self.messages.append(["role": "assistant", "content": fullResponse])
                    continuation.yield(.done("anthropic"))
                    continuation.finish()
                } catch {
                    self.messages.removeLast()
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
