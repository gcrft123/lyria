import SwiftUI

// MARK: - Act 3 · Permissions (fully user-paced)

struct PermissionsAct: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    let accent: Color
    @State private var asked = false

    private var permission: OnboardingPermission? { coordinator.currentPermission }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("Borrow a few senses")
                    .font(Typography.subheadline).foregroundStyle(Palette.textPrimary)
                Spacer()
                Text("\(coordinator.permissionIndex + 1) of \(coordinator.permissions.count)")
                    .font(Typography.captionMono).foregroundStyle(Palette.textTertiary)
            }

            Spacer(minLength: Spacing.zero)

            if let permission {
                HStack(alignment: .center, spacing: Spacing.xl) {
                    sensePreview(glyph: permission.glyph, active: asked)
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text(permission.title)
                            .font(Typography.bodyStrong).foregroundStyle(Palette.textPrimary)
                        Text(permission.reason)
                            .font(Typography.footnote).foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        actions(for: permission).padding(.top, Spacing.xs)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(coordinator.permissionIndex)   // re-inserts the card view per permission
            }

            Spacer(minLength: Spacing.zero)

            Text("Everything stays on your Mac — grant only what you want.")
                .font(Typography.footnote).foregroundStyle(Palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .actPadding()
        // `asked` is owned by this act view, so the `.id` on the card above can't
        // reset it — without this every card after the first would skip straight to
        // "Next / Open Settings again" and never fire its actual grant. Reset it
        // whenever the active permission changes (forward via Next, back via Back).
        .onChange(of: coordinator.permissionIndex) { _ in asked = false }
    }

    private func sensePreview(glyph: String, active: Bool) -> some View {
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .fill(active ? accent.opacity(0.18) : Palette.surfaceSubtle)
            .frame(width: Layout.onboardingPreview, height: Layout.onboardingPreview)
            .overlay {
                Image(systemName: glyph)
                    .font(.system(size: IconSize.xxxl))
                    .foregroundStyle(active ? accent : Palette.textFaint)
                    .saturation(active ? 1 : 0)
            }
            .animation(Motion.transition, value: active)
    }

    @ViewBuilder
    private func actions(for permission: OnboardingPermission) -> some View {
        if asked {
            HStack(spacing: Spacing.xxl) {
                OnboardingPill(title: coordinator.isLastPermission ? "Continue" : "Next",
                               icon: "chevron.right", accent: accent) {
                    coordinator.nextPermission()
                }
                OnboardingLink(title: "Open Settings again") { coordinator.openSettingsForCurrent() }
            }
        } else {
            HStack(spacing: Spacing.xxl) {
                OnboardingPill(title: "Grant", icon: "arrow.up.forward", accent: accent) {
                    coordinator.grantCurrent(); asked = true
                }
                OnboardingLink(title: permission.isOptional ? "Skip" : "Maybe later") {
                    coordinator.nextPermission()
                }
            }
        }
    }
}

// MARK: - Act 4 · Personalize

struct PersonalizeAct: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    @EnvironmentObject var settings: AppSettings
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text("Make it yours")
                .font(Typography.subheadline).foregroundStyle(Palette.textPrimary)

            HStack {
                Text("Tint with album art").font(Typography.bodyRegular).foregroundStyle(Palette.textPrimary)
                Spacer()
                Toggle("", isOn: $settings.tintWithArtwork)
                    .labelsHidden().toggleStyle(.switch).tint(accent)
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Open the island on").font(Typography.footnote).foregroundStyle(Palette.textSecondary)
                Picker("", selection: $settings.expandTrigger) {
                    ForEach(AppSettings.ExpandTrigger.allCases) { t in Text(t.label).tag(t) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Text("Glow").font(Typography.footnote).foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Text("\(Int(settings.glowIntensity * 100))%")
                        .font(Typography.footnoteMono).foregroundStyle(Palette.textTertiary)
                }
                Slider(value: $settings.glowIntensity, in: 0...1).tint(accent)
            }

            Spacer(minLength: Spacing.zero)
            HStack {
                Spacer()
                OnboardingPill(title: "Continue", icon: "chevron.right", accent: accent) { coordinator.advancePhase() }
            }
        }
        .actPadding()
    }
}

// MARK: - Act 5 · Try me (a list of tips, then Continue)

struct TryMeAct: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("A few things to try")
                .font(Typography.subheadline).foregroundStyle(Palette.textPrimary)
            Spacer(minLength: Spacing.zero)
            VStack(alignment: .leading, spacing: Spacing.lg) {
                ForEach(TryStep.allCases) { step in
                    HStack(spacing: Spacing.lg) {
                        Image(systemName: step.glyph)
                            .font(.system(size: IconSize.lg))
                            .foregroundStyle(accent)
                            .frame(width: 26, alignment: .center)
                        Text(step.prompt)
                            .font(Typography.bodyRegular)
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Spacing.zero)
                    }
                }
            }
            Spacer(minLength: Spacing.zero)
            HStack {
                Spacer()
                OnboardingPill(title: "Continue", icon: "chevron.right", accent: accent) { coordinator.advancePhase() }
            }
        }
        .actPadding()
    }
}

// MARK: - Act 6 · Finale

struct FinaleAct: View {
    let accent: Color
    let reduceMotion: Bool
    let onDone: () -> Void
    @State private var burst = false

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer(minLength: Spacing.zero)
            ZStack {
                if !reduceMotion {
                    ForEach(0..<12, id: \.self) { i in
                        let angle = Double(i) / 12 * 2 * .pi
                        Circle().fill(accent)
                            .frame(width: 6, height: 6)
                            .offset(x: cos(angle) * (burst ? 60 : 0), y: sin(angle) * (burst ? 60 : 0))
                            .opacity(burst ? 0 : 1)
                    }
                }
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: IconSize.xxxl, weight: .bold))
                    .foregroundStyle(accent)
                    .scaleEffect(burst ? 1 : 0.5)
            }
            .frame(height: Layout.onboardingPreview)
            Text("You're all set")
                .font(Typography.title).foregroundStyle(Palette.textPrimary)
            Text("I'll be right here. The gear in the sidebar changes all this.")
                .font(Typography.footnote).foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: Spacing.zero)
            OnboardingPill(title: "Enter", accent: accent, action: onDone)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .actPadding()
        .onAppear { withAnimation(reduceMotion ? Motion.reduced : Motion.pop) { burst = true } }
    }
}
