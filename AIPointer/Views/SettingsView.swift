import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var viewModel: PointerViewModel
    @AppStorage("backendURL") private var backendURL = "http://localhost:18789"
    @AppStorage("agentId") private var agentId = "main"
    @AppStorage("behaviorSensingEnabled") private var behaviorSensingEnabled = true
    @AppStorage("behaviorSensitivity") private var behaviorSensitivity = 1.0
    @AppStorage("debugMaterial") private var debugMaterial: Int = 13 // .hudWindow
    @State private var debugCycling = false

    var body: some View {
        Form {
            Section("OpenClaw") {
                TextField("Server URL", text: $backendURL,
                          prompt: Text("http://localhost:18789"))
                    .textFieldStyle(.roundedBorder)
                TextField("Agent ID", text: $agentId,
                          prompt: Text("main"))
                    .textFieldStyle(.roundedBorder)
                Text("The agent to chat with. Used in model name and session key.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Behavior Sensing") {
                Toggle("Enable behavior sensing", isOn: $behaviorSensingEnabled)
                if behaviorSensingEnabled {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Sensitivity")
                            Spacer()
                            Text(String(format: "%.1f", behaviorSensitivity))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $behaviorSensitivity, in: 0.5...2.0, step: 0.1)
                    }
                    Text("Higher sensitivity triggers suggestions more often.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Debug") {
                Toggle("Cycle pointer states", isOn: $debugCycling)
                    .onChange(of: debugCycling) { _, on in
                        if on { viewModel.startDebugCycle() }
                        else { viewModel.stopDebugCycle(); viewModel.dismiss() }
                    }
                Text("Cycles idle → monitoring → codeReady → suggestion every 3s.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Blur Material", selection: $debugMaterial) {
                    Text("titlebar (3)").tag(3)
                    Text("selection (4)").tag(4)
                    Text("menu (5)").tag(5)
                    Text("popover (6)").tag(6)
                    Text("sidebar (7)").tag(7)
                    Text("headerView (10)").tag(10)
                    Text("sheet (11)").tag(11)
                    Text("windowBackground (12)").tag(12)
                    Text("hudWindow (13)").tag(13)
                    Text("fullScreenUI (15)").tag(15)
                    Text("toolTip (17)").tag(17)
                    Text("contentBackground (18)").tag(18)
                    Text("underWindowBackground (21)").tag(21)
                    Text("underPageBackground (22)").tag(22)
                }
                Text("Live preview — click to switch material.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 420)
    }
}

#Preview {
    SettingsView(viewModel: PointerViewModel())
}
