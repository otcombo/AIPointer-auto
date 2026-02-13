import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("suppressFnKey") private var suppressFnKey = true
    @AppStorage("backendURL") private var backendURL = "http://localhost:18789"

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

            Section("OpenClaw") {
                TextField("Server URL", text: $backendURL,
                          prompt: Text("http://localhost:18789"))
                    .textFieldStyle(.roundedBorder)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 420)
    }
}

#Preview {
    SettingsView()
}
