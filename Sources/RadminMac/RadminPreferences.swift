// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct RadminPreferences: View {
    @ObservedObject var model: RuntimeModel
    @AppStorage("appearance") private var appearance = RadminAppearance.dark.rawValue
    @State private var section = 0
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                item("Тема", image: "paintpalette", index: 0)
                item("Подключение", image: "server.rack", index: 1)
                item("О программе", image: "info.circle", index: 2)
                Spacer()
            }.padding(10).frame(width: 175).background(.quaternary.opacity(0.35))
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                switch section {
                case 0:
                    Text("Выберите цветовую схему").font(.headline)
                    Picker("Тема", selection: $appearance) {
                        ForEach(RadminAppearance.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }.pickerStyle(.radioGroup).labelsHidden()
                case 1:
                    Text("Параметры подключения").font(.headline)
                    LabeledContent("Устройство", value: model.deviceName)
                    Toggle("Использовать только relay", isOn: $model.forceRelay).disabled(model.active)
                    Text(model.active ? "Для изменения способа соединения сначала отключите VPN кнопкой питания." : "Relay передаёт трафик через сервер, когда прямое соединение недоступно.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Divider()
                    Text(model.bridgeServiceInstalled ? "Служба адаптера установлена" : "Адаптер без повторного пароля администратора").font(.system(size: 12, weight: .medium))
                    Button(model.bridgeServiceInstalled ? "Обновить службу адаптера…" : "Установить службу один раз…") { model.installBridgeService() }
                        .disabled(model.active || model.bridgeInstallPending)
                    Text(model.bridgeInstallMessage.isEmpty ? "Одно подтверждение администратора при установке. Затем переподключения используют системную службу." : model.bridgeInstallMessage)
                        .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    Divider()
                    Text("Язык интерфейса: русский").font(.system(size: 12))
                    Text("Прокси-сервер и автоматическое обновление в этой версии не поддерживаются.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                default:
                    Text("Radmin VPN для macOS").font(.headline)
                    Text("Версия 0.3.3 · SwiftUI · OpenRad 2.0.1")
                    Text("Независимый совместимый клиент. Не связан с Famatech. Нативное подключение без Wine и Windows-компонентов.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Link("Исходный движок OpenRad", destination: URL(string: "https://github.com/gringoestrangeiro/openrad")!)
                    Text("Лицензии: GPL-3.0 и MIT. Полные уведомления о зависимостях находятся в Resources внутри приложения.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(width: 510, height: 420).navigationTitle("Настройки")
            .preferredColorScheme(RadminAppearance(rawValue: appearance)?.scheme).tint(RadminColors.teal)
    }
    private func item(_ title: String, image: String, index: Int) -> some View {
        Button { section = index } label: {
            HStack(spacing: 8) {
                Image(systemName: image).font(.system(size: 15)).frame(width: 20).foregroundStyle(RadminColors.teal)
                Text(title).font(.system(size: 12)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }.padding(.horizontal, 8).frame(height: 34).contentShape(Rectangle())
                .background(section == index ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
}
