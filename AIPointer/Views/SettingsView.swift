import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("suppressFnKey") private var suppressFnKey = true
    @AppStorage("longPressDuration") private var longPressDuration = 0.0
    @AppStorage("backendURL") private var backendURL = "https://claude.otcombo.com"
    @AppStorage("authToken") private var authToken = ""

    var body: some View {
        Form {
            Section("Trigger") {
                Toggle("Suppress fn key emoji picker", isOn: $suppressFnKey)
                Text("When enabled, fn key events are consumed and won't open the system emoji picker.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Long-press duration")
                    Slider(value: $longPressDuration, in: 0...0.8, step: 0.05)
                    Text("\(Int(longPressDuration * 1000))ms")
                        .monospacedDigit()
                        .frame(width: 45, alignment: .trailing)
                }
                Text("Hold fn for this duration to activate. Set to 0 for instant trigger.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

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

            Section("Backend") {
                TextField("Server URL", text: $backendURL)
                    .textFieldStyle(.roundedBorder)

                SecureField("Auth Token", text: $authToken)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 380)
    }
}

#Preview {
    SettingsView()
}
