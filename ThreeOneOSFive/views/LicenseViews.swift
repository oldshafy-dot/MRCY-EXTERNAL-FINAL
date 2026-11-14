import SwiftUI

struct LicenseGateView: View {
    @EnvironmentObject private var session: LicenseSessionController
    @EnvironmentObject private var updates: ContentUpdateController
    @EnvironmentObject private var store: PatchProjectStore

    var body: some View {
        Group {
            switch session.state {
            case .loading:
                AppLaunchLoadingView()
            case .unconfigured:
                if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 17 {
                    LicenseActivationView()
                } else {
                    Color.clear.onAppear { RuntimeGuard.seal() }
                }
            case .signedOut:
                LicenseActivationView()
            case .authenticated:
                if session.hasLiveAuthority {
                    authenticatedRoot
                } else if updates.integrityCompromised {
                    Color.clear.onAppear { RuntimeGuard.rejectTamper() }
                } else {
                    AppLaunchLoadingView()
                }
            case .blocked(let message):
                LicenseBlockedView(message: message)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await session.startIfNeeded()
            await session.renewAuthorityIfNeeded()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await session.renewAuthorityIfNeeded()
            }
        }
    }

    @ViewBuilder
    private var authenticatedRoot: some View {
        if let release = updates.requiredRelease {
            RequiredContentUpdateView(release: release)
        } else if updates.integrityCompromised {
            Color.clear.onAppear { RuntimeGuard.rejectTamper() }
        } else if updates.hasVerifiedPolicy {
            ContentView()
        } else {
            ContentPolicyVerificationView()
        }
    }

}

private struct ContentPolicyVerificationView: View {
    @EnvironmentObject private var session: LicenseSessionController
    @EnvironmentObject private var updates: ContentUpdateController
    @EnvironmentObject private var store: PatchProjectStore

    var body: some View {
        ZStack {
            AppLaunchLoadingView()
            if let error = updates.errorMessage, !updates.isChecking {
                VStack(spacing: 14) {
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.secondaryText)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task {
                            await updates.checkForUpdates(
                                session: session,
                                store: store
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updates.isChecking)
                }
                .padding(28)
            }
        }
        .task {
            await updates.checkForUpdates(session: session, store: store)
        }
    }
}

private struct AppLaunchLoadingView: View {
    var body: some View {
        ZStack {
            MercyStarsBackground()
            VStack(spacing: 0) {
                Text("Mercy iOS External")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
                Spacer()
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(AppTheme.accent)
                        .scaleEffect(1.15)
                    Text("Loading..")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.white)
                }
                Spacer()
            }
            .padding(.horizontal, 36)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading")
    }
}

struct LicenseActivationView: View {
    @EnvironmentObject private var session: LicenseSessionController
    @State private var licenseKey = ""

    var body: some View {
        ZStack {
            PandaBackground()
            ScrollView {
                VStack(spacing: 18) {
                    Spacer(minLength: 44)
                    AppLogo(size: 92)
                    Text("Panda Injector")
                        .font(.system(size: 32, weight: .heavy))
                        .foregroundStyle(Color.black)
                    Text("SECURE ACCESS. SAFEST. ENTER YOUR KEY.")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Color.black.opacity(0.72))
                        .multilineTextAlignment(.center)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ACCESS KEY")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(Color.black.opacity(0.70))
                        HStack(spacing: 10) {
                            Image(systemName: "key.fill")
                                .foregroundStyle(Color.black.opacity(0.65))
                            SecureField("Enter Access Key", text: $licenseKey)
                                .textContentType(.password)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .foregroundStyle(Color.black)
                                .disabled(session.isWorking)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 54)
                        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        Button {
                            Task {
                                await session.beginActivation(licenseKey: licenseKey)
                                if session.state == .authenticated { licenseKey = "" }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if session.isWorking { ProgressView().tint(.white) }
                                Text(session.isWorking ? "UNLOCKING…" : "UNLOCK")
                            }
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(session.isWorking || licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let error = session.errorMessage {
                            Text(error)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(18)
                    .background(Color.white.opacity(0.28), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    Text("no key? contact your seller.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.72))
                    Text("This Injector Is Made by Shafy.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.72))
                    Spacer(minLength: 44)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 430)
                .frame(maxWidth: .infinity)
            }
        }
        .tint(.black)
    }
}

struct LoginNoticeCard: View {
    let message: String
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.72))
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                Text("Open Bot")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                Text("for Daily Updates")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.top, 6)
                Text(message)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
                Button(action: onOpen) {
                    Text("Open Bot")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            AppTheme.accentGradient,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 22)
                .accessibilityLabel("Open Bot")
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(Color(red: 0.10, green: 0.10, blue: 0.11).opacity(0.72), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 28)
        }
        .accessibilityElement(children: .contain)
    }
}

struct LicenseConfigurationView: View {
    let message: String

    var body: some View {
        LicenseMessagePage<EmptyView>(
            icon: "gear.badge.xmark",
            title: "Licensing not configured",
            message: message,
            detail: "Access remains locked until a valid HTTPS server and Ed25519 key are configured."
        )
    }
}

struct LicenseBlockedView: View {
    @EnvironmentObject private var session: LicenseSessionController
    let message: String

    var body: some View {
        LicenseMessagePage(
            icon: "wifi.exclamationmark",
            title: "License unavailable",
            message: message,
            detail: "The app is locked because the session could not be securely validated."
        ) {
            Button("Retry") {
                Task { await session.retrySession() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isWorking)

            Button("Log out", role: .destructive) {
                session.logout()
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct LicenseMessagePage<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    let detail: String
    let actions: Actions

    init(
        icon: String,
        title: String,
        message: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        ZStack {
            AppTheme.pageBackground.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AppTheme.primaryText)
                Text(message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppTheme.primaryText)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.secondaryText)
                actions
            }
            .multilineTextAlignment(.center)
            .padding(28)
            .frame(maxWidth: 480)
        }
    }
}

private extension LicenseMessagePage where Actions == EmptyView {
    init(icon: String, title: String, message: String, detail: String) {
        self.init(icon: icon, title: title, message: message, detail: detail) {
            EmptyView()
        }
    }
}

struct RequiredContentUpdateView: View {
    @EnvironmentObject private var session: LicenseSessionController
    @EnvironmentObject private var updates: ContentUpdateController
    @EnvironmentObject private var store: PatchProjectStore
    let release: ContentReleaseManifest

    var body: some View {
        ZStack {
            MercyStarsBackground()
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 36) {
                        Spacer(minLength: 48)
                        Text("Panda Injector")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Color.white)
                        releaseNotes
                        if let error = updates.errorMessage {
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                                .accessibilityLabel("Update error. \(error)")
                        }
                        installButton
                        Spacer(minLength: 48)
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 430)
                    .frame(minHeight: geometry.size.height)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
        }
        .interactiveDismissDisabled()
        .preferredColorScheme(.dark)
        .task {
            await updates.checkForUpdates(session: session, store: store)
        }
    }

    private var descriptionLines: [String] {
        let lines = (release.description ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? ["Update required before functions can be used."] : lines
    }

    private var releaseNotes: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VitaProfileIcon(systemName: "doc.fill")
                Text("What's New")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text("v\(release.version)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
                .padding(.leading, 60)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(descriptionLines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(AppTheme.accent)
                            .frame(width: 6, height: 6)
                            .padding(.top, 5)
                            .accessibilityHidden(true)
                        Text(line)
                            .font(.system(size: 14))
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(
            Color.white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }

    private var installButton: some View {
        Button {
            Task {
                await updates.installRequired(session: session, store: store)
            }
        } label: {
            HStack(spacing: 10) {
                if updates.isInstalling {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "square.and.arrow.down")
                }
                Text(updates.isInstalling ? "Installing…" : "Download & Install")
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .background(AppTheme.accent, in: Capsule())
            .shadow(color: AppTheme.accent.opacity(0.45), radius: 18, y: 0)
        }
        .buttonStyle(.plain)
        .disabled(updates.isInstalling)
        .accessibilityHint("Downloads and verifies the required data packages")
    }
}
