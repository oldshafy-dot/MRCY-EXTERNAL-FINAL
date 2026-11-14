import SwiftUI
import UIKit

enum AppTheme {
    static let accent = Color.black
    static let accentDeep = Color.black
    static let accentGradient = LinearGradient(
        colors: [accent, accentDeep],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let pageBackground = Color(red: 0.98, green: 0.66, blue: 0.06)
    static let consoleBackground = Color.black.opacity(0.55)
    static let card = Color.white.opacity(0.34)
    static let optionSurface = Color.white.opacity(0.34)
    static let cardSelected = accent
    static let primaryText = Color.black
    static let secondaryText = Color.black.opacity(0.68)
    static let tertiaryText = Color.black.opacity(0.50)
    static let hairline = Color.black

    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 24
    static let rowPadding: CGFloat = 16
    static let pageInset: CGFloat = 20
    static let rowIconSize: CGFloat = 17
    static let rowIconFrame: CGFloat = 28
    static let fileRowIconSize: CGFloat = 17
    static let fileRowIconFrame: CGFloat = 30
    static let fileRowHeight: CGFloat = 60
    static let appIconSize: CGFloat = 32
    static let emptyIconSize: CGFloat = 30
    static let selectionIconSize: CGFloat = 18
    static let contentCardCornerRadius: CGFloat = 16
    static let contentCardInset: CGFloat = 16
    static let contentCardPadding: CGFloat = 16
}

struct AppCardBorder: View {
    var body: some View {
        RoundedRectangle(
            cornerRadius: AppTheme.contentCardCornerRadius,
            style: .continuous
        )
        .strokeBorder(
            Color.black,
            lineWidth: 0.5
        )
        .accessibilityHidden(true)
    }
}

struct AppRowIcon: View {
    let systemName: String
    var tint: Color = AppTheme.accent
    var symbolSize: CGFloat = AppTheme.rowIconSize
    var frameSize: CGFloat = AppTheme.rowIconFrame

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.12))
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: frameSize, height: frameSize)
        .accessibilityHidden(true)
    }
}

struct AppSearchField: View {
    @Binding var text: String
    let prompt: String
    let clearLabel: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(clearLabel)
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 36)
        .background(
            Color(uiColor: .secondarySystemFill),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(.horizontal, AppTheme.pageInset)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct VitaTitleWordmark: View {
    var maxWidth: CGFloat = 240
    var alignment: Alignment = .center

    var body: some View {
        Group {
            if let mark = UIImage(named: "TitleWordmark") {
                Image(uiImage: mark)
                    .resizable()
                    .scaledToFit()
            } else {
                VStack(spacing: 8) {
                    Text("Panda Injector")
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundStyle(Color.black)
                    Text("SECURE ACCESS. SAFEST.")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(Color.black.opacity(0.68))
                }
            }
        }
        .frame(maxWidth: maxWidth, alignment: alignment)
        .accessibilityLabel("Panda Injector")
    }
}

struct PandaLogoMark: View {
    var size: CGFloat = 92

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black)
                .frame(width: size, height: size)
            Circle()
                .fill(Color.white)
                .frame(width: size * 0.78, height: size * 0.68)
                .offset(y: size * 0.06)
            Circle()
                .fill(Color.black)
                .frame(width: size * 0.24, height: size * 0.28)
                .offset(x: -size * 0.23, y: -size * 0.25)
            Circle()
                .fill(Color.black)
                .frame(width: size * 0.24, height: size * 0.28)
                .offset(x: size * 0.23, y: -size * 0.25)
            Circle()
                .fill(Color.black)
                .frame(width: size * 0.12, height: size * 0.12)
                .offset(x: -size * 0.16, y: size * 0.02)
            Circle()
                .fill(Color.black)
                .frame(width: size * 0.12, height: size * 0.12)
                .offset(x: size * 0.16, y: size * 0.02)
            Capsule()
                .fill(Color.black)
                .frame(width: size * 0.18, height: size * 0.10)
                .offset(y: size * 0.20)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Panda Injector")
    }
}

struct AppLogo: View {
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let icon = UIImage(named: "AppLogo")
                ?? UIImage(named: "AppIcon")
                ?? UIImage(named: "AppIcon60x60") {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "bolt.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

enum VitaGame: String, CaseIterable, Identifiable, Hashable {
    case freeFire
    case freeFireMax

    var id: String { rawValue }

    var slug: String {
        switch self {
        case .freeFire: return "free-fire"
        case .freeFireMax: return "free-fire-max"
        }
    }

    var title: String {
        switch self {
        case .freeFire: return "Free Fire"
        case .freeFireMax: return "Free Fire MAX"
        }
    }

    var subtitle: String {
        switch self {
        case .freeFire: return "Unlock your potential"
        case .freeFireMax: return "Maximize your experience"
        }
    }

    var eyebrow: String {
        title.uppercased()
    }

    var assetName: String {
        switch self {
        case .freeFire: return "GameIconFreeFire"
        case .freeFireMax: return "GameIconFreeFireMax"
        }
    }
}

enum FunctionGlyph {
    static func symbol(icon: String?, name: String) -> String {
        if let icon, let mapped = symbols[icon] {
            return mapped
        }
        let hay = name.lowercased()
        if hay.contains("aim") { return "scope" }
        if hay.contains("esp") || hay.contains("vision") { return "eye.fill" }
        if hay.contains("recoil") { return "line.3.horizontal" }
        if hay.contains("spread") { return "plus.viewfinder" }
        if hay.contains("reload") || hay.contains("bolt") { return "bolt.fill" }
        if hay.contains("speed") || hay.contains("run") { return "figure.run" }
        if hay.contains("ban") || hay.contains("shield") { return "shield.fill" }
        if hay.contains("shake") || hay.contains("iphone") { return "iphone" }
        return "slider.horizontal.3"
    }

    private static let symbols: [String: String] = [
        "aim": "scope",
        "vision": "eye.fill",
        "recoil": "line.3.horizontal",
        "spread": "plus.viewfinder",
        "reload": "bolt.fill",
        "speed": "figure.run",
        "shield": "shield.fill",
        "device": "iphone",
        "target": "target",
        "radar": "dot.radiowaves.left.and.right",
        "lock": "lock.fill",
        "flame": "flame.fill",
        "spark": "sparkles",
        "hand": "hand.raised.fill",
        "signal": "antenna.radiowaves.left.and.right",
        "slider": "slider.horizontal.3",
    ]
}

struct GameIcon: View {
    let game: VitaGame
    var size: CGFloat = 52

    var body: some View {
        Group {
            if let icon = UIImage(named: game.assetName) {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.card)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct ContentGameIcon: View {
    let game: ContentGameDescriptor
    var size: CGFloat = 52

    private var uploadedImage: UIImage? {
        guard game.icon.hasPrefix("data:image"),
              let comma = game.icon.firstIndex(of: ",") else { return nil }
        let payload = String(game.icon[game.icon.index(after: comma)...])
        guard let data = Data(base64Encoded: payload) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        Group {
            if let uploadedImage {
                Image(uiImage: uploadedImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.card)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

enum VitaTab: Int, CaseIterable, Hashable {
    case home
    case game
    case cmd

    var title: String {
        switch self {
        case .home: return "Home"
        case .game: return "Game"
        case .cmd: return "CMD"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .game: return "gamecontroller"
        case .cmd: return "terminal"
        }
    }

    var selectedIcon: String {
        switch self {
        case .home: return "house.fill"
        case .game: return "gamecontroller.fill"
        case .cmd: return "terminal.fill"
        }
    }

    func localizedTitle(_ language: AppLanguage) -> String {
        switch self {
        case .home: return language.text("home")
        case .game: return language.text("game")
        case .cmd: return language.text("cmd")
        }
    }
}

struct VitaCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            AppTheme.card,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppTheme.hairline, lineWidth: 0.5)
        }
    }
}

struct VitaCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.hairline)
            .frame(height: 0.5)
            .padding(.leading, AppTheme.rowPadding)
            .accessibilityHidden(true)
    }
}

struct VitaInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .foregroundStyle(AppTheme.primaryText)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 14))
        .padding(.horizontal, AppTheme.rowPadding)
        .padding(.vertical, 10)
        .frame(minHeight: 42)
        .accessibilityElement(children: .combine)
    }
}

struct VitaProfileIcon: View {
    let systemName: String
    var tint: Color = AppTheme.accent

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.14))
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }
}

struct VitaProfileRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var badge: String? = nil
    var badgeColor: Color = Color(red: 0.22, green: 0.86, blue: 0.48)

    var body: some View {
        HStack(spacing: 12) {
            VitaProfileIcon(systemName: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            Spacer(minLength: 8)
            if let badge {
                Text(badge)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(badgeColor.opacity(0.16), in: Capsule())
            } else if let value {
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
    }
}

struct VitaProfileCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            Color.black.opacity(0.62),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}

struct VitaSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(AppTheme.secondaryText)
            .padding(.horizontal, 4)
    }
}

struct VitaLiquidTabBar: View {
    @Binding var selection: VitaTab
    @Environment(\.appLanguage) private var appLanguage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectedTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(VitaTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(height: 62)
        .frame(maxWidth: 360)
        .background { glassCapsule }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
        .frame(maxWidth: .infinity)
    }

    private var glassCapsule: some View {
        Capsule()
            .fill(AppTheme.pageBackground.opacity(0.95))
            .overlay {
                Capsule()
                    .strokeBorder(AppTheme.hairline, lineWidth: 0.5)
            }
    }

    private func tabButton(_ tab: VitaTab) -> some View {
        let selected = selection == tab
        return Button {
            guard selection != tab else { return }
            withAnimation(
                reduceMotion
                    ? .easeOut(duration: 0.15)
                    : .spring(response: 0.36, dampingFraction: 0.86)
            ) {
                selection = tab
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? tab.selectedIcon : tab.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .frame(width: 18, height: 18)
                Text(tab.localizedTitle(appLanguage))
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.92))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if selected {
                    Capsule()
                        .fill(AppTheme.accent)
                        .matchedGeometryEffect(id: "selected-tab", in: selectedTab)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(tab.localizedTitle(appLanguage))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PandaBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 1.0, green: 0.78, blue: 0.16),
                        Color(red: 0.96, green: 0.48, blue: 0.04)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: proxy.size.width * 0.9)
                    .offset(x: proxy.size.width * 0.42, y: -proxy.size.height * 0.18)
                Circle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: proxy.size.width * 0.8)
                    .offset(x: -proxy.size.width * 0.45, y: proxy.size.height * 0.38)
                ForEach(0..<22, id: \.self) { index in
                    Image(systemName: "star.fill")
                        .font(.system(size: CGFloat(5 + index % 5), weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.18))
                        .offset(
                            x: CGFloat((index * 67) % 240) - 120,
                            y: CGFloat((index * 113) % 780) - 390
                        )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct MercyStarsBackground: View {
    var body: some View { PandaBackground() }
}

