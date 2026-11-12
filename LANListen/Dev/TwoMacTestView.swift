import CoreAudio
import SwiftUI

/// Phase 0 exit test: Mac A shares one app's audio, Mac B listens via manual IP. Not the room UI.
struct TwoMacTestView: View {
    enum Role: String, CaseIterable { case share = "分享（A）", listen = "收聽（B）" }

    let share: ShareSession
    let listen: ListenSession
    @State private var role = Role.share
    private var live = LiveConnections.shared

    init(share: ShareSession, listen: ListenSession) {
        self.share = share
        self.listen = listen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("雙機音訊實驗（Phase 0）").font(.title2.bold())
            Text("實驗用：手動 IP、明文信令、無配對。只在可信任的測試網路使用。")
                .font(.callout).foregroundStyle(.orange)
            Picker("角色", selection: $role) {
                ForEach(Role.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            switch role {
            case .share: SharePanel(session: share)
            case .listen: ListenPanel(session: listen)
            }
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))　診斷：本機存活連線數 \(live.count)（未連線時應為 0）")
                .font(.caption.monospaced())
                .foregroundStyle(live.count > 0 && !share.isSharing && !listen.isConnected ? .red : .secondary)
        }
        .padding(20)
        .frame(width: 520)
    }
}

private struct SharePanel: View {
    @Bindable var session: ShareSession
    @State private var apps: [SourceApp] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("來源 App", selection: $session.selectedBundleID) {
                    ForEach(apps) { Text($0.name).tag(Optional($0.bundleID)) }
                }
                Button("重新整理") { Task { await loadApps() } }
            }
            .disabled(session.isSharing)
            HStack {
                Text("連接埠")
                TextField("", text: $session.port).frame(width: 80).disabled(session.isSharing)
                Spacer()
                Button(session.isSharing ? "停止分享" : "開始分享") {
                    Task {
                        if session.isSharing { await session.stop() }
                        else if let bundleID = session.selectedBundleID, let p = UInt16(session.port) {
                            await session.start(bundleID: bundleID, port: p)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.selectedBundleID == nil)
            }
            GroupBox("請 B 輸入以下任一位址（utun 開頭通常是 VPN，請優先用 en0）") {
                VStack(alignment: .leading) {
                    ForEach(WebRTCSupport.localIPv4Addresses(), id: \.self) { Text("\($0)  :\(session.port)") }
                }
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            GroupBox("狀態") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("分享中：\(session.isSharing ? "是" : "否")　聽眾：\(session.peers.count)")
                    ForEach(Array(session.peers.values.enumerated()), id: \.offset) { i, peer in
                        Text("  聽眾 \(i + 1)：ICE \(peer.ice)")
                    }
                    Text("編碼：\(session.stats.codec)")
                    Text(String(format: "送出：%.0f kbps　累計 %.1f MB　%.0f 封包", session.kbps, session.stats.bytes / 1_000_000, session.stats.packets))
                    ElapsedText(label: "分享已經過", since: session.startedAt)
                }
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let message = session.errorMessage {
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .task { await loadApps() }
    }

    private func loadApps() async {
        do {
            apps = try await AudioCaptureService.shareableApps()
            if session.selectedBundleID == nil || !apps.contains(where: { $0.bundleID == session.selectedBundleID }) {
                session.selectedBundleID = apps.first?.bundleID
            }
        } catch {
            session.errorMessage = AudioCaptureService.describe(error)
        }
    }
}

private struct ListenPanel: View {
    @Bindable var session: ListenSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("A 的 IP，例如 192.168.1.20", text: $session.host)
                TextField("連接埠", text: $session.port).frame(width: 80)
                Button(session.isConnected ? "離開" : "連線") {
                    if session.isConnected { session.disconnect() } else { session.connect() }
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(false)
            HStack {
                Picker("輸出裝置", selection: $session.outputDeviceID) {
                    Text("系統預設").tag(AudioDeviceID?.none)
                    ForEach(session.outputDevices) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("重新整理") { session.refreshOutputDevices() }
            }
            HStack {
                Text("本機音量")
                Slider(value: $session.volume, in: 0...1)
                Toggle("靜音", isOn: $session.isMuted)
            }
            if let message = session.outputError {
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            }
            GroupBox("狀態") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(session.status)　ICE：\(session.ice)")
                    Text("編碼：\(session.stats.codec)")
                    Text(String(format: "收到 %.0f 封包　遺失 %.0f　累計 %.1f MB", session.stats.packets, session.stats.packetsLost, session.stats.bytes / 1_000_000))
                    Text(String(format: "jitter buffer %.0f ms　音量 %.3f", session.stats.jitterBufferMs, session.stats.audioLevel))
                    Text("補幀：前 10 秒 \(Self.format(session.warmUpConcealedPercent))　之後 \(Self.format(session.steadyConcealedPercent))")
                    ElapsedText(label: "收聽已經過", since: session.startedAt)
                }
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { session.refreshOutputDevices() }
    }

    private static func format(_ percent: Double?) -> String {
        percent.map { String(format: "%.2f%%", $0) } ?? "—"
    }
}

private struct ElapsedText: View {
    let label: String
    let since: Date?

    var body: some View {
        if let since {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let s = Int(context.date.timeIntervalSince(since))
                Text(String(format: "\(label)：%02d:%02d", s / 60, s % 60))
            }
        } else {
            Text("\(label)：—")
        }
    }
}
