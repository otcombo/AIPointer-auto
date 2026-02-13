import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("suppressFnKey") private var suppressFnKey = true
    @AppStorage("apiFormat") private var apiFormat = "anthropic"
    @AppStorage("backendURL") private var backendURL = ""
    @AppStorage("authToken") private var authToken = ""
    @AppStorage("agentId") private var agentId = "main"
    @AppStorage("modelName") private var modelName = "anthropic/claude-sonnet-4-5"

    private var isAnthropic: Bool { apiFormat == "anthropic" }

    var body: some View {
        Form {
            Section("Trigger") {
                Toggle("Suppress fn key emoji picker", isOn: $suppressFnKey)
                Text("When enabled, fn key events are consumed and won't open the system emoji picker.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("To fully prevent the emoji picker, go to:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("System Settings → Keyboard → \"Press fn key to\" → Do Nothing") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption)
                }
            }

            Section("API") {
                Picker("Format", selection: $apiFormat) {
                    Text("Anthropic Messages").tag("anthropic")
                    Text("OpenAI (OpenClaw)").tag("openai")
                }
                .pickerStyle(.segmented)

                TextField("Server URL", text: $backendURL,
                          prompt: Text(isAnthropic ? "https://api.anthropic.com" : "http://localhost:18789"))
                    .textFieldStyle(.roundedBorder)

                SecureField(isAnthropic ? "API Key" : "Auth Token", text: $authToken)
                    .textFieldStyle(.roundedBorder)

                if isAnthropic {
                    TextField("Model", text: $modelName, prompt: Text("anthropic/claude-sonnet-4-5"))
                        .textFieldStyle(.roundedBorder)
                    Text("Model ID to use for chat requests.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    TextField("Agent ID", text: $agentId, prompt: Text("main"))
                        .textFieldStyle(.roundedBorder)
                    Text("The OpenClaw agent to chat with. Note: OpenClaw does not support sending images.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 420)
    }
}

#Preview {
    SettingsView()
}
