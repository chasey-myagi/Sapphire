//
//  SettingsSidebar.swift
//  Sapphire
//
//  Created by Shariq Charolia on 2025-07-10.
//

import SwiftUI

struct SettingsSidebarGroup: Identifiable {
    let id: String
    let title: String
    let sections: [SettingsSection]
}

extension SettingsSection {
    static let sidebarGroups: [SettingsSidebarGroup] = [
        .init(id: "general", title: String(localized: "General"), sections: [.general, .keyboardShortcuts, .bluetoothUnlock, .neardrop]),
        .init(id: "notch", title: String(localized: "Notch"), sections: [.appearance, .widgets, .liveActivities, .lockScreen, .notifications, .hud]),
        .init(id: "widgetsAndContent", title: String(localized: "Widgets & Content"), sections: [.music, .weather, .calendar, .sports, .battery, .audio, .bluetooth, .shortcuts, .fileShelf, .notes, .clipboard, .mirror, .caffeine]),
        .init(id: "systemAndUtilities", title: String(localized: "System & Utilities"), sections: [.systemEnhance, .snapZones, .dockLayouts, .mediaOptimizer, .mouse, .monitoring, .devActivity, .emoji, .archives, .apps, .storage]),
        .init(id: "focusAndSecurity", title: String(localized: "Focus & Security"), sections: [.eyeBreak, .focusSession]),
        .init(id: "about", title: "", sections: [.about])
    ]

    static func sidebarGroups(matching searchText: String) -> [SettingsSidebarGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sidebarGroups }

        return sidebarGroups.compactMap { group in
            let matches = group.sections.filter { section in
                let haystacks = [section.label, section.shortDescription] + section.searchTokens
                return haystacks.contains { $0.localizedCaseInsensitiveContains(query) }
            }
            return matches.isEmpty ? nil : SettingsSidebarGroup(id: group.id, title: group.title, sections: matches)
        }
    }
}

struct SettingsSidebarView: View {
    @Binding var selectedSection: SettingsSection?
    let onQuit: () -> Void
    @State private var searchText = ""

    private var filteredGroups: [SettingsSidebarGroup] {
        SettingsSection.sidebarGroups(matching: searchText)
    }

    var body: some View {
        let filteredGroups = filteredGroups

        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 45)

            // MARK: 1. Search Settings (Top of Sidebar)
            ClearableSearchField(placeholder: "Search settings", text: $searchText)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            // MARK: 3. Settings Sections list
            List(selection: Binding(
                get: { selectedSection },
                set: { value in
                    selectedSection = value
                }
            )) {
                ForEach(filteredGroups) { group in
                    Section {
                        ForEach(group.sections) { section in
                            SidebarRowView(section: section)
                            .tag(section)
                        }
                    } header: {
                        Text(verbatim: group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity, alignment: .top)
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SapphireSelectSection"))) { notification in
                if let sectionName = notification.object as? String,
                   let section = SettingsSection(rawValue: sectionName) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.selectedSection = section
                    }
                }
            }

            if !searchText.isEmpty && filteredGroups.isEmpty {
                Text("No settings matched \"\(searchText)\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            Spacer(minLength: 0)

            Button(action: onQuit) {
                HStack {
                    Image(systemName: "power.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.red)
                        .frame(width: 30, height: 30)
                        .background(Color.red.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("Quit")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.vertical, 3)
                .padding(.leading, 12)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 15)
        }
    }
}

struct TrafficLightButtonStyle: ButtonStyle {
    let color: Color; let isHovering: Bool
    func makeBody(configuration: Configuration) -> some View {
        ZStack { Circle().fill(color); configuration.label.foregroundStyle(.black.opacity(0.6)).opacity(isHovering ? 1 : 0) }.frame(width: 12, height: 12)
    }
}

fileprivate struct SidebarRowView: View {
    let section: SettingsSection

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: section.systemImage).font(.system(size: 11, weight: .bold)).foregroundStyle(.white).frame(width: 22, height: 22).background(LinearGradient(colors: section.iconGradientColors, startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.8)).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(verbatim: section.label).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            Spacer()

        }.padding(.vertical, 5)
    }
}
