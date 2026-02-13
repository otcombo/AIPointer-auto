import Foundation
import Cocoa

enum SSEEvent {
    case status(String)
    case delta(String)
    case done(String)
    case error(String)
}

class OpenClawService: NSObject, URLSessionDataDelegate {
    private var baseURL = ""
    private var authToken = ""
    private var messages: [[String: Any]] = []
    private var activeSession: URLSession?

    // Colorist gateway for direct Anthropic Messages API (supports images)
    private var coloristBaseURL = ""
    private var coloristAPIKey = ""
    private var coloristModel = ""

    func cancel() {
        activeSession?.invalidateAndCancel()
        activeSession = nil
    }

    func configure(baseURL: String) {
        // Strip trailing slashes
        var url = baseURL
        while url.hasSuffix("/") { url = String(url.dropLast()) }
        self.baseURL = url

        // Read full config from ~/.openclaw/openclaw.json
        if let config = Self.readConfig() {
            self.authToken = config.gatewayToken
            self.coloristBaseURL = config.coloristBaseURL
            self.coloristAPIKey = config.coloristAPIKey
            self.coloristModel = config.coloristModel
        }
        NSLog("[API] configured: openclaw=%@ colorist=%@ model=%@",
              self.baseURL,
              coloristBaseURL.isEmpty ? "(none)" : coloristBaseURL,
              coloristModel.isEmpty ? "(none)" : coloristModel)
    }

    private struct OpenClawConfig {
        let gatewayToken: String
        let coloristBaseURL: String
        let coloristAPIKey: String
        let coloristModel: String
    }

    /// Read config from ~/.openclaw/openclaw.json
    private static func readConfig() -> OpenClawConfig? {
        let path = NSString(string: "~/.openclaw/openclaw.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Gateway auth token
        let gatewayToken: String = {
            guard let gateway = json["gateway"] as? [String: Any],
                  let auth = gateway["auth"] as? [String: Any],
                  let token = auth["token"] as? String else { return "" }
            return token
        }()

        // Colorist provider config (for direct Anthropic Messages API with image support)
        var coloristBaseURL = ""
        var coloristAPIKey = ""
        var coloristModel = ""

        if let models = json["models"] as? [String: Any],
           let providers = models["providers"] as? [String: Any] {
            // Find first provider with api: "anthropic-messages" and image input support
            for (_, providerValue) in providers {
                guard let provider = providerValue as? [String: Any],
                      let providerBaseUrl = provider["baseUrl"] as? String,
                      let apiKey = provider["apiKey"] as? String,
                      let providerModels = provider["models"] as? [[String: Any]] else { continue }

                // Find a model that supports image input
                for model in providerModels {
                    if let inputs = model["input"] as? [String],
                       inputs.contains("image"),
                       let modelId = model["id"] as? String {
                        coloristBaseURL = providerBaseUrl
                        coloristAPIKey = apiKey
                        coloristModel = modelId
                        break
                    }
                }
                if !coloristModel.isEmpty { break }
            }
        }

        return OpenClawConfig(
            gatewayToken: gatewayToken,
            coloristBaseURL: coloristBaseURL,
            coloristAPIKey: coloristAPIKey,
            coloristModel: coloristModel
        )
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

    /// Stateless single-shot request to OpenClaw.
    /// Does not maintain chat history — each call is independent.
    func executeCommand(prompt: String) -> AsyncThrowingStream<SSEEvent, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
                    continuation.finish(throwing: URLError(.badURL))
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !self.authToken.isEmpty {
                    request.setValue("Bearer \(self.authToken)", forHTTPHeaderField: "Authorization")
                }
                request.timeoutInterval = 30

                let messages: [[String: Any]] = [
                    ["role": "user", "content": prompt]
                ]

                let body: [String: Any] = [
                    "model": "openclaw:main",
                    "messages": messages,
                    "stream": true,
                    "user": "aipointer-autoverify"
                ]
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

                    var fullResponse = ""

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

                        fullResponse += content
                        continuation.yield(.delta(content))
                    }

                    // Do NOT store in self.messages — stateless
                    continuation.yield(.done("openclaw"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func chat(message: String, conversationId: String?, images: [(NSImage, String)] = []) -> AsyncThrowingStream<SSEEvent, Error> {
        if !images.isEmpty && !coloristBaseURL.isEmpty {
            return chatAnthropic(message: message, images: images)
        }
        return chatOpenClaw(message: message, images: images)
    }

    // MARK: - OpenClaw chat completions (text-only)

    private func chatOpenClaw(message: String, images: [(NSImage, String)]) -> AsyncThrowingStream<SSEEvent, Error> {
        let userMessage: [String: Any]
        if images.isEmpty {
            userMessage = ["role": "user", "content": message]
        } else {
            // Fallback: include images in OpenAI format (may not display, but preserves text)
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
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !self.authToken.isEmpty {
                    request.setValue("Bearer \(self.authToken)", forHTTPHeaderField: "Authorization")
                }
                request.setValue("agent:main:main", forHTTPHeaderField: "x-openclaw-session-key")

                // Strip image content from history for OpenClaw (it can't handle images)
                let cleanMessages = self.messages.map { Self.stripImages(from: $0) }

                let body: [String: Any] = [
                    "model": "openclaw:main",
                    "messages": cleanMessages,
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

    // MARK: - Anthropic Messages API (supports images)

    private func chatAnthropic(message: String, images: [(NSImage, String)]) -> AsyncThrowingStream<SSEEvent, Error> {
        // Build user message in Anthropic format
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
        let userMessage: [String: Any] = ["role": "user", "content": content]
        messages.append(userMessage)

        return AsyncThrowingStream { continuation in
            Task {
                guard let url = URL(string: "\(self.coloristBaseURL)/v1/messages") else {
                    self.messages.removeLast()
                    continuation.finish(throwing: URLError(.badURL))
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(self.coloristAPIKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                // Convert history: strip images from older messages, keep in latest
                let apiMessages = self.messages.enumerated().map { (index, msg) -> [String: Any] in
                    if index < self.messages.count - 1 {
                        return Self.stripImages(from: msg)
                    }
                    return msg
                }

                let body: [String: Any] = [
                    "model": self.coloristModel,
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
