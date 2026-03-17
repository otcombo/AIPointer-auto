import Foundation
import Cocoa

enum SSEEvent {
    case status(String)
    case delta(String)
    case done(String)
    case error(String)
}

class OpenClawService: NSObject, URLSessionDataDelegate {
    private var apiKey = ""
    private var model = ""
    private var baseURL = "https://api.anthropic.com"
    private var messages: [[String: Any]] = []
    private var activeSession: URLSession?
    private var hasLoggedConfig = false

    func cancel() {
        activeSession?.invalidateAndCancel()
        activeSession = nil
    }

    func configure(baseURL: String) {
        // Read API config from UserDefaults
        let defaults = UserDefaults.standard
        self.apiKey = defaults.string(forKey: "anthropicAPIKey") ?? ""
        self.model = defaults.string(forKey: "anthropicModel") ?? "anthropic/claude-sonnet-4-5"
        let customBaseURL = defaults.string(forKey: "anthropicBaseURL") ?? ""
        if !customBaseURL.isEmpty {
            var url = customBaseURL
            while url.hasSuffix("/") { url = String(url.dropLast()) }
            self.baseURL = url
        }

        if !hasLoggedConfig {
            hasLoggedConfig = true
            NSLog("[API] configured: anthropic baseURL=%@ model=%@ keyPresent=%@",
                  self.baseURL,
                  self.model,
                  self.apiKey.isEmpty ? "NO" : "YES")
        }
    }

    func clearHistory() {
        messages = []
    }

    /// Convert NSImage to base64-encoded JPEG string (quality 85%).
    /// Falls back to scaling down if the result exceeds 300KB.
    static func toBase64JPEG(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return nil
        }

        // If larger than 300KB, scale down and re-encode
        if jpeg.count > 307_200 {
            let scale = sqrt(307_200.0 / Double(jpeg.count))
            let newWidth = Int(Double(bitmap.pixelsWide) * scale)
            let newHeight = Int(Double(bitmap.pixelsHigh) * scale)

            let resized = NSImage(size: NSSize(width: newWidth, height: newHeight))
            resized.lockFocus()
            image.draw(in: NSRect(x: 0, y: 0, width: newWidth, height: newHeight),
                       from: .zero, operation: .copy, fraction: 1.0)
            resized.unlockFocus()

            if let resizedTiff = resized.tiffRepresentation,
               let resizedBitmap = NSBitmapImageRep(data: resizedTiff),
               let resizedJpeg = resizedBitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                return resizedJpeg.base64EncodedString()
            }
        }

        return jpeg.base64EncodedString()
    }

    func chat(message: String, conversationId: String?, images: [(NSImage, String)] = []) -> AsyncThrowingStream<SSEEvent, Error> {
        return chatAnthropic(message: message, images: images)
    }

    // MARK: - Anthropic Messages API

    private func chatAnthropic(message: String, images: [(NSImage, String)]) -> AsyncThrowingStream<SSEEvent, Error> {
        // Build user message in Anthropic format
        var content: [[String: Any]] = []
        content.append(["type": "text", "text": message])
        for (image, label) in images {
            content.append(["type": "text", "text": label])
            if let base64 = Self.toBase64JPEG(image) {
                content.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": base64
                    ]
                ])
            }
        }
        let userMessage: [String: Any] = ["role": "user", "content": content]
        messages.append(userMessage)

        return AsyncThrowingStream { continuation in
            Task {
                guard !self.apiKey.isEmpty else {
                    self.messages.removeLast()
                    continuation.yield(.error("API Key not configured. Please set it in Settings."))
                    continuation.finish()
                    return
                }

                guard let url = URL(string: "\(self.baseURL)/v1/messages") else {
                    self.messages.removeLast()
                    continuation.finish(throwing: URLError(.badURL))
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(self.apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                // Convert history: strip images from older messages, keep in latest
                let apiMessages = self.messages.enumerated().map { (index, msg) -> [String: Any] in
                    if index < self.messages.count - 1 {
                        return Self.stripImages(from: msg)
                    }
                    return msg
                }

                let body: [String: Any] = [
                    "model": self.model,
                    "max_tokens": 8192,
                    "system": "You are a helpful assistant. A small screenshot around the user's cursor may be attached for visual context. Use it only if relevant to the user's question; otherwise ignore it.",
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

    // MARK: - Helpers

    /// Strip image content blocks from a message, keeping only text.
    private static func stripImages(from message: [String: Any]) -> [String: Any] {
        guard let content = message["content"] else { return message }
        if content is String { return message }
        guard let arr = content as? [[String: Any]] else { return message }

        let textOnly = arr.filter { block in
            let type = block["type"] as? String ?? ""
            return type == "text"
        }
        if textOnly.isEmpty {
            return ["role": message["role"] as Any, "content": ""]
        }
        if textOnly.count == 1, let text = textOnly.first?["text"] as? String {
            return ["role": message["role"] as Any, "content": text]
        }
        return ["role": message["role"] as Any, "content": textOnly]
    }
}
