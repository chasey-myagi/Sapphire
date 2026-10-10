import Foundation
import Combine
import SwiftUI

enum AppLanguagePreference: CaseIterable, Hashable, Identifiable {
    case followSystem, simplifiedChinese, traditionalChinese, english, existingOverride

    var id: Self { self }

    var title: String {
        switch self {
        case .followSystem: return String(localized: "Follow System")
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .existingOverride: return String(localized: "Current language setting")
        }
    }
}

struct AppLanguagePreferenceStore {
    let defaults: UserDefaults
    let domainName: String

    static var currentApp: Self {
        Self(defaults: .standard, domainName: Bundle.main.bundleIdentifier!)
    }

    var selection: AppLanguagePreference {
        guard let override = defaults.persistentDomain(forName: domainName)?["AppleLanguages"] else {
            return .followSystem
        }
        if let languages = override as? [String] {
            if languages == ["zh-Hans"] { return .simplifiedChinese }
            if languages == ["zh-Hant"] { return .traditionalChinese }
            if languages == ["en"] { return .english }
        }
        return .existingOverride
    }

    func select(_ preference: AppLanguagePreference) {
        switch preference {
        case .followSystem:
            defaults.removeObject(forKey: "AppleLanguages")
        case .simplifiedChinese:
            defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        case .traditionalChinese:
            defaults.set(["zh-Hant"], forKey: "AppleLanguages")
        case .english:
            defaults.set(["en"], forKey: "AppleLanguages")
        case .existingOverride:
            break
        }
    }
}

struct AppLanguagePicker: View {
    private let store: AppLanguagePreferenceStore
    @State private var selection: AppLanguagePreference
    private let showsDescription: Bool

    init(store: AppLanguagePreferenceStore = .currentApp, showsDescription: Bool = true) {
        self.store = store
        self.showsDescription = showsDescription
        _selection = State(initialValue: store.selection)
    }

    var body: some View {
        Group {
            if showsDescription {
                VStack(alignment: .leading, spacing: 8) {
                    languagePicker
                    Text("Quit and reopen Sapphire to apply language changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                languagePicker.labelsHidden()
            }
        }
        .onAppear { selection = store.selection }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)) { _ in
            selection = store.selection
        }
    }

    private var languagePicker: some View {
        Picker("Language", selection: Binding(
            get: { selection },
            set: { preference in
                store.select(preference)
                selection = store.selection
            }
        )) {
            ForEach(AppLanguagePreference.allCases.filter { $0 != .existingOverride || selection == .existingOverride }) { preference in
                Text(verbatim: preference.title).tag(preference)
            }
        }
        .pickerStyle(.menu)
    }
}
