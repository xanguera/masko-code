import SwiftUI

struct OnboardingView: View {
    @Environment(AppStore.self) var appStore
    @Environment(OverlayManager.self) var overlayManager

    let onComplete: () -> Void

    @State private var step = 0
    @State private var hookInstalled = false
    @State private var hookError: String?
    @State private var mascotActivated = false

    private let totalSteps = 4

    /// Advance to the next step that actually needs user action, skipping already-completed ones.
    private func nextStep(after current: Int) {
        var next = current + 1
        // Skip hooks step if already installed
        if next == 1 && hookInstalled { next = 2 }
        // Step 2 (notifications) and 3 (mascot) always show
        step = min(next, totalSteps - 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Group {
                switch step {
                case 0: welcomeStep
                case 1: hooksStep
                case 2: notificationsStep
                case 3: mascotStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: 440)
            .transition(.opacity)
            .id(step)

            Spacer()

            // Step indicator dots
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Constants.orangePrimary : Constants.border)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Constants.lightBackground)
        .animation(.easeInOut(duration: 0.3), value: step)
        .onAppear {
            hookInstalled = HookInstaller.isRegistered()
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            if let url = Bundle.module.url(forResource: "logo", withExtension: "png", subdirectory: "Images"),
               let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 72)
            }

            VStack(spacing: 4) {
                Text("Welcome to Masko")
                    .font(Constants.heading(size: 28, weight: .bold))
                    .foregroundStyle(Constants.textPrimary)
                Text("for Claude Code")
                    .font(Constants.heading(size: 18, weight: .semibold))
                    .foregroundStyle(Constants.textMuted)
            }

            Text("Masko lives on your screen, reacts to Claude Code activity, and lets you approve actions without switching windows.")
                .font(Constants.body(size: 14))
                .foregroundStyle(Constants.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)

            primaryButton("Get Started") {
                nextStep(after: 0)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Step 1: Enable Hooks

    private var hooksStep: some View {
        VStack(spacing: 20) {
            stepIcon(hookInstalled ? "checkmark.circle.fill" : "terminal.fill",
                     color: hookInstalled ? .green : Constants.orangePrimary)

            VStack(spacing: 8) {
                Text("Connect to Claude Code")
                    .font(Constants.heading(size: 24, weight: .bold))
                    .foregroundStyle(Constants.textPrimary)

                Text("Masko listens to Claude Code events via hooks. This adds a small config to ~/.claude/settings.json.")
                    .font(Constants.body(size: 14))
                    .foregroundStyle(Constants.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }

            if let error = hookError {
                Text(error)
                    .font(Constants.body(size: 12))
                    .foregroundStyle(.red)
            }

            if hookInstalled {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Hooks enabled")
                        .font(Constants.body(size: 14, weight: .medium))
                        .foregroundStyle(.green)
                }

                primaryButton("Continue") {
                    nextStep(after: 1)
                }
            } else {
                primaryButton("Enable Hooks") {
                    enableHooks()
                }

                skipButton { nextStep(after: 1) }
            }
        }
    }

    // MARK: - Step 2: Notifications

    private var notificationsStep: some View {
        VStack(spacing: 20) {
            stepIcon("bell.fill", color: Constants.orangePrimary)

            VStack(spacing: 8) {
                Text("Stay in the loop")
                    .font(Constants.heading(size: 24, weight: .bold))
                    .foregroundStyle(Constants.textPrimary)

                Text("Get notified when Claude Code needs your attention \u{2014} permission requests, questions, and completed tasks.")
                    .font(Constants.body(size: 14))
                    .foregroundStyle(Constants.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }

            primaryButton("Enable Notifications") {
                Task {
                    await appStore.notificationService.requestPermission()
                    nextStep(after: 2)
                }
            }

            skipButton { nextStep(after: 2) }
        }
    }

    // MARK: - Step 3: Activate Mascot

    private var mascotStep: some View {
        VStack(spacing: 20) {
            stepIcon(mascotActivated ? "checkmark.circle.fill" : "wand.and.stars",
                     color: mascotActivated ? .green : Constants.orangePrimary)

            VStack(spacing: 8) {
                Text("Meet your mascot")
                    .font(Constants.heading(size: 24, weight: .bold))
                    .foregroundStyle(Constants.textPrimary)

                if let mascot = appStore.mascotStore.mascots.first {
                    Text("Your \"\(mascot.name)\" mascot will appear on screen and react to Claude Code in real time.")
                        .font(Constants.body(size: 14))
                        .foregroundStyle(Constants.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                } else {
                    Text("You can add a mascot later from the Masko tab.")
                        .font(Constants.body(size: 14))
                        .foregroundStyle(Constants.textMuted)
                        .multilineTextAlignment(.center)
                }
            }

            if mascotActivated {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Mascot activated!")
                        .font(Constants.body(size: 14, weight: .medium))
                        .foregroundStyle(.green)
                }
            } else if appStore.mascotStore.mascots.first != nil {
                primaryButton("Activate Mascot") {
                    activateMascot()
                }
            }

            if mascotActivated {
                primaryButton("Let's go!") {
                    onComplete()
                }
            } else {
                skipButton { onComplete() }
            }
        }
    }

    // MARK: - Shared Components

    private func stepIcon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 48))
            .foregroundStyle(color)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Constants.heading(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: 280)
                .padding(.vertical, 14)
                .background(Constants.orangePrimary)
                .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadius))
                .shadow(color: Constants.orangeShadow, radius: 0, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }

    private func skipButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Skip")
                .font(Constants.body(size: 13, weight: .medium))
                .foregroundStyle(Constants.textMuted)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func enableHooks() {
        hookError = nil
        do {
            try HookInstaller.install()
            hookInstalled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                nextStep(after: 1)
            }
        } catch {
            hookError = error.localizedDescription
        }
    }

    private func activateMascot() {
        guard let mascot = appStore.mascotStore.mascots.first else { return }
        overlayManager.showOverlayWithConfig(mascot.config)
        mascotActivated = true
    }
}
