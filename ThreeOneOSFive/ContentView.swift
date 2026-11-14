import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var store: PatchProjectStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var licenseSession: LicenseSessionController
    @EnvironmentObject private var contentUpdates: ContentUpdateController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.appLanguage) private var appLanguage
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.english.rawValue
    @State private var showLanguagePicker = false
    @StateObject private var controller = VitaPatchController()
    @State private var tab: VitaTab = .game
    @State private var selectedGameID: String?
    @State private var showNotice = true
    @State private var noticeMessage = "Stay connected and get the latest updates, news, and announcements right on your bot!"
    @State private var noticeURL = URL(string: "https://t.me/roboiosbot")!

    private var busy: Bool { store.isBusy || controller.isWorking }
    private var items: [PatchLibraryItem] { store.items }

    private var availableGames: [ContentGameDescriptor] {
        contentUpdates.games.filter { game in
            game.slug == "free-fire" || game.slug == "free-fire-max"
        }
    }
    private var selectedGame: ContentGameDescriptor? {
        guard let selectedGameID else { return nil }
        return availableGames.first(where: { $0.id == selectedGameID })
    }

    private func items(for game: ContentGameDescriptor) -> [PatchLibraryItem] {
        items
            .filter { item in
                ContentFunctionMetadataStore.metadata(for: item.id)?.gameSlug ?? "free-fire"
                    == game.slug
            }
            .sorted { left, right in
                let leftSort = ContentFunctionMetadataStore.metadata(for: left.id)?.sort ?? .max
                let rightSort = ContentFunctionMetadataStore.metadata(for: right.id)?.sort ?? .max
                if leftSort != rightSort { return leftSort < rightSort }
                return BundledFunctionCatalog.displayName(for: left)
                    .localizedCaseInsensitiveCompare(
                        BundledFunctionCatalog.displayName(for: right)
                    ) == .orderedAscending
            }
    }

    var body: some View {
        ZStack(alignment: .top) {
            PandaBackground()

            pageScroll(profilePage)
                .opacity(tab == .home ? 1 : 0)
                .allowsHitTesting(tab == .home)
                .accessibilityHidden(tab != .home)

            pageScroll(homeGamesPage)
                .opacity(tab == .game ? 1 : 0)
                .allowsHitTesting(tab == .game)
                .accessibilityHidden(tab != .game)
                .transaction { $0.animation = nil }

            pageScroll(cmdPage)
                .opacity(tab == .cmd ? 1 : 0)
                .allowsHitTesting(tab == .cmd)
                .accessibilityHidden(tab != .cmd)

            if tab == .game && showNotice {
                LoginNoticeCard(
                    message: noticeMessage,
                    onOpen: { openURL(noticeURL) },
                    onClose: { showNotice = false }
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VitaLiquidTabBar(selection: $tab)
                .padding(.top, 6)
                .padding(.bottom, 4)
        }
        .tint(AppTheme.accent)
        .preferredColorScheme(.dark)
        .alert(
            "Panda Injector",
            isPresented: Binding(
                get: { controller.message != nil },
                set: { if !$0 { controller.message = nil } }
            )
        ) {
            Button(appLanguage.text("common.ok"), role: .cancel) { controller.message = nil }
        } message: {
            Text(controller.message ?? "")
        }

        .onAppear {
            if contentUpdates.integrityCompromised {
                RuntimeGuard.rejectTamper()
            }
            controller.licenseAllowsApply = { licenseSession.hasLiveAuthority && contentUpdates.hasVerifiedPolicy && contentUpdates.requiredRelease == nil }
            controller.requestPermit = { packageID, packageData, apply in
                try await licenseSession.authorizeWrite(
                    packageID: packageID,
                    packageData: packageData,
                    apply: apply
                )
            }
            controller.refresh(items: items)
            restoreLeftoverPatchesIfNeeded()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await contentUpdates.checkForUpdates(session: licenseSession, store: store) }
            }
        }
        .task { await contentUpdates.checkForUpdates(session: licenseSession, store: store) }
        .task {
            if let notice = await licenseSession.loginNotice() {
                noticeMessage = notice.message
                noticeURL = notice.url
            } else {
                showNotice = false
            }
        }
    }

    private func pageScroll<Content: View>(_ content: Content) -> some View {
        ScrollView {
            content
                .frame(maxWidth: 560)
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.top, 10)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private var homeGamesPage: some View {
        Group {
            if let selectedGame {
                functionPage(for: selectedGame)
            } else {
                appPickerPage
            }
        }
    }

    private var appPickerPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PANDA")
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(Color.black)
            Text(appLanguage.text("select_app"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)

            VStack(spacing: 10) {
                ForEach(availableGames, id: \.id) { game in
                    Button {
                        selectedGameID = game.id
                    } label: {
                        HStack(spacing: 14) {
                            ContentGameIcon(game: game, size: 52)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(game.name)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(Color.black)
                                Text(gameSubtitle(for: game))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Color.black.opacity(0.65))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .background(Color.white.opacity(0.32), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .transaction { transaction in transaction.animation = nil }

                }
            }
            .background(Color.clear)
        }
    }

    private func gameSubtitle(for game: ContentGameDescriptor) -> String {
        switch game.slug {
        case "free-fire": return "Normal"
        case "free-fire-max": return "MAX"
        default: return "Ready"
        }
    }

    private func functionPage(for game: ContentGameDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ContentGameIcon(game: game, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.name).font(.system(size: 20, weight: .bold)).foregroundStyle(Color.black)
                    Text(appLanguage.text("functions")).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.black)
                }
                Spacer()
                Button(appLanguage.text("change")) { selectedGameID = nil }.foregroundStyle(Color.black)
            }
            functionList(items(for: game), showSecurityTitle: game.slug == "free-fire")
        }
    }

    private func functionList(_ rows: [PatchLibraryItem], showSecurityTitle: Bool = false) -> some View {
        VStack(spacing: 12) {
            if rows.isEmpty {
                Text(appLanguage.text("no_functions"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                    if showSecurityTitle && index == rows.count - 1 {
                        Text(appLanguage.text("security"))
                            .font(.system(size: 12, weight: .heavy))
                            .tracking(1.1)
                            .foregroundStyle(Color.black)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    functionRow(item)
                }
            }
        }
    }

    private func functionRow(_ item: PatchLibraryItem) -> some View {
        let name = BundledFunctionCatalog.displayName(for: item)
        let description = ContentFunctionMetadataStore.metadata(for: item.id)?.description
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let injected = controller.isOpen(item)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.black)
                    if !description.isEmpty {
                        Text(description)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
                Spacer()
                Text(injected ? appLanguage.text("injected") : appLanguage.text("ready"))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(injected ? Color(red: 0.55, green: 0.95, blue: 0.70) : Color.black.opacity(0.65))
            }

            Button {
                controller.setOpen(!injected, item: item, items: items)
            } label: {
                Text(injected ? appLanguage.text("injected") : appLanguage.text("inject"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(injected ? Color(red: 0.55, green: 0.95, blue: 0.70) : Color.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
             .disabled(controller.isWorking)
        }
        .padding(14)
        .background(Color.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 18))
    }

    private var profilePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                AppLogo(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 0) {
                        Text(appLanguage.text("app.name"))
                            .foregroundStyle(Color.black)
                    }
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.white)
                    Text(appLanguage.text("app.subtitle"))
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }

            profileSection(appLanguage.text("device")) {
                VitaProfileRow(
                    icon: "iphone",
                    title: appLanguage.text("this_iphone"),
                    subtitle: appState.isSupported
                        ? appLanguage.text("ready_to_use")
                        : appLanguage.text("ios_not_supported"),
                    badge: appState.isSupported ? appLanguage.text("supported") : appLanguage.text("unsupported"),
                    badgeColor: compatibilityTint
                )
                VitaProfileRow(
                    icon: "iphone",
                    title: "Model",
                    value: AppInfo.hardwareDisplayName
                )
                VitaProfileRow(
                    icon: "cpu",
                    title: "iOS Version",
                    value: AppInfo.osVersion
                )
                VitaProfileRow(
                    icon: "square.stack.3d.up.fill",
                    title: "Build",
                    value: AppInfo.osBuild
                )
            }

            profileSection(appLanguage.text("license")) {
                VitaProfileRow(
                    icon: "checkmark.shield.fill",
                    title: "Status",
                    value: licenseSession.hasLiveAuthority ? appLanguage.text("active") : appLanguage.text("inactive")
                )
                VitaProfileRow(
                    icon: "calendar",
                    title: "Expiry",
                    value: profileExpiryValue
                )
            }

            profileSection(appLanguage.text("about_app")) {
                VitaProfileRow(
                    icon: "info.circle.fill",
                    title: appLanguage.text("name"),
                    value: "Panda Injector"
                )
                VitaProfileRow(
                    icon: "square.stack.3d.up.fill",
                    title: appLanguage.text("version"),
                    value: appVersion
                )
            }

            Button {
                licenseSession.logout()
            } label: {
                HStack(spacing: 12) {
                    VitaProfileIcon(systemName: "rectangle.portrait.and.arrow.right", tint: .red)
                    Text(appLanguage.text("sign_out"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.red)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(minHeight: 56)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(appLanguage.text("sign_out"))
        }
        .padding(.horizontal, 2)
        .sheet(isPresented: $showLanguagePicker) {
            LanguagePickerView(languageRaw: $languageRaw, isPresented: $showLanguagePicker)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { value in
            profileCountdownNow = value
        }
    }

    private func profileSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Color.white.opacity(0.78))
                .padding(.horizontal, 4)
            VitaProfileCard(content: content)
        }
    }

    private var cmdPage: some View {
        let patchCount = items.count
        let gameCount = availableGames.count
        return VStack(alignment: .leading, spacing: 12) {
            Text("CMD").font(.system(size: 28, weight: .heavy)).foregroundStyle(Color.black)
            Text("LOGS").font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(Color.black)
            VStack(alignment: .leading, spacing: 10) {
                logLine("Login/session verified")
                logLine("Online patch data checked")
                logLine("\(gameCount) online app option(s) loaded")
                logLine("\(patchCount) patch/function item(s) available")
                if let selectedGame { logLine("Selected app: \(selectedGame.name)") }
                let activeCount = items.filter { controller.isOpen($0) }.count
                 if activeCount > 0 { logLine("\(activeCount) function(s) injected") }
                logLine("Panda Injector ready")
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 18))
            .foregroundStyle(Color.white)
        }
    }

    private func logLine(_ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(">").font(.system(size: 12, weight: .bold, design: .monospaced))
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }

    private var compatibilityTint: Color {
        appState.isSupported ? Color(red: 0.22, green: 0.86, blue: 0.48) : .red
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var profileExpiryValue: String {
        guard let expiry = parsedProfileExpiryDate else {
            return licenseSession.profile?.expiryText ?? "—"
        }
        return expiry.formatted(date: .abbreviated, time: .omitted)
    }

    private var parsedProfileExpiryDate: Date? {
        guard let text = licenseSession.profile?.expiresAt, !text.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let precise = parser.date(from: text) {
            return precise
        }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: text)
    }

    private func remainingProfileText(until expiry: Date) -> String {
        let total = max(0, Int(expiry.timeIntervalSince(profileCountdownNow)))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        return "\(days) Days \(hours) Hours \(minutes) Minutes"
    }

    private var canAccessPatchedFiles: Bool {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 17 {
            return false
        }
        if appState.kernelExploitApplicable {
            return appState.exploitStatus.isSuccess
        }
        return appState.isSupported
    }

    private func restoreLeftoverPatchesIfNeeded() {
        controller.restoreLeftoversIfNeeded(
            items: items,
            canAccessFiles: canAccessPatchedFiles
        )
    }

}