import SwiftUI
import AppKit

// MARK: - Overlay style constants (Speech Bubble + Tight Crisp Shadow)

private enum OverlayStyle {
    static let cardBg = Color.white
    static let cardShadow = Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.22)
    static let codeBg = Color(red: 250/255, green: 249/255, blue: 247/255)  // #faf9f7
    static let codeBorder = Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.06)
    static let textPrimary = Color(red: 35/255, green: 17/255, blue: 60/255)
    static let textMuted = Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.55)
    static let textHint = Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.30)
    static let orange = Color(red: 249/255, green: 93/255, blue: 2/255)
    static let orangeBorder = Color(red: 249/255, green: 93/255, blue: 2/255).opacity(0.25)
    static let selectedBg = Color(red: 249/255, green: 93/255, blue: 2/255).opacity(0.06)
    static let denyBorder = Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.12)
    static let denyText = Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.50)
    static let radioBorder = Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.20)
    static let inputBg = Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.04)

    static let tailHeight: CGFloat = 8
}

// MARK: - Speech Bubble Shape

/// Card with 14px corners and a triangular tail at bottom-center-right pointing toward mascot
private struct SpeechBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 14  // uniform corner radius

        let tailH: CGFloat = OverlayStyle.tailHeight
        let tailW: CGFloat = 14
        // Tail sits far right — points toward mascot below-right
        let tailCenter = rect.width * 0.80
        let cardBottom = rect.height - tailH

        var path = Path()

        // Start at top edge after top-left corner
        path.move(to: CGPoint(x: r, y: 0))

        // Top edge → top-right corner
        path.addLine(to: CGPoint(x: rect.width - r, y: 0))
        path.addArc(center: CGPoint(x: rect.width - r, y: r),
                     radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)

        // Right edge → bottom-right corner
        path.addLine(to: CGPoint(x: rect.width, y: cardBottom - r))
        path.addArc(center: CGPoint(x: rect.width - r, y: cardBottom - r),
                     radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)

        // Bottom edge → tail (right side of tail first)
        path.addLine(to: CGPoint(x: tailCenter + tailW / 2, y: cardBottom))
        path.addLine(to: CGPoint(x: tailCenter, y: rect.height))        // tail tip
        path.addLine(to: CGPoint(x: tailCenter - tailW / 2, y: cardBottom))

        // Continue bottom edge → bottom-left corner
        path.addLine(to: CGPoint(x: r, y: cardBottom))
        path.addArc(center: CGPoint(x: r, y: cardBottom - r),
                     radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)

        // Left edge → top-left corner
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addArc(center: CGPoint(x: r, y: r),
                     radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)

        path.closeSubpath()
        return path
    }
}

/// Render markdown string as AttributedString, falling back to plain text
private func markdownText(_ string: String) -> Text {
    if let attributed = try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
        return Text(attributed)
    }
    return Text(string)
}

/// Activate the terminal running the Claude Code session.
/// Uses the exact terminal PID from the hook when available, falls back to first running terminal.
/// AppleScript `tell application ... to activate` is the most reliable cross-Space activation on macOS.
private func focusTerminal(pid: Int? = nil) {
    // Try PID-based activation first
    if let pid = pid,
       let app = NSRunningApplication(processIdentifier: pid_t(pid)),
       let name = app.localizedName {
        activateApp(named: name)
        return
    }
    // Fallback: activate first running terminal app
    let bundleIDs = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.exafunction.windsurf",       // Windsurf
        "dev.zed.Zed",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "dev.warp.Warp-Stable",
    ]
    for id in bundleIDs {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == id }),
           let name = app.localizedName {
            activateApp(named: name)
            return
        }
    }
}

private func activateApp(named name: String) {
    let src = "tell application \"\(name)\" to activate"
    if let script = NSAppleScript(source: src) {
        var error: NSDictionary?
        script.executeAndReturnError(&error)
    }
}

// MARK: - AskUserQuestion View

struct AskUserQuestionView: View {
    let permission: PendingPermission
    let questions: [ParsedQuestion]
    let onAnswer: ([String: String]) -> Void
    let onDeny: () -> Void
    let onLater: () -> Void

    @State private var selections: [String: String] = [:]
    @State private var multiSelections: [String: Set<String>] = [:]
    @State private var customInputs: [String: String] = [:]
    @State private var usingCustom: Set<String> = []

    private var allAnswered: Bool {
        questions.allSatisfy { q in
            if usingCustom.contains(q.question) {
                return !(customInputs[q.question] ?? "").isEmpty
            }
            if q.multiSelect {
                return !(multiSelections[q.question] ?? []).isEmpty
            }
            return selections[q.question] != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Header
            HStack {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(OverlayStyle.orange)
                Text("Question")
                    .font(Constants.heading(size: 11, weight: .bold))
                    .foregroundStyle(OverlayStyle.textPrimary)

                Spacer()

                Button { focusTerminal(pid: permission.event.terminalPid) } label: {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(OverlayStyle.textHint)
                }
                .buttonStyle(.plain)
                .help("Open terminal")

                Button { onLater() } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(OverlayStyle.textHint)
                }
                .buttonStyle(.plain)
                .help("Handle later")
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                        questionView(question)
                    }
                }
            }
            .frame(maxHeight: 200)

            // Submit / Skip
            HStack(spacing: 5) {
                Button {
                    var answers: [String: String] = [:]
                    for q in questions {
                        if usingCustom.contains(q.question) {
                            answers[q.question] = customInputs[q.question] ?? ""
                        } else if q.multiSelect {
                            answers[q.question] = (multiSelections[q.question] ?? []).sorted().joined(separator: ", ")
                        } else {
                            answers[q.question] = selections[q.question] ?? ""
                        }
                    }
                    onAnswer(answers)
                } label: {
                    Text("Submit")
                        .font(Constants.heading(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(allAnswered ? OverlayStyle.orange : Color.gray.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!allAnswered)

                Button {
                    onDeny()
                } label: {
                    Text("Skip")
                        .font(Constants.heading(size: 11, weight: .semibold))
                        .foregroundStyle(OverlayStyle.denyText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(OverlayStyle.denyBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .padding(.bottom, OverlayStyle.tailHeight)
        .background(OverlayStyle.cardBg)
        .clipShape(SpeechBubbleShape())
        .shadow(color: OverlayStyle.cardShadow, radius: 3, x: 0, y: 2)
    }

    @ViewBuilder
    private func questionView(_ question: ParsedQuestion) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let header = question.header {
                Text(header)
                    .font(Constants.heading(size: 10, weight: .bold))
                    .foregroundStyle(OverlayStyle.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule().stroke(OverlayStyle.orangeBorder, lineWidth: 1))
            }

            markdownText(question.question)
                .font(Constants.body(size: 11, weight: .medium))
                .foregroundStyle(OverlayStyle.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture { focusTerminal(pid: permission.event.terminalPid) }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { idx, option in
                    optionRow(question: question, option: option, index: idx)
                }
                otherRow(question: question)
            }
        }
    }

    @ViewBuilder
    private func optionRow(question: ParsedQuestion, option: ParsedOption, index: Int) -> some View {
        let isMulti = question.multiSelect
        let isSelected: Bool = {
            guard !usingCustom.contains(question.question) else { return false }
            if isMulti {
                return multiSelections[question.question]?.contains(option.label) == true
            }
            return selections[question.question] == option.label
        }()

        Button {
            usingCustom.remove(question.question)
            if isMulti {
                var set = multiSelections[question.question] ?? []
                if set.contains(option.label) { set.remove(option.label) } else { set.insert(option.label) }
                multiSelections[question.question] = set
            } else {
                selections[question.question] = option.label
            }
        } label: {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: isMulti
                    ? (isSelected ? "checkmark.square.fill" : "square")
                    : (isSelected ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? OverlayStyle.orange : OverlayStyle.radioBorder)
                    .frame(width: 13)

                VStack(alignment: .leading, spacing: 1) {
                    markdownText(option.label)
                        .font(Constants.body(size: 11, weight: .medium))
                        .foregroundStyle(OverlayStyle.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let desc = option.description, !desc.isEmpty {
                        markdownText(desc)
                            .font(Constants.body(size: 9))
                            .foregroundStyle(OverlayStyle.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 5)
            .background(isSelected ? OverlayStyle.selectedBg : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func otherRow(question: ParsedQuestion) -> some View {
        let isCustom = usingCustom.contains(question.question)

        VStack(alignment: .leading, spacing: 2) {
            Button {
                usingCustom.insert(question.question)
                selections.removeValue(forKey: question.question)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isCustom ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(isCustom ? OverlayStyle.orange : OverlayStyle.radioBorder)
                        .frame(width: 13)

                    Text("Other")
                        .font(Constants.body(size: 11, weight: .medium))
                        .foregroundStyle(OverlayStyle.textMuted)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 5)
                .background(isCustom ? OverlayStyle.selectedBg : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)

            if isCustom {
                TextField("Type your answer...", text: Binding(
                    get: { customInputs[question.question] ?? "" },
                    set: { customInputs[question.question] = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(OverlayStyle.textPrimary)
                .padding(3)
                .background(OverlayStyle.inputBg)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .padding(.leading, 22)
            }
        }
    }
}

// MARK: - ExitPlanMode View

struct ExitPlanModeView: View {
    let permission: PendingPermission
    let onDecision: (PermissionDecision) -> Void
    let onFeedback: ((String) -> Void)?
    let onAllowWithPermissions: (([PermissionSuggestion]) -> Void)?
    let onLater: () -> Void

    @State private var selectedOption = 1
    @State private var feedbackText = ""
    @State private var isExpanded = false
    @State private var planContent: String?

    private let options = [
        "Yes, clear context and auto-accept edits",
        "Yes, auto-accept edits",
        "Yes, manually approve edits",
        "Tell Claude what to change",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Header
            HStack {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(OverlayStyle.orange)
                Text("Plan Ready")
                    .font(Constants.heading(size: 11, weight: .bold))
                    .foregroundStyle(OverlayStyle.textPrimary)

                Spacer()

                Button { focusTerminal(pid: permission.event.terminalPid) } label: {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(OverlayStyle.textHint)
                }
                .buttonStyle(.plain)
                .help("Open terminal")

                Button { onLater() } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(OverlayStyle.textHint)
                }
                .buttonStyle(.plain)
                .help("Handle later")
            }

            // Plan content (rendered as markdown)
            if let content = planContent {
                if isExpanded {
                    ScrollView(.vertical, showsIndicators: true) {
                        markdownText(content)
                            .font(.system(size: 10))
                            .foregroundStyle(OverlayStyle.textPrimary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(5)
                    .background(OverlayStyle.codeBg)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(OverlayStyle.codeBorder, lineWidth: 1))
                    .contentShape(Rectangle())
                    .onTapGesture { isExpanded = false }

                    Text("tap to collapse")
                        .font(.system(size: 9))
                        .foregroundStyle(OverlayStyle.textHint)
                } else {
                    let preview = content.split(separator: "\n", omittingEmptySubsequences: false)
                        .prefix(4)
                        .joined(separator: "\n")

                    markdownText(preview)
                        .font(.system(size: 10))
                        .foregroundStyle(OverlayStyle.textPrimary.opacity(0.75))
                        .lineLimit(4)
                        .padding(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(OverlayStyle.codeBg)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(OverlayStyle.codeBorder, lineWidth: 1))
                        .contentShape(Rectangle())
                        .onTapGesture { isExpanded = true }

                    Text("tap to expand full plan")
                        .font(.system(size: 9))
                        .foregroundStyle(OverlayStyle.textHint)
                }
            } else {
                Text("Plan file not found")
                    .font(.system(size: 10))
                    .foregroundStyle(OverlayStyle.textMuted)
            }

            // Options
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(options.enumerated()), id: \.offset) { idx, label in
                    Button {
                        selectedOption = idx
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: selectedOption == idx ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(selectedOption == idx ? OverlayStyle.orange : OverlayStyle.radioBorder)
                                .frame(width: 13)

                            Text(label)
                                .font(Constants.body(size: 11, weight: .medium))
                                .foregroundStyle(OverlayStyle.textPrimary)

                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 5)
                        .background(selectedOption == idx ? OverlayStyle.selectedBg : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }

                if selectedOption == 3 {
                    TextField("Type your feedback...", text: $feedbackText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(OverlayStyle.textPrimary)
                        .padding(3)
                        .background(OverlayStyle.inputBg)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .padding(.leading, 22)
                }
            }

            // Approve / Deny
            HStack(spacing: 5) {
                Button {
                    if selectedOption == 3 && !feedbackText.isEmpty {
                        onFeedback?(feedbackText)
                    } else if selectedOption <= 1 {
                        let autoAccept = [
                            PermissionSuggestion(type: "setMode", destination: "session", behavior: nil, rules: nil, mode: "acceptEdits"),
                        ]
                        onAllowWithPermissions?(autoAccept)
                    } else {
                        onDecision(.allow)
                    }
                } label: {
                    Text("Approve")
                        .font(Constants.heading(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            (selectedOption == 3 && feedbackText.isEmpty)
                                ? Color.gray.opacity(0.3)
                                : OverlayStyle.orange
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(selectedOption == 3 && feedbackText.isEmpty)

                Button {
                    onDecision(.deny)
                } label: {
                    Text("Deny")
                        .font(Constants.heading(size: 11, weight: .semibold))
                        .foregroundStyle(OverlayStyle.denyText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(OverlayStyle.denyBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .padding(.bottom, OverlayStyle.tailHeight)
        .background(OverlayStyle.cardBg)
        .clipShape(SpeechBubbleShape())
        .shadow(color: OverlayStyle.cardShadow, radius: 3, x: 0, y: 2)
        .onAppear {
            planContent = permission.planFileContent
        }
    }
}

// MARK: - Standard Permission Prompt (Allow/Deny)

struct PermissionPromptView: View {
    let permission: PendingPermission
    let onDecision: (PermissionDecision) -> Void
    let onAnswers: (([String: String]) -> Void)?
    let onFeedback: ((String) -> Void)?
    let onAllowWithPermissions: (([PermissionSuggestion]) -> Void)?
    let onLater: () -> Void

    init(permission: PendingPermission, onDecision: @escaping (PermissionDecision) -> Void, onAnswers: (([String: String]) -> Void)? = nil, onFeedback: ((String) -> Void)? = nil, onAllowWithPermissions: (([PermissionSuggestion]) -> Void)? = nil, onLater: @escaping () -> Void) {
        self.permission = permission
        self.onDecision = onDecision
        self.onAnswers = onAnswers
        self.onFeedback = onFeedback
        self.onAllowWithPermissions = onAllowWithPermissions
        self.onLater = onLater
    }

    @State private var isExpanded = false

    var body: some View {
        if permission.event.toolName == "ExitPlanMode" {
            ExitPlanModeView(
                permission: permission,
                onDecision: onDecision,
                onFeedback: onFeedback,
                onAllowWithPermissions: onAllowWithPermissions,
                onLater: onLater
            )
        } else if let questions = permission.parsedQuestions, !questions.isEmpty {
            AskUserQuestionView(
                permission: permission,
                questions: questions,
                onAnswer: { answers in onAnswers?(answers) },
                onDeny: { onDecision(.deny) },
                onLater: onLater
            )
        } else {
            standardPermissionView
        }
    }

    private var standardPermissionView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: tool name + terminal + later button
            HStack {
                Text(permission.toolName)
                    .font(Constants.heading(size: 11, weight: .bold))
                    .foregroundStyle(OverlayStyle.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule().stroke(OverlayStyle.orangeBorder, lineWidth: 1))

                Spacer()

                Button { focusTerminal(pid: permission.event.terminalPid) } label: {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(OverlayStyle.textHint)
                }
                .buttonStyle(.plain)
                .help("Open terminal")

                Button { onLater() } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(OverlayStyle.textHint)
                }
                .buttonStyle(.plain)
                .help("Handle later")
            }

            // Code preview
            if isExpanded {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(permission.fullToolInputText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(OverlayStyle.textPrimary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .padding(5)
                .background(OverlayStyle.codeBg)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(OverlayStyle.codeBorder, lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { isExpanded = false }

                Text("tap to collapse")
                    .font(.system(size: 9))
                    .foregroundStyle(OverlayStyle.textHint)
            } else {
                Text(permission.toolInputPreview)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(OverlayStyle.textPrimary.opacity(0.75))
                    .lineLimit(2)
                    .padding(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(OverlayStyle.codeBg)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(OverlayStyle.codeBorder, lineWidth: 1))
                    .contentShape(Rectangle())
                    .onTapGesture { isExpanded = true }
            }

            // Buttons: Allow / Deny
            let suggestions = permission.permissionSuggestions

            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    Button {
                        onDecision(.allow)
                    } label: {
                        Text("Allow")
                            .font(Constants.heading(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(OverlayStyle.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)

                    Button {
                        onDecision(.deny)
                    } label: {
                        Text("Deny")
                            .font(Constants.heading(size: 11, weight: .semibold))
                            .foregroundStyle(OverlayStyle.denyText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(OverlayStyle.denyBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                // "Always allow" suggestions
                ForEach(suggestions) { suggestion in
                    Button {
                        onAllowWithPermissions?([suggestion])
                    } label: {
                        Text(suggestion.displayLabel)
                            .font(Constants.body(size: 10, weight: .medium))
                            .foregroundStyle(OverlayStyle.denyText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                            .background(Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(OverlayStyle.denyBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .padding(.bottom, OverlayStyle.tailHeight)
        .background(OverlayStyle.cardBg)
        .clipShape(SpeechBubbleShape())
        .shadow(color: OverlayStyle.cardShadow, radius: 3, x: 0, y: 2)
    }
}

// MARK: - Collapsed Permission Pill

/// Compact pill shown when user clicks "Later" — tap to re-expand
private struct CollapsedPermissionPill: View {
    let permission: PendingPermission
    let onExpand: () -> Void
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 9))
                .foregroundStyle(OverlayStyle.orange)

            Text(permission.toolName)
                .font(Constants.heading(size: 10, weight: .bold))
                .foregroundStyle(OverlayStyle.textPrimary)

            Text(permission.toolInputPreview)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(OverlayStyle.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            Button { focusTerminal(pid: permission.event.terminalPid) } label: {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(OverlayStyle.textHint)
            }
            .buttonStyle(.plain)
            .help("Open terminal")

            Button { onAllow() } label: {
                Text("Allow")
                    .font(Constants.heading(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(OverlayStyle.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)

            Button { onDeny() } label: {
                Text("Deny")
                    .font(Constants.heading(size: 9, weight: .semibold))
                    .foregroundStyle(OverlayStyle.denyText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(OverlayStyle.denyBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(OverlayStyle.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: OverlayStyle.cardShadow, radius: 2, x: 0, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { onExpand() }
    }
}

// MARK: - Permission Stack Container

struct PermissionStackView: View {
    @Environment(PendingPermissionStore.self) var pendingPermissionStore

    var body: some View {
        if !pendingPermissionStore.pending.isEmpty {
            VStack(spacing: 4) {
                // Bulk actions when multiple pending
                if pendingPermissionStore.pending.count > 1 {
                    HStack(spacing: 6) {
                        Text("\(pendingPermissionStore.pending.count) pending")
                            .font(Constants.body(size: 10, weight: .medium))
                            .foregroundStyle(OverlayStyle.textMuted)

                        Spacer()

                        Button {
                            pendingPermissionStore.resolveAll(decision: .allow)
                        } label: {
                            Text("Allow All")
                                .font(Constants.heading(size: 10, weight: .semibold))
                                .foregroundStyle(OverlayStyle.orange)
                        }
                        .buttonStyle(.plain)

                        Button {
                            pendingPermissionStore.resolveAll(decision: .deny)
                        } label: {
                            Text("Deny All")
                                .font(Constants.heading(size: 10, weight: .semibold))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                }

                ForEach(pendingPermissionStore.pending.reversed()) { perm in
                    if pendingPermissionStore.collapsed.contains(perm.id) {
                        CollapsedPermissionPill(
                            permission: perm,
                            onExpand: { pendingPermissionStore.expand(id: perm.id) },
                            onAllow: { pendingPermissionStore.resolve(id: perm.id, decision: .allow) },
                            onDeny: { pendingPermissionStore.resolve(id: perm.id, decision: .deny) }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    } else {
                        PermissionPromptView(
                            permission: perm,
                            onDecision: { decision in
                                pendingPermissionStore.resolve(id: perm.id, decision: decision)
                            },
                            onAnswers: { answers in
                                pendingPermissionStore.resolveWithAnswers(id: perm.id, answers: answers)
                            },
                            onFeedback: { feedback in
                                pendingPermissionStore.resolveWithFeedback(id: perm.id, feedback: feedback)
                            },
                            onAllowWithPermissions: { suggestions in
                                pendingPermissionStore.resolveWithPermissions(id: perm.id, suggestions: suggestions)
                            },
                            onLater: {
                                pendingPermissionStore.collapse(id: perm.id)
                            }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: pendingPermissionStore.pending.count)
        }
    }
}
