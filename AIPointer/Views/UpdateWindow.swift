import SwiftUI
import AppKit

/// Standalone update check window showing app icon, current version, and update status.
struct UpdateView: View {
    @ObservedObject var viewModel: UpdateViewModel
    @State private var isPresented = false

    /// Load app icon from SPM resource bundle, falling back to NSApp icon.
    private var appIcon: NSImage? {
        let bundleName = "AIPointer_AIPointer"
        // Try .app bundle Resources first
        if let resourceURL = Bundle.main.resourceURL,
           let bundle = Bundle(url: resourceURL.appendingPathComponent(bundleName + ".bundle")),
           let url = bundle.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        // SPM development: Bundle.module
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSApp.applicationIconImage
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 28)

            // App icon
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 80, height: 80)
            }

            Spacer().frame(height: 16)

            Text("AIPointer")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.primary)

            Text("v\(viewModel.currentVersion)")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            Spacer().frame(height: 24)

            // Status area
            statusContent

            Spacer().frame(height: 24)

            // Action buttons
            actionButtons

            Spacer().frame(height: 20)
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 24)
        .scaleEffect(isPresented ? 1.0 : 0.95)
        .opacity(isPresented ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                isPresented = true
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch viewModel.state {
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L("正在检查更新…", "Checking for updates…"))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

        case .available(let version):
            VStack(spacing: 6) {
                Text(L("发现新版本", "Update Available"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                Text("v\(version)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

        case .downloading(let progress):
            VStack(spacing: 8) {
                Text(L("正在下载…", "Downloading…"))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                ProgressView(value: progress)
                    .frame(width: 200)
            }

        case .installing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L("正在安装…", "Installing…"))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

        case .upToDate:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 16))
                Text(L("已是最新版本", "You're up to date"))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

        case .error(let msg):
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 14))
                    Text(L("检查失败", "Check failed"))
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                }
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch viewModel.state {
        case .available:
            HStack(spacing: 12) {
                Button(L("以后再说", "Later")) {
                    viewModel.dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.secondary)

                Button(L("立即更新", "Update Now")) {
                    viewModel.update()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

        case .error:
            Button(L("重试", "Retry")) {
                viewModel.retry()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

        case .checking, .downloading, .installing:
            EmptyView()

        case .upToDate:
            Button(L("好", "OK")) {
                viewModel.dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }
}

// MARK: - ViewModel

@MainActor
final class UpdateViewModel: ObservableObject {
    enum ViewState: Equatable {
        case checking
        case available(version: String)
        case downloading(progress: Double)
        case installing
        case upToDate
        case error(String)
    }

    @Published var state: ViewState = .checking
    let currentVersion: String

    var onDismiss: (() -> Void)?
    var onUpdate: (() -> Void)?
    var onRetry: (() -> Void)?

    init(currentVersion: String) {
        self.currentVersion = currentVersion
    }

    func dismiss() { onDismiss?() }
    func update() { onUpdate?() }
    func retry() { onRetry?() }
}
