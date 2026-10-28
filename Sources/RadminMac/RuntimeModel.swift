// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import Foundation
import RadminCore

@MainActor
final class RuntimeModel: ObservableObject {
    @Published var phase = "stopped"
    @Published var connectionDetail = "Отключено"
    @Published var snapshot: EngineSnapshot?
    @Published var deviceName = Host.current().localizedName ?? "MacBook"
    @Published var networkName = ""
    @Published var networkPassword = ""
    @Published var privateNetwork = true
    @Published var forceRelay = false
    @Published var operationPending = false
    @Published var operationMessage = ""
    @Published var engineVersion = ""
    @Published var showJoinNetwork = false
    @Published var showCreateNetwork = false
    @Published var uploadRate: Double = 0
    @Published var downloadRate: Double = 0
    @Published var peerQuality: [UInt64: PeerLinkQuality] = [:]
    @Published var bridgeServiceInstalled = BridgeServiceInstaller.installed
    @Published var bridgeInstallPending = false
    @Published var bridgeInstallMessage = ""
    @Published var showBridgeSetup = false
    private var pingRequests: [UInt64: (peer: UInt64, automatic: Bool)] = [:]
    private var probeSchedule = PeerProbeSchedule()
    private var linkMonitorTask: Task<Void, Never>?
    private var lastTraffic: (time: TimeInterval, sent: UInt64, received: UInt64)?
    private var process: Process?
    private var input: FileHandle?
    private var incoming = Data()
    private var sequence: UInt64 = 0
    private var generation = UUID()
    private var networkOperation: UInt64?
    private var connectionDesired = false
    private var knownIdentity = false
    private var retryAttempt = 0
    private var onlineSince: TimeInterval?
    private var reconnectTask: Task<Void, Never>?
    var active: Bool { !["stopped", "error"].contains(phase) }
    var serverConnected: Bool { phase == "online" }
    var engineURL: URL? {
        guard let directory = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let url = directory.appendingPathComponent("radmin-mac-engine")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    var nativeHelperAvailable: Bool {
        guard let directory = Bundle.main.executableURL?.deletingLastPathComponent() else { return false }
        return FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("radmin-bridge").path)
    }
    init() {
        linkMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshLinkQuality()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    deinit { linkMonitorTask?.cancel() }
    func connect() {
        bridgeServiceInstalled = BridgeServiceInstaller.installed
        guard bridgeServiceInstalled else { showBridgeSetup = true; return }
        connectionDesired = true; retryAttempt = 0
        reconnectTask?.cancel(); reconnectTask = nil
        connectAttempt()
    }
    private func connectAttempt() {
        do {
            try startEngine()
            snapshot = nil; lastTraffic = nil; uploadRate = 0; downloadRate = 0
            onlineSince = nil
            peerQuality = [:]; pingRequests = [:]
            operationMessage = ""; phase = "connecting"
            connectionDetail = "Подключение к Radmin…"
            try send(["command": "connect", "name": deviceName, "force_relay": forceRelay])
        } catch { phase = "error"; connectionDetail = error.localizedDescription; scheduleReconnect() }
    }
    func disconnect() {
        connectionDesired = false; reconnectTask?.cancel(); reconnectTask = nil
        if input == nil {
            phase = "stopped"; connectionDetail = "Отключено"
            snapshot = nil; peerQuality = [:]; pingRequests = [:]
            lastTraffic = nil; uploadRate = 0; downloadRate = 0
            return
        }
        phase = "stopping"; connectionDetail = "Отключение…"
        do { try send(["command": "disconnect"]) }
        catch { phase = "error"; connectionDetail = error.localizedDescription }
    }
    private func scheduleReconnect() {
        guard connectionDesired, reconnectTask == nil,
              let delay = ReconnectPolicy.delay(attempt: retryAttempt, knownIdentity: knownIdentity, error: connectionDetail) else { return }
        retryAttempt += 1
        phase = "reconnecting"
        connectionDetail = "Связь потеряна. Повторное подключение через \(Int(delay)) с…"
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.connectionDesired else { return }
            self.reconnectTask = nil
            self.connectAttempt()
        }
    }
    func join() {
        guard !operationPending else { return }
        var request: [String: Any] = ["command": "join", "name": networkName]
        if privateNetwork { request["password"] = networkPassword }
        do {
            networkOperation = try send(request)
            operationPending = true; operationMessage = "Вход в сеть…"
            networkPassword = ""
        } catch { operationMessage = error.localizedDescription }
    }
    func createNetwork(name: String, password: String) {
        guard !operationPending else { return }
        do {
            networkOperation = try send(["command": "create", "name": name, "password": password])
            operationPending = true; operationMessage = "Создание сети…"
        } catch { operationMessage = error.localizedDescription }
    }
    func leave(_ network: EngineNetwork) {
        guard !operationPending else { return }
        do {
            networkOperation = try send(["command": "leave", "name": network.name])
            operationPending = true; operationMessage = "Выход из сети…"
        } catch { operationMessage = error.localizedDescription }
    }
    func ping(_ peer: EnginePeerView) {
        guard peer.status == "Connected", !pingRequests.values.contains(where: { $0.peer == peer.id }) else { return }
        do {
            let id = try send(["command": "ping", "peer": peer.peer.rid])
            pingRequests[id] = (peer.id, false)
            probeSchedule.sent(to: peer.id, at: ProcessInfo.processInfo.systemUptime)
            operationMessage = "Проверка \(peer.peer.vip)…"
        }
        catch { operationMessage = error.localizedDescription }
    }
    func refreshLinkQuality() {
        guard serverConnected, let snapshot else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let pending = Set(pingRequests.values.map(\.peer))
        let connected = Set(snapshot.peers.values.filter { $0.status == "Connected" }.map(\.id))
        for peer in probeSchedule.due(connected: connected, pending: pending, at: now) {
            if let id = try? send(["command": "ping", "peer": peer]) {
                pingRequests[id] = (peer, true)
                probeSchedule.sent(to: peer, at: now)
            }
        }
    }
    func retryInterface() { do { try send(["command": "retry_interface"]) } catch { connectionDetail = error.localizedDescription } }
    func installBridgeService(connectAfter: Bool = false) {
        guard !active, !bridgeInstallPending else { return }
        bridgeInstallPending = true
        bridgeInstallMessage = "Подтвердите однократную установку службы адаптера в системном окне."
        Task {
            defer { bridgeInstallPending = false }
            do {
                bridgeInstallMessage = try await BridgeServiceInstaller.install()
                bridgeServiceInstalled = BridgeServiceInstaller.installed
                if bridgeServiceInstalled && connectAfter { showBridgeSetup = false; connect() }
            }
            catch { bridgeInstallMessage = error.localizedDescription }
        }
    }
    func retryPeers() { do { try send(["command": "retry_peers"]) } catch { operationMessage = error.localizedDescription } }

    private func startEngine() throws {
        if process?.isRunning == true { return }
        guard let executable = engineURL else { throw CocoaError(.fileNoSuchFile) }
        let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        let profile = try ProfileLocation.resolve(
            home: FileManager.default.homeDirectoryForCurrentUser,
            override: ProcessInfo.processInfo.environment["RADMIN_PROFILE_DIR"],
            directoryExists: { FileManager.default.fileExists(atPath: $0.path) })
        child.executableURL = executable
        child.arguments = ["--stdio", "--profile", profile.path]
        let token = UUID(); generation = token; incoming = Data()
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.consume(data)
            }
        }
        // Consume bounded diagnostics; credentials are never sent to this pipe.
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        child.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self.input = nil; self.process = nil
                self.operationPending = false; self.snapshot = nil
                self.lastTraffic = nil; self.uploadRate = 0; self.downloadRate = 0
                self.peerQuality = [:]; self.pingRequests = [:]
                if self.phase != "error" {
                    self.phase = status == 0 ? "stopped" : "error"
                    self.connectionDetail = status == 0 ? "Отключено" : "Движок завершился (код \(status))"
                }
                self.scheduleReconnect()
            }
        }
        try child.run()
        process = child; input = stdin.fileHandleForWriting
    }
    @discardableResult private func send(_ fields: [String: Any]) throws -> UInt64 {
        guard let input else { throw CocoaError(.fileWriteUnknown) }
        sequence += 1
        var value = fields; value["id"] = sequence
        var data = try JSONSerialization.data(withJSONObject: value)
        guard data.count < 16_384 else { throw CocoaError(.fileWriteInvalidFileName) }
        data.append(10)
        try input.write(contentsOf: data)
        return sequence
    }
    private func consume(_ data: Data) {
        incoming.append(data)
        guard incoming.count <= 4 * 1024 * 1024 else {
            phase = "error"; connectionDetail = "Превышен размер ответа движка"; process?.terminate(); return
        }
        while let newline = incoming.firstIndex(of: 10) {
            let line = incoming.prefix(upTo: newline)
            incoming.removeSubrange(...newline)
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let kind = event["event"] as? String else { continue }
            switch kind {
            case "ready": engineVersion = event["engine"] as? String ?? "OpenRad"
            case "device":
                knownIdentity = true
                if let name = event["name"] as? String { deviceName = name }
            case "phase":
                phase = event["phase"] as? String ?? "error"
                connectionDetail = event["detail"] as? String ?? ""
                if ["stopped", "error"].contains(phase) {
                    snapshot = nil; operationPending = false; lastTraffic = nil
                    uploadRate = 0; downloadRate = 0
                    peerQuality = [:]; pingRequests = [:]
                    if phase == "error" { scheduleReconnect() }
                }
            case "state":
                if let value = event["snapshot"], let data = try? JSONSerialization.data(withJSONObject: value),
                   let state = try? EngineSnapshot.decode(data) {
                    let now = ProcessInfo.processInfo.systemUptime
                    if let previous = lastTraffic, now > previous.time,
                       state.traffic.sentBytes >= previous.sent, state.traffic.receivedBytes >= previous.received {
                        uploadRate = Double(state.traffic.sentBytes - previous.sent) / (now - previous.time)
                        downloadRate = Double(state.traffic.receivedBytes - previous.received) / (now - previous.time)
                    }
                    lastTraffic = (now, state.traffic.sentBytes, state.traffic.receivedBytes)
                    let connected = Set(state.peers.values.filter { $0.status == "Connected" }.map(\.id))
                    let changed = Set(state.peers.values.filter {
                        $0.status == "Connected" && (snapshot?.peers[String($0.id)]?.status != "Connected" || snapshot?.peers[String($0.id)]?.transport != $0.transport)
                    }.map(\.id))
                    peerQuality = peerQuality.filter { connected.contains($0.key) && !changed.contains($0.key) }
                    pingRequests = pingRequests.filter { connected.contains($0.value.peer) && !changed.contains($0.value.peer) }
                    probeSchedule.retain(connected)
                    for peer in changed { probeSchedule.forget(peer) }
                    snapshot = state
                    if phase != "stopping" { phase = "online" }
                    if onlineSince == nil { onlineSince = now }
                    if now - (onlineSince ?? now) >= 30 { retryAttempt = 0 }
                    connectionDetail = state.interfaceReady ? "Подключено к Radmin" : "Сервер подключён · ожидание адаптера"
                    if !changed.isEmpty { refreshLinkQuality() }
                }
            case "result":
                if (event["id"] as? NSNumber)?.uint64Value == networkOperation {
                    operationPending = false; networkOperation = nil
                    if event["error"] as? Bool == false { showJoinNetwork = false; showCreateNetwork = false }
                }
                operationMessage = event["message"] as? String ?? ""
            case "reply":
                if event["ok"] as? Bool == false {
                    if let id = (event["id"] as? NSNumber)?.uint64Value, let ping = pingRequests.removeValue(forKey: id), ping.automatic { break }
                    let error = event["error"] as? String ?? "Ошибка команды"
                    operationMessage = error
                    if (event["id"] as? NSNumber)?.uint64Value == networkOperation { operationPending = false; networkOperation = nil }
                }
            case "ping":
                let id = (event["id"] as? NSNumber)?.uint64Value
                let request = id.flatMap { pingRequests.removeValue(forKey: $0) }
                guard let request, let peer = (event["peer"] as? NSNumber)?.uint64Value,
                      request.peer == peer, snapshot?.peers[String(peer)]?.status == "Connected" else { break }
                peerQuality[peer] = PeerLinkQuality(rttMilliseconds: event["rtt_ms"] as? Double, measuredAt: ProcessInfo.processInfo.systemUptime)
                if request.automatic { break }
                if let error = event["error"] as? String { operationMessage = error }
                else if let rtt = event["rtt_ms"] as? Double { operationMessage = String(format: "Защищённый канал отвечает: %.1f мс", rtt) }
            case "operation": operationMessage = event["message"] as? String ?? ""
            default: break
            }
        }
    }
}
