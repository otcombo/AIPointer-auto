import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var viewModel: PointerViewModel
    @AppStorage("backendURL") private var backendURL = "http://localhost:18789"
    @AppStorage("agentId") private var agentId = "main"
    @AppStorage("responseLanguage") private var responseLanguage = defaultResponseLanguage
    @AppStorage("behaviorSensingEnabled") private var behaviorSensingEnabled = true
    @AppStorage("behaviorSensitivity") private var behaviorSensitivity = 1.0
    @AppStorage("focusDetectionEnabled") private var focusDetectionEnabled = true
    @AppStorage("focusDetectionWindow") private var focusDetectionWindow = 5.0
    @AppStorage("focusCooldownDetected") private var focusCooldownDetected = 10.0
    @AppStorage("focusCooldownMissed") private var focusCooldownMissed = 2.0
    @AppStorage("focusStrictness") private var focusStrictness = 1
    @AppStorage("focusShowObservation") private var focusShowObservation = true
    @AppStorage("focusShowInsight") private var focusShowInsight = true
    @AppStorage("focusShowOffer") private var focusShowOffer = true
    @AppStorage("suggestionDisplaySeconds") private var suggestionDisplaySeconds = 10.0
    @AppStorage("debugMaterial") private var debugMaterial: Int = 13 // .hudWindow
    @State private var debugCycling = false
    @State private var connectionStatus: String?
    @State private var connectionOk: Bool = false

    var body: some View {
        Form {
            Section("OpenClaw") {
                TextField("Server URL", text: $backendURL,
                          prompt: Text("e.g. http://localhost:18789"))
                    .textFieldStyle(.roundedBorder)
                TextField("Agent ID", text: $agentId,
                          prompt: Text("e.g. main"))
                    .textFieldStyle(.roundedBorder)
                Text("The agent to chat with. Used in model name and session key.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Picker("Response Language", selection: $responseLanguage) {
                    Text("中文").tag("zh-CN")
                    Text("English").tag("en")
                }
                .pickerStyle(.segmented)
                Text("Language for AI responses and behavior sensing suggestions.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // 连接测试 & 终端配置
                HStack {
                    Button("测试连接") {
                        testConnection()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("打开终端配置") {
                        openTerminalForAdvancedConfig()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if let status = connectionStatus {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(connectionOk ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(status)
                                .font(.caption)
                                .foregroundColor(connectionOk ? .green : .red)
                        }
                    }
                }
                Text("在终端中配置 API Key、模型等高级选项")
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

                    Divider()

                    Toggle("Enable focus detection", isOn: $focusDetectionEnabled)

                    if focusDetectionEnabled {
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Detection window")
                                Spacer()
                                Text("\(Int(focusDetectionWindow)) min")
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $focusDetectionWindow, in: 3...10, step: 1)
                        }

                        VStack(alignment: .leading) {
                            HStack {
                                Text("Cooldown (detected)")
                                Spacer()
                                Text(String(format: "%.1f", focusCooldownDetected) + " min")
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $focusCooldownDetected, in: 0...30, step: 0.5)
                        }

                        VStack(alignment: .leading) {
                            HStack {
                                Text("Cooldown (not detected)")
                                Spacer()
                                Text(String(format: "%.1f", focusCooldownMissed) + " min")
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $focusCooldownMissed, in: 0...5, step: 0.5)
                        }

                        Picker("Strictness", selection: $focusStrictness) {
                            Text("Relaxed").tag(0)
                            Text("Normal").tag(1)
                            Text("Strict").tag(2)
                        }
                        .pickerStyle(.segmented)

                        Text("Relaxed = more suggestions, Strict = fewer but more precise")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Divider()

                        Text("Display Options")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Toggle("Show observation", isOn: $focusShowObservation)
                        Text("Detected behavior facts")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Toggle("Show insight", isOn: $focusShowInsight)
                        Text("AI's interpretation of your intent")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Toggle("Show offer", isOn: $focusShowOffer)
                        Text("What AI can help with, including skill recommendations")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Divider()

                        VStack(alignment: .leading) {
                            HStack {
                                Text("Suggestion display time")
                                Spacer()
                                Text("\(Int(suggestionDisplaySeconds))s")
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $suggestionDisplaySeconds, in: 3...30, step: 1)
                        }
                    }
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

                Button("Show Onboarding") {
                    NotificationCenter.default.post(name: .showOnboarding, object: nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 640)
    }

    // MARK: - 终端配置

    private func openTerminalForAdvancedConfig() {
        let script = """
        tell application "Terminal"
            activate
            do script "echo '=== OpenClaw 高级配置 ===' && echo '' && echo '查看当前状态:' && openclaw status 2>/dev/null || echo 'openclaw 未找到' && echo '' && echo '编辑配置: openclaw config edit' && echo '查看帮助: openclaw --help'"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    // MARK: - 连接测试

    private func testConnection() {
        connectionStatus = "测试中..."
        connectionOk = false

        let urlString = backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(urlString)/api/health") else {
            connectionStatus = "无效的 URL"
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode) {
                    connectionStatus = "连接成功"
                    connectionOk = true
                } else {
                    connectionStatus = "服务器返回错误"
                }
            } catch {
                connectionStatus = "无法连接"
            }
        }
    }
}

extension Notification.Name {
    static let showOnboarding = Notification.Name("showOnboarding")
}

#Preview {
    SettingsView(viewModel: PointerViewModel())
}
