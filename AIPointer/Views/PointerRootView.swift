import SwiftUI

struct PointerRootView: View {
    @ObservedObject var viewModel: PointerViewModel
    @AppStorage("debugMaterial") private var debugMaterial: Int = 13 // default .hudWindow

    private var inputBarWidth: CGFloat {
        if viewModel.inputText.isEmpty { return 110 }
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        let textWidth = (viewModel.inputText as NSString).size(withAttributes: [.font: font]).width
        return min(max(textWidth + 44, 110), 440)
    }

    private var hasAttachments: Bool {
        !viewModel.attachedImages.isEmpty
    }

    /// Width needed to show all thumbnails: each 48px wide + 6px spacing + 10px padding each side.
    private var thumbnailStripWidth: CGFloat {
        let count = CGFloat(viewModel.attachedImages.count)
        guard count > 0 else { return 0 }
        return count * 48 + (count - 1) * 6 + 20
    }

    private var codeReadyWidth: CGFloat {
        if case .codeReady(let code) = viewModel.state {
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            let textWidth = (code as NSString).size(withAttributes: [.font: font]).width
            return textWidth + 20 // horizontal padding 10*2
        }
        return 16
    }

    private var selectionContextWidth: CGFloat {
        guard let sel = viewModel.pendingSelectionContext, !sel.isEmpty else { return 0 }
        let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        var maxW: CGFloat = 0
        if let text = sel.selectedText {
            let preview = text.count > 10 ? String(text.prefix(10)) + "…" : text
            let w = (preview as NSString).size(withAttributes: [.font: bodyFont]).width
            maxW = max(maxW, w)
        }
        for path in sel.filePaths {
            let nameW = ((path as NSString).lastPathComponent as NSString).size(withAttributes: [.font: bodyFont]).width
            maxW = max(maxW, nameW)
        }
        if !sel.isEmpty {
            let headerW = ("SELECTION" as NSString).size(withAttributes: [.font: headerFont]).width
            maxW = max(maxW, headerW)
        }
        return maxW > 0 ? maxW + 20 : 0 // 10px padding each side
    }

    /// Maximum expanded width shared by input and chat states.
    private static let maxExpandedWidth: CGFloat = 440

    private var shapeWidth: CGFloat {
        switch viewModel.state {
        case .idle: return 16
        case .monitoring: return 24
        case .suggestion: return 24
        case .codeReady: return codeReadyWidth
        case .input:
            let contextWidth: CGFloat = viewModel.pendingBehaviorContext != nil ? Self.maxExpandedWidth : 0
            let skillWidth: CGFloat = viewModel.showSkillCompletion ? 360 : 0
            let contentWidth = max(inputBarWidth, thumbnailStripWidth, contextWidth, selectionContextWidth, skillWidth)
            return min(contentWidth, Self.maxExpandedWidth)
        case .thinking, .responding, .response: return Self.maxExpandedWidth
        }
    }

    private var shapeRadius: CGFloat {
        viewModel.state.isExpanded ? 20 : 12
    }

    // MARK: - Dynamic expansion direction

    /// Whether content should expand right, based on current width and screen space.
    private var shouldExpandRight: Bool {
        let mouseX = viewModel.expansionMouseX
        let maxX = viewModel.expansionScreenMaxX
        let padding: CGFloat = 14
        return (mouseX + shapeWidth + padding) <= maxX
    }

    /// Whether content should expand down, based on screen space (checked once, using max height).
    private var shouldExpandDown: Bool {
        viewModel.expandsDown
    }

    /// The overlay alignment based on current expansion direction.
    private var overlayAlignment: Alignment {
        switch (shouldExpandRight, shouldExpandDown) {
        case (true, true):   return .topLeading
        case (false, true):  return .topTrailing
        case (true, false):  return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: overlayAlignment) {
                ZStack(alignment: .topLeading) {
                    switch viewModel.state {
                    case .idle:
                        Color.clear.frame(width: 16, height: 16)
                    case .monitoring:
                        MonitoringIndicator()
                    case .suggestion:
                        SuggestionIndicator()
                    case .codeReady(let code):
                        CodeReadyCursor(code: code)
                    case .input:
                        VStack(alignment: .leading, spacing: 0) {
                            // Selection context bar
                            if let sel = viewModel.pendingSelectionContext, !sel.isEmpty {
                                SelectionContextView(context: sel)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                Rectangle()
                                    .fill(Color.white.opacity(0.1))
                                    .frame(height: 1)
                                    .padding(.horizontal, 10)
                            }
                            // Behavior context bar
                            if let context = viewModel.pendingBehaviorContext {
                                ScrollView {
                                    BehaviorContextView(text: context)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxHeight: 300)
                                Rectangle()
                                    .fill(Color.white.opacity(0.1))
                                    .frame(height: 1)
                                    .padding(.horizontal, 10)
                            }
                            // Skill completion popup
                            if viewModel.showSkillCompletion {
                                SkillCompletionView(
                                    skills: viewModel.filteredSkills,
                                    selectedIndex: viewModel.skillCompletionIndex,
                                    onSelect: { skill in viewModel.selectSkill(skill) }
                                )
                                .transition(.opacity.combined(with: .move(edge: .top)))
                                Rectangle()
                                    .fill(Color.white.opacity(0.1))
                                    .frame(height: 1)
                                    .padding(.horizontal, 10)
                                    .transition(.opacity)
                            }
                            // Attachment preview in input mode
                            if !viewModel.attachedImages.isEmpty {
                                AttachmentStripView(
                                    images: viewModel.attachedImages,
                                    onRemove: { index in viewModel.removeAttachment(at: index) }
                                )
                                Rectangle()
                                    .fill(Color.white.opacity(0.1))
                                    .frame(height: 1)
                                    .padding(.horizontal, 10)
                            }
                            InputBar(
                                text: $viewModel.inputText,
                                onSubmit: { viewModel.send() },
                                onCancel: { viewModel.dismiss() },
                                onScreenshot: { viewModel.requestScreenshot() },
                                onUpArrow: { viewModel.skillCompletionMoveUp() },
                                onDownArrow: { viewModel.skillCompletionMoveDown() },
                                onTab: { viewModel.skillCompletionConfirm() }
                            )
                        }
                        .onChange(of: viewModel.inputText) { _, _ in
                            viewModel.updateSkillCompletion()
                        }
                    case .thinking:
                        ChatPanel(
                            chatHistory: viewModel.chatHistory,
                            responseText: "",
                            isThinking: true,
                            isStreaming: false,
                            inputText: $viewModel.inputText,
                            onSubmit: { viewModel.send() },
                            onDismiss: { viewModel.dismiss() }
                        )
                    case .responding(let text):
                        ChatPanel(
                            chatHistory: viewModel.chatHistory,
                            responseText: text,
                            isThinking: false,
                            isStreaming: true,
                            inputText: $viewModel.inputText,
                            onSubmit: { viewModel.send() },
                            onDismiss: { viewModel.dismiss() }
                        )
                    case .response(let text):
                        ChatPanel(
                            chatHistory: viewModel.chatHistory,
                            responseText: text,
                            isThinking: false,
                            isStreaming: false,
                            inputText: $viewModel.inputText,
                            onSubmit: { viewModel.send() },
                            onDismiss: { viewModel.dismiss() },
                            attachedImages: viewModel.attachedImages,
                            onRemoveAttachment: { index in viewModel.removeAttachment(at: index) },
                            onScreenshot: { viewModel.requestScreenshot() }
                        )
                    }
                }
                .frame(width: shapeWidth, alignment: .topLeading)
                .clipShape(PointerShape(radius: shapeRadius))
                .background(
                    ZStack {
                        VisualEffectBlur(material: NSVisualEffectView.Material(rawValue: debugMaterial) ?? .sheet, blendingMode: .behindWindow)
                            .clipShape(PointerShape(radius: shapeRadius))
                        PointerShape(radius: shapeRadius)
                            .fill(Color.black.opacity(viewModel.state.isExpanded ? 0.15 : 0.15))
                    }
                    .shadow(color: .black.opacity(0.25), radius: 3.75, x: 0, y: 3.75)
                )
                .overlay(PointerShape(radius: shapeRadius).stroke(Color.white, lineWidth: 2))
                .padding(14) // Offset from panel edge = shadow padding
            }
            .onChange(of: shouldExpandRight) { _, newValue in
                viewModel.expandsRight = newValue
                // Only reposition while expanded; during collapse the panel
                // drives its own animation and direction flips would fight it.
                if viewModel.state.isExpanded {
                    viewModel.onExpansionDirectionChanged?()
                }
            }
            .animation(
                viewModel.state == .idle
                    ? .easeOut(duration: 0.25)                          // collapse: bezier, no bounce
                    : .spring(response: 0.293, dampingFraction: 0.793), // expand: mass=1, damping=34, stiffness=460
                value: viewModel.state
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: inputBarWidth)
            .animation(.spring(response: 0.293, dampingFraction: 0.793), value: viewModel.attachedImages.count)
            .animation(.spring(response: 0.293, dampingFraction: 0.793), value: viewModel.showSkillCompletion)
            .animation(.spring(response: 0.293, dampingFraction: 0.793), value: viewModel.filteredSkills.count)
            .animation(.spring(response: 0.293, dampingFraction: 0.793), value: viewModel.pendingSelectionContext)
    }
}

/// Renders captured selection context (selected text and/or Finder file paths).
private struct SelectionContextView: View {
    let context: SelectionContextCapture.CapturedContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text = context.selectedText {
                let preview = text.count > 10 ? String(text.prefix(10)) + "…" : text
                VStack(alignment: .leading, spacing: 2) {
                    Text("SELECTION")
                        .font(.custom("SF Compact Text", size: 11).weight(.semibold))
                        .foregroundColor(.white.opacity(0.45))
                    Text(preview)
                        .font(.custom("SF Compact Text", size: 13).weight(.medium))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            ForEach(context.filePaths, id: \.self) { path in
                VStack(alignment: .leading, spacing: 1) {
                    Text("FILE")
                        .font(.custom("SF Compact Text", size: 11).weight(.semibold))
                        .foregroundColor(.white.opacity(0.45))
                    Text((path as NSString).lastPathComponent)
                        .font(.custom("SF Compact Text", size: 13).weight(.medium))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Renders behavior context with section headers (Observation / Insight / Action).
private struct BehaviorContextView: View {
    let text: String

    private var sections: [(header: String?, body: String)] {
        let knownHeaders: Set<String> = ["Observation", "Insight", "Action"]
        var result: [(header: String?, body: String)] = []
        var currentHeader: String? = nil
        var currentLines: [String] = []

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if knownHeaders.contains(trimmed) {
                // Flush previous section
                if !currentLines.isEmpty {
                    result.append((header: currentHeader, body: currentLines.joined(separator: "\n")))
                    currentLines = []
                }
                currentHeader = trimmed
            } else if !trimmed.isEmpty {
                currentLines.append(trimmed)
            }
        }
        if !currentLines.isEmpty {
            result.append((header: currentHeader, body: currentLines.joined(separator: "\n")))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 2) {
                    if let header = section.header {
                        Text(header)
                            .font(.custom("SF Compact Text", size: 12).weight(.semibold))
                            .foregroundColor(.white.opacity(0.45))
                            .textCase(.uppercase)
                    }
                    Text(section.body)
                        .font(.custom("SF Compact Text", size: 14).weight(.medium))
                        .foregroundColor(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
