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
            controller.recordActivity("Login/session verified")
            controller.refresh(items: items)
            controller.recordActivity("\(items.count) patch/function item(s) available")
            restoreLeftoverPatchesIfNeeded()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await contentUpdates.checkForUpdates(session: licenseSession, store: store) }
            }
        }
        .task {
            await contentUpdates.checkForUpdates(session: licenseSession, store: store)
            controller.recordActivity("Online patch data checked")
        }
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
                        controller.recordActivity("Selected app: " + game.name)
                    } label: {
                        HStack(spacing: 14) {
                            ContentGameIcon(game: game, size: 52)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(game.name)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(Color.white)
                                Text(gameSubtitle(for: game))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.72))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(AppTheme.accent)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.black, lineWidth: 1)
                    }
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
                        .foregroundStyle(Color.white)
                    if !description.isEmpty {
                        Text(description)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.72))
                    }
                }
                Spacer()
                Text(injected ? appLanguage.text("injected") : appLanguage.text("ready"))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(injected ? Color.green : Color(red: 1.0, green: 0.78, blue: 0.16))
            }

            Button {
                controller.setOpen(!injected, item: item, items: items)
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(injected ? Color.green : Color(red: 1.0, green: 0.78, blue: 0.16))
                        .frame(width: 7, height: 7)
                    Text(injected ? appLanguage.text("injected") : appLanguage.text("inject"))
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    injected
                        ? Color.green.opacity(0.18)
                        : Color(red: 1.0, green: 0.78, blue: 0.16).opacity(0.18),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            injected ? Color.green.opacity(0.75) : Color(red: 1.0, green: 0.78, blue: 0.16).opacity(0.75),
                            lineWidth: 0.8
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(controller.isWorking)
            .contentShape(Rectangle())
        }
        .padding(14)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.black, lineWidth: 1)
        }
    }

    private var profilePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                AppLogo(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 0) {
                        Text(appLanguage.text("app.name"))
                            .foregroundStyle(Color.white)
                    }
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.white)
                    Text(appLanguage.text("app.subtitle"))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.72))
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
                    VitaProfileIcon(systemName: "key.fill")
                    Text(appLanguage.text("change_license"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(minHeight: 56)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.black, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VitaProfileIcon(systemName: "globe")
                    Text(appLanguage.text("change_language"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                    Spacer()
                    Text(appLanguage.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.72))
                }

                VStack(spacing: 0) {
                    ForEach(AppLanguage.allCases) { language in
                        Button {
                            languageRaw = language.rawValue
                            controller.recordActivity("Language changed to " + language.displayName)
                        } label: {
                            HStack {
                                Text(language.displayName)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color.white)
                                Spacer()
                                if language == appLanguage {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Color.green)
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 42)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if language != AppLanguage.allCases.last {
                            Divider()
                                .overlay(Color.white.opacity(0.10))
                        }
                    }
                }
                .background(Color.black, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.black, lineWidth: 1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.black, lineWidth: 1)
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
                    Color.black,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.black, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(appLanguage.text("sign_out"))
        }
        .padding(.horizontal, 2)
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
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CMD").font(.system(size: 28, weight: .heavy)).foregroundStyle(Color.white)
                    Text("LOGS").font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(Color.white)
                }
                Spacer()
                Text(String(controller.activityLogs.count))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.accent)
            }
            VStack(alignment: .leading, spacing: 8) {
                if controller.activityLogs.isEmpty {
                    logLine("No activity logs")
                } else {
                    ForEach(Array(controller.activityLogs.enumerated()), id: \.offset) { _, entry in
                        logLine(entry)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.black, lineWidth: 1)
            }
            .foregroundStyle(Color.white)

            Button {
                controller.clearActivityLogs()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                    Text("Clear All Logs")
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.black, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func logLine(_ value: String, success: Bool? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(">").font(.system(size: 12, weight: .bold, design: .monospaced))
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(
                    success == true
                        ? Color.green
                        : success == false
                            ? Color.red
                            : Color.white
                )
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

