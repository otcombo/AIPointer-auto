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

    func cancel() {
        activeSession?.invalidateAndCancel()
        activeSession = nil
    }

    func configure(baseURL: String) {
        // Strip trailing slashes
        var url = baseURL
        while url.hasSuffix("/") { url = String(url.dropLast()) }
        self.baseURL = url
        self.authToken = Self.readTokenFromConfig() ?? ""
        NSLog("[API] configured: url=%@ token=%@", self.baseURL, authToken.isEmpty ? "(none)" : "(set)")
    }

    /// Read auth token from ~/.openclaw/openclaw.json
    private static func readTokenFromConfig() -> String? {
        let path = NSString(string: "~/.openclaw/openclaw.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = json["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any],
              let token = auth["token"] as? String else {
            return nil
        }
        return token
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
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !self.authToken.isEmpty {
                    request.setValue("Bearer \(self.authToken)", forHTTPHeaderField: "Authorization")
                }
                request.setValue("agent:main:main", forHTTPHeaderField: "x-openclaw-session-key")

                let body: [String: Any] = [
                    "model": "openclaw:main",
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
}
