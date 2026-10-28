// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import RadminCore

enum RadminAppearance: String, CaseIterable {
    case light, dark, system
    var title: String { switch self { case .light: "Светлая"; case .dark: "Тёмная"; case .system: "Автоматически" } }
    var scheme: ColorScheme? { switch self { case .light: .light; case .dark: .dark; case .system: nil } }
}

struct RadminColors {
    let dark: Bool
    static let teal = Color(red: 0.17, green: 0.73, blue: 0.82)
    var background: Color { dark ? Color(red: 0.055, green: 0.085, blue: 0.12) : Color(red: 0.94, green: 0.95, blue: 0.97) }
    var card: Color { dark ? Color(red: 0.135, green: 0.175, blue: 0.23) : .white }
    var selected: Color { dark ? Color(red: 0.17, green: 0.32, blue: 0.47) : Color.accentColor.opacity(0.17) }
}

struct RadminWindow: View {
    @ObservedObject var model: RuntimeModel
    @AppStorage("appearance") private var appearance = RadminAppearance.dark.rawValue
    var body: some View {
        RadminWindowContent(model: model)
            .preferredColorScheme(RadminAppearance(rawValue: appearance)?.scheme)
            .tint(RadminColors.teal)
    }
}

private struct RadminWindowContent: View {
    private struct PeerRowSelection: Equatable {
        let network: String
        let peer: UInt64
    }
    @ObservedObject var model: RuntimeModel
    @Environment(\.colorScheme) private var scheme
    @State private var collapsed: Set<String> = []
    @State private var selection: PeerRowSelection?
    @State private var leaving: EngineNetwork?
    @State private var showDetails = false
    private var colors: RadminColors { RadminColors(dark: scheme == .dark) }
    private var address: String { model.snapshot?.vip ?? "—" }
    private var status: String {
        if model.serverConnected { return model.snapshot?.interfaceReady == true ? "В сети" : "Ожидание адаптера" }
        switch model.phase {
        case "stopped": return "Не в сети"
        case "error": return "Ошибка подключения"
        case "stopping": return "Отключение…"
        case "provisioning": return "Регистрация…"
        default: return "Подключение…"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Menu("Система") {
                    Button(model.active ? "Отключить" : "Подключить") { power() }.disabled(model.phase == "stopping")
                    SettingsLink { Text("Настройки…") }
                    Divider()
                    Button("Выход") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                }
                Menu("Сеть") {
                    Button("Создать сеть…") { model.showCreateNetwork = true }.disabled(!model.serverConnected)
                    Button("Присоединиться к сети…") { model.showJoinNetwork = true }.disabled(!model.serverConnected)
                    Divider()
                    Button("Повторить соединения") { model.retryPeers() }.disabled(!model.serverConnected)
                }
                Menu("Справка") {
                    Button("О программе и соединении") { showDetails = true }
                }
                Spacer(minLength: 0)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).tint(.primary).fixedSize(horizontal: false, vertical: true)
                .font(.system(size: 11)).padding(.horizontal, 14).frame(height: 29)

            HStack(spacing: 12) {
                Button(action: power) {
                    VStack(spacing: 1) {
                        Image(systemName: "power").font(.system(size: 22, weight: .medium))
                        Text(model.active ? "ON" : "OFF").font(.system(size: 9, weight: .bold))
                    }.foregroundStyle(model.active ? Color.white : Color.secondary)
                        .frame(width: 59, height: 59)
                        .background {
                            Circle().fill(LinearGradient(colors: model.active ? [RadminColors.teal.opacity(0.65), RadminColors.teal] : [colors.card, colors.background], startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                        .overlay(Circle().strokeBorder(.white.opacity(model.active ? 0.7 : 0.2), lineWidth: 1.5))
                        .padding(3).background(Circle().fill(.primary.opacity(0.12)))
                }.buttonStyle(.plain).disabled(model.engineURL == nil || model.phase == "stopping")
                    .accessibilityLabel(model.active ? "Отключить VPN" : "Подключить VPN")
                    .help(model.active ? "Отключить VPN" : "Подключить VPN")
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.deviceName).font(.system(size: 15, weight: .semibold)).foregroundStyle(RadminColors.teal).lineLimit(1)
                    Text(address).font(.system(size: 13, weight: .bold)).monospacedDigit().textSelection(.enabled)
                        .contextMenu { Button("Скопировать IP-адрес") { copy(address) } }
                    Text(status).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(model.serverConnected ? Color.white : Color.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(model.serverConnected ? RadminColors.teal.opacity(0.7) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
                Spacer(minLength: 0)
            }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.card, in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 10).padding(.bottom, 8)

            if let error = model.snapshot?.interfaceError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).lineLimit(3).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Повторить") { model.retryInterface() }
                }.font(.system(size: 10)).padding(10)
            } else if model.active && model.snapshot?.interfaceReady != true {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(model.snapshot == nil ? model.connectionDetail : "Подтвердите настройку адаптера в macOS").lineLimit(2)
                    Spacer(minLength: 0)
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(10)
            } else if model.phase == "error" {
                Text(model.connectionDetail).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled).padding(10)
            }

            ScrollView {
                VStack(spacing: 5) {
                    if let snapshot = model.snapshot, !snapshot.networks.isEmpty {
                        ForEach(snapshot.networks) { network in networkCard(network, snapshot: snapshot) }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "network").font(.system(size: 25)).foregroundStyle(.tertiary)
                            Text(model.serverConnected ? "Нет подключённых сетей" : (model.active ? "Ожидаем подключение…" : "Нажмите кнопку питания"))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            if model.serverConnected {
                                Button("Присоединиться к сети…") { model.showJoinNetwork = true }.controlSize(.small)
                            }
                        }.frame(maxWidth: .infinity).padding(.top, 48)
                    }
                }.padding(.horizontal, 10).padding(.bottom, 10)
            }
            HStack(spacing: 5) {
                Text(model.operationMessage.isEmpty ? "" : model.operationMessage).lineLimit(1).help(model.operationMessage)
                Spacer(minLength: 0)
                Text("↓ \(rate(model.downloadRate))  ↑ \(rate(model.uploadRate))").monospacedDigit().fixedSize()
                Button { showDetails.toggle() } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).padding(.leading, 3)
                    .help("Сведения о соединении")
                    .popover(isPresented: $showDetails) { connectionDetails.padding(18).frame(width: 280) }
            }.font(.system(size: 9)).foregroundStyle(.secondary).padding(.horizontal, 11).frame(height: 25)
        }.background(colors.background).navigationTitle("Radmin VPN")
            .sheet(isPresented: $model.showJoinNetwork) { RadminNetworkSheet(model: model, creating: false) }
            .sheet(isPresented: $model.showCreateNetwork) { RadminNetworkSheet(model: model, creating: true) }
            .sheet(isPresented: $model.showBridgeSetup) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Однократная настройка адаптера").font(.headline)
                    Text("Установите системный помощник Radmin VPN один раз. После этого подключение и переподключение не требуют пароля администратора для адаптера.")
                    Text("Помощник создаёт только адаптер Radmin. Движок и ключи остаются в вашем пользовательском процессе.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.bridgeInstallMessage.isEmpty { Text(model.bridgeInstallMessage).font(.caption).textSelection(.enabled) }
                    HStack {
                        Button("Позже") { model.showBridgeSetup = false }.disabled(model.bridgeInstallPending)
                        Spacer()
                        if model.bridgeInstallPending { ProgressView().controlSize(.small) }
                        Button("Установить и подключить") { model.installBridgeService(connectAfter: true) }
                            .buttonStyle(.borderedProminent).disabled(model.bridgeInstallPending)
                    }
                }.padding(24).frame(width: 410).interactiveDismissDisabled(model.bridgeInstallPending)
            }
            .confirmationDialog("Выйти из сети «\(leaving?.name ?? "")»?", isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }), titleVisibility: .visible) {
                if let network = leaving { Button("Выйти из сети", role: .destructive) { model.leave(network); leaving = nil } }
            } message: { Text("Для повторного входа в закрытую сеть понадобится её пароль.") }
    }
    private func networkCard(_ network: EngineNetwork, snapshot: EngineSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                if !collapsed.insert(network.id).inserted { collapsed.remove(network.id) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: collapsed.contains(network.id) ? "chevron.right" : "chevron.down").font(.system(size: 8, weight: .bold)).frame(width: 8)
                    Text(network.name).font(.system(size: 12, weight: .bold)).lineLimit(1)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3)
                .accessibilityLabel("\(collapsed.contains(network.id) ? "Развернуть" : "Свернуть") сеть \(network.name)")
                .contextMenu { Button("Выйти из сети…") { leaving = network }.disabled(model.operationPending) }
            if !collapsed.contains(network.id) {
                let peers = snapshot.sortedPeers.filter { $0.peer.networkIds.contains(network.id) }
                if peers.isEmpty { Text("Нет других участников").font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 3) }
                ForEach(peers) { peer in
                    Button {
                        selection = PeerRowSelection(network: network.id, peer: peer.id)
                    } label: {
                    HStack(spacing: 5) {
                        signal(peer)
                        Text(peer.peer.name).lineLimit(1)
                        Spacer(minLength: 3)
                        Text(peer.peer.vip).monospacedDigit().fixedSize()
                    }.font(.system(size: 10)).padding(.horizontal, 7).frame(height: 22)
                        .background(selection == PeerRowSelection(network: network.id, peer: peer.id) ? colors.selected : .clear, in: Capsule())
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { model.ping(peer) })
                        .contextMenu {
                            Text(transport(peer))
                            Button("Проверить связь") { model.ping(peer) }.disabled(peer.status != "Connected")
                            Button("Скопировать IP-адрес") { copy(peer.peer.vip) }
                        }.help("\(transport(peer)) · \(qualityDescription(peer))")
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(peer.peer.name), \(peer.peer.vip), \(transport(peer)), \(qualityDescription(peer))")
                        .accessibilityValue(selection == PeerRowSelection(network: network.id, peer: peer.id) ? "Выбрано" : "")
                        .padding(.horizontal, 7)
                }
            }
        }.padding(.bottom, 7).background(colors.card, in: RoundedRectangle(cornerRadius: 8))
    }
    private func signal(_ peer: EnginePeerView) -> some View {
        let bars = peer.status == "Connected" ? model.peerQuality[peer.id]?.bars(at: ProcessInfo.processInfo.systemUptime) ?? 0 : 0
        return HStack(alignment: .center, spacing: 1) {
            Image(systemName: "xmark").font(.system(size: 6, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 6).opacity(peer.status == "Offline" ? 1 : 0)
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(0..<4) { i in RoundedRectangle(cornerRadius: 0.5).fill(i < bars ? Color.green : Color.secondary.opacity(0.25)).frame(width: 2, height: CGFloat(3 + i * 2)) }
            }
        }.frame(width: 18, height: 12).accessibilityHidden(true)
    }
    private func qualityDescription(_ peer: EnginePeerView) -> String {
        guard peer.status == "Connected" else { return transport(peer) }
        guard let quality = model.peerQuality[peer.id], let bars = quality.bars(at: ProcessInfo.processInfo.systemUptime) else { return "Задержка ещё не измерена" }
        guard let rtt = quality.rttMilliseconds else { return "Нет ответа на проверку связи" }
        return String(format: "Ping %.0f мс · %d из 4", rtt, bars)
    }
    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Radmin VPN для macOS").font(.headline)
            LabeledContent("Адрес", value: address)
            LabeledContent("Адаптер", value: model.snapshot?.interfaceReady == true ? "Подключён" : "Не подключён")
            LabeledContent("Отправлено", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: model.snapshot?.traffic.sentBytes ?? 0), countStyle: .binary))
            LabeledContent("Получено", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: model.snapshot?.traffic.receivedBytes ?? 0), countStyle: .binary))
            LabeledContent("Отброшено кадров", value: String(model.snapshot?.traffic.dropped ?? 0))
            if let traffic = model.snapshot?.traffic, traffic.congestionWaits != nil {
                LabeledContent("Ожиданий окна UDP", value: String(traffic.congestionWaits ?? 0))
                LabeledContent("Потери: вход / адаптер", value: "\(traffic.receiveQueueDropped ?? 0) / \(traffic.interfaceDropped ?? 0)")
                LabeledContent("Потери: очередь / пересылка", value: "\(traffic.forwardQueueDropped ?? 0) / \(traffic.forwardingDropped ?? 0)")
            }
            Divider()
            Text("Независимый клиент · 0.3.3\nOpenRad 2.0.1 · GPL-3.0 / MIT\nНе связан с Famatech.").font(.system(size: 10)).foregroundStyle(.secondary)
        }.font(.system(size: 11))
    }
    private func power() { if model.active { model.disconnect() } else { model.connect() } }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func rate(_ value: Double) -> String {
        if value >= 1_048_576 { return String(format: "%.1f МБ/с", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.1f КБ/с", value / 1024) }
        return String(format: "%.0f Б/с", max(0, value))
    }
    private func transport(_ peer: EnginePeerView) -> String {
        switch peer.transport {
        case "DirectTcp": return "Прямое соединение · TCP"
        case "DirectUdp": return "Прямое соединение · UDP"
        case "Relay": return "Через сервер"
        default:
            switch peer.status {
            case "Offline": return "Не в сети"
            case "Connecting": return "Подключение…"
            case "Failed", "Refused": return "Нет соединения"
            default: return "В сети"
            }
        }
    }
}

struct RadminNetworkSheet: View {
    @ObservedObject var model: RuntimeModel
    let creating: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    private var valid: Bool {
        !model.networkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!(creating || model.privateNetwork) || (password.utf16.count >= 6 && password.utf16.count <= 256)) &&
        (!creating || password == confirmation)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(creating ? "Создать сеть" : "Присоединиться к сети").font(.system(size: 16, weight: .semibold))
            if !creating {
                Picker("Тип сети", selection: $model.privateNetwork) {
                    Text("Частная сеть").tag(true)
                    Text("Игровая сеть").tag(false)
                }.pickerStyle(.segmented).labelsHidden()
            }
            Form {
                TextField("Имя сети:", text: $model.networkName)
                if creating || model.privateNetwork {
                    SecureField("Пароль:", text: $password)
                    if creating { SecureField("Повторите пароль:", text: $confirmation) }
                }
            }.formStyle(.columns).disabled(model.operationPending)
            if !creating && !model.privateNetwork {
                Text("Введите точное название публичной игровой сети Radmin. Пароль для неё не требуется.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if creating || model.privateNetwork {
                Text(creating && !confirmation.isEmpty && password != confirmation ? "Пароли не совпадают." : "Пароль: от 6 до 256 символов.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !model.operationMessage.isEmpty { Text(model.operationMessage).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                if model.operationPending { ProgressView().controlSize(.small) }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.operationPending)
                Button(creating ? "Создать" : "Подключиться") {
                    if creating { model.createNetwork(name: model.networkName, password: password) }
                    else { model.networkPassword = password; model.join() }
                    password = ""; confirmation = ""
                }.keyboardShortcut(.defaultAction).disabled(!valid || model.operationPending)
            }
        }.padding(22).frame(width: 350).tint(RadminColors.teal)
            .onAppear { model.operationMessage = "" }
            .onDisappear { password = ""; confirmation = ""; model.networkPassword = "" }
    }
}
