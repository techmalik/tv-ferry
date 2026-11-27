import SwiftUI

/// TV Ferry → Settings… (⌘,)
struct SettingsView: View {
    @ObservedObject var prefs: UpdatePrefs
    @ObservedObject var settings: ConnectionSettings

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $prefs.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Section {
                Toggle("Show TV Ferry in the menu bar", isOn: $prefs.showInMenuBar)
            } header: {
                Text("Menu bar")
            } footer: {
                Text("Drop files on the menu bar panel and watch transfers without opening the window. With this on, TV Ferry keeps running when you close its window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Transfers") {
                Toggle("Skip files already on the TV", isOn: $settings.skipExisting)
                Toggle("Convert videos the TV may not play without asking", isOn: $prefs.autoConvert)
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $prefs.autoCheck)
                Button("Check Now") { Updates.check(userInitiated: true) }
            }
        }
        .formStyle(.grouped)
        .tint(Palette.accent)
        .frame(width: 480)
        .fixedSize()
    }
}
