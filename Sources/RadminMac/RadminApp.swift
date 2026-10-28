// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import RadminCore

private let panel = Color(red: 0.085, green: 0.11, blue: 0.15)

@main
struct RadminApp: App {
    @StateObject private var model = RuntimeModel()
    var body: some Scene {
        WindowGroup {
            RadminWindow(model: model).frame(minWidth: 340, minHeight: 420)
        }.defaultSize(width: 360, height: 500)
        Settings { RadminPreferences(model: model) }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Система") {
                Button(model.active ? "Отключить" : "Подключить") { if model.active { model.disconnect() } else { model.connect() } }
                Divider()
                SettingsLink { Text("Настройки…") }
            }
            CommandMenu("Сеть") {
                Button("Создать сеть…") { model.showCreateNetwork = true }.keyboardShortcut("n").disabled(!model.serverConnected)
                Button("Присоединиться к сети…") { model.showJoinNetwork = true }.keyboardShortcut("j").disabled(!model.serverConnected)
                Button("Повторить соединения") { model.retryPeers() }.disabled(!model.serverConnected)
            }
        }
    }
}
