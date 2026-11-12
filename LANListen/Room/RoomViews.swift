import CoreAudio
import AppKit
import Network
import RoomCore
import SwiftUI

@MainActor @Observable
final class RoomAppModel {
    var nickname = UserDefaults.standard.string(forKey: "nickname") ?? "" {
        didSet { UserDefaults.standard.set(nickname, forKey: "nickname") }
    }
    let discovery = RoomDiscovery()
    var session: RoomSession?
    var error: String?

    var validNickname: String? { NameRules.nickname(nickname) }

    static let defaultPort = "47900"

    /// Empty = let the system pick. Ports below 1024 need root, so they're rejected up front.
    static func parsePort(_ text: String) -> UInt16?? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        guard let port = UInt16(trimmed), port >= 1024 else { return nil }
        return .some(port)
    }

    func create(roomName: String, port portText: String) {
        guard let nickname = validNickname, let name = NameRules.roomName(roomName),
              let port = Self.parsePort(portText) else { return }
        do {
            session = try RoomSession.host(roomName: name, nickname: nickname, port: port)
            error = nil
        } catch {
            self.error = "無法開房：\(error.localizedDescription)"
        }
    }

    func join(_ candidates: [NWEndpoint], code: String) {
        guard let nickname = validNickname else { return }
        session = RoomSession.join(candidates, nickname: nickname, code: code.trimmingCharacters(in: .whitespaces))
    }
}

struct RoomRootView: View {
    @Bindable var model: RoomAppModel

    var body: some View {
        Group {
            if let session = model.session {
                RoomView(session: session) { model.session = nil }
            } else {
                RoomHomeView(model: model)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { model.discovery.start() }
    }
}

// MARK: - Home

private struct RoomHomeView: View {
    @Bindable var model: RoomAppModel
    @State private var roomName = ""
    @State private var roomPort = RoomAppModel.defaultPort
    @State private var joining: RoomDiscovery.Room?
    @State private var manualHost = ""
    @State private var manualPort = ""
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("區網音樂房間").font(.title2.bold())
            HStack {
                Text("暱稱")
                TextField("1～24 個字（必填）", text: $model.nickname)
            }
            if model.validNickname == nil {
                Text("請先輸入暱稱才能建房或加入").font(.caption).foregroundStyle(.secondary)
            }

            GroupBox("建立房間") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("房名（1～40 個字）", text: $roomName)
                        Text("連接埠")
                        TextField("自動", text: $roomPort).frame(width: 70)
                        Button("建立") { model.create(roomName: roomName, port: roomPort) }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.validNickname == nil || NameRules.roomName(roomName) == nil
                                      || RoomAppModel.parsePort(roomPort) == nil)
                    }
                    Text(RoomAppModel.parsePort(roomPort) == nil
                         ? "連接埠需為 1024～65535，或留空自動選擇"
                         : "其他人手動加入時要輸入這個連接埠；留空則自動選擇")
                        .font(.caption)
                        .foregroundStyle(RoomAppModel.parsePort(roomPort) == nil ? .red : .secondary)
                }
            }

            GroupBox("區網中的房間") {
                VStack(alignment: .leading, spacing: 6) {
                    if let problem = model.discovery.problem {
                        Text(problem).foregroundStyle(.red).font(.callout)
                    }
                    if model.discovery.rooms.isEmpty {
                        Text("尚未找到房間").foregroundStyle(.secondary)
                    }
                    ForEach(model.discovery.rooms) { room in
                        HStack {
                            Text(room.name)
                            Text("#\(room.creatorShortID)").foregroundStyle(.secondary).font(.caption.monospaced())
                            Spacer()
                            if room.isCompatible {
                                Button("加入") { code = ""; joining = room }
                                    .disabled(model.validNickname == nil)
                            } else {
                                Text("版本不相容").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("手動加入（搜尋不到時）") {
                HStack {
                    TextField("IP，例如 192.168.1.20", text: $manualHost)
                        .onChange(of: manualHost) { _, pasted in
                            // Host screen copies "ip:port"; split it so one paste fills both fields.
                            let parts = pasted.trimmingCharacters(in: .whitespaces).split(separator: ":")
                            if parts.count == 2, UInt16(parts[1]) != nil {
                                manualHost = String(parts[0])
                                manualPort = String(parts[1])
                            }
                        }
                    TextField("連接埠", text: $manualPort).frame(width: 80)
                    TextField("驗證碼", text: $code).frame(width: 90)
                    Button("加入") {
                        guard let port = NWEndpoint.Port(manualPort.trimmingCharacters(in: .whitespaces)) else { return }
                        model.join([.hostPort(host: NWEndpoint.Host(manualHost.trimmingCharacters(in: .whitespaces)), port: port)], code: code)
                    }
                    .disabled(model.validNickname == nil || manualHost.isEmpty || manualPort.isEmpty || code.isEmpty)
                }
                Text("手動位址無法穿過公司網路的裝置隔離或防火牆。").font(.caption).foregroundStyle(.secondary)
            }

            if let error = model.error { Text(error).foregroundStyle(.red) }
        }
        .sheet(item: $joining) { room in
            VStack(alignment: .leading, spacing: 12) {
                Text("加入「\(room.name)」").font(.headline)
                TextField("請輸入房主提供的 6 位數驗證碼", text: $code)
                HStack {
                    Spacer()
                    Button("取消") { joining = nil }
                    Button("加入") {
                        model.join(room.joinCandidates, code: code)
                        joining = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(code.isEmpty)
                }
            }
            .padding(20)
            .frame(width: 360)
        }
    }
}

// MARK: - Room

private struct RoomView: View {
    let session: RoomSession
    let onExit: () -> Void
    @State private var confirmCreatorLeave = false
    /// Which code was last copied, so "已複製" disappears by itself once the code is refreshed.
    @State private var copiedCode: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch session.phase {
            case .connecting:
                ProgressView("加入中…\(session.currentAttempt.map { "（嘗試 \($0)）" } ?? "")")
                Button("取消") { session.leave(); onExit() }
            case .ended(let reason):
                Text(reason).font(.title3)
                Button("回到房間列表", action: onExit).buttonStyle(.borderedProminent)
            case .joined:
                if let snapshot = session.snapshot { joined(snapshot) }
            }
        }
        .confirmationDialog("你是建房者，離開後房間會關閉，所有人都會離開。", isPresented: $confirmCreatorLeave) {
            Button("關閉房間並離開", role: .destructive) { session.leave() }
        }
    }

    @ViewBuilder
    private func joined(_ s: RoomSnapshot) -> some View {
        Text(s.roomName).font(.title2.bold())
        if session.isCreator, let port = session.listenPort {
            ManualJoinAddresses(port: port)
        }

        if let code = s.code {
            GroupBox("驗證碼（只有房主看得到）") {
                HStack {
                    Text(code).font(.system(size: 28, weight: .bold, design: .monospaced)).textSelection(.enabled)
                    Button(copiedCode == code ? "已複製" : "複製") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        copiedCode = code
                    }
                    Spacer()
                    Button("更新驗證碼") { session.send(.refreshCode) }
                }
                Text("更新後舊碼立即失效，已在房間裡的人不受影響。").font(.caption).foregroundStyle(.secondary)
            }
        }

        ForEach(s.pendingTransfers.filter { $0.to == s.you }, id: \.id) { offer in
            OfferBanner(offer: offer, from: name(offer.from, in: s)) { accept in
                session.send(accept ? .acceptTransfer(offerID: offer.id) : .rejectTransfer(offerID: offer.id))
            }
        }
        ForEach(s.pendingTransfers.filter { $0.from == s.you }, id: \.id) { offer in
            Text("已邀請 \(name(offer.to, in: s)) 成為\(offer.role.label)，等待回應…").foregroundStyle(.secondary)
        }

        GroupBox("成員（\(s.members.count)/\(RoomProtocol.maxMembers)）") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(s.members) { member in
                    MemberRow(member: member, snapshot: s, send: session.send)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        GroupBox("音樂") {
            if s.presenterID == s.you {
                PresenterPanel(audio: session.audio, snapshot: s, name: { name($0, in: s) })
            } else {
                ListenerPanel(audio: session.audio, presenter: name(s.presenterID, in: s))
            }
        }

        if let error = session.lastError { Text(error).foregroundStyle(.red) }

        Button(session.isCreator ? "關閉房間" : "離開房間", role: .destructive) {
            if session.isCreator { confirmCreatorLeave = true } else { session.leave() }
        }
    }

    private func name(_ id: MemberID, in s: RoomSnapshot) -> String {
        s.members.first { $0.id == id }.map { "\($0.nickname) #\($0.id.short)" } ?? "#\(id.short)"
    }
}

private struct MemberRow: View {
    let member: Member
    let snapshot: RoomSnapshot
    let send: (ClientMessage) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(member.nickname)
            Text("#\(member.id.short)").font(.caption.monospaced()).foregroundStyle(.secondary)
            if member.id == snapshot.creatorID { Badge("建房者") }
            if member.id == snapshot.hostID { Badge("房主") }
            if member.id == snapshot.presenterID { Badge("播歌者") }
            if member.id == snapshot.you { Badge("你") }
            Spacer()
            if member.id != snapshot.you { actions }
        }
    }

    @ViewBuilder
    private var actions: some View {
        let isHost = snapshot.you == snapshot.hostID
        let isPresenter = snapshot.you == snapshot.presenterID
        if isHost || isPresenter {
            Menu("操作") {
                if isHost {
                    Button("轉移房主給他") { send(.offerTransfer(role: .host, to: member.id)) }
                    if member.id != snapshot.creatorID {
                        Button("踢出房間", role: .destructive) { send(.kick(member.id)) }
                    }
                }
                if isPresenter {
                    Button("交棒播歌給他") { send(.offerTransfer(role: .presenter, to: member.id)) }
                }
            }
            .fixedSize()
        }
    }
}

private struct Badge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
    }
}

private struct OfferBanner: View {
    let offer: TransferOffer
    let from: String
    let respond: (Bool) -> Void

    var body: some View {
        GroupBox {
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(offer.expiresAt.timeIntervalSince(context.date).rounded(.up)))
                    Text("\(from) 邀請你成為\(offer.role.label)（剩 \(left) 秒）")
                }
                Spacer()
                Button("拒絕") { respond(false) }
                Button("接受") { respond(true) }.buttonStyle(.borderedProminent)
            }
        }
    }
}

/// One row per local address with its own copy button; the kind label tells people which one to try.
private struct ManualJoinAddresses: View {
    let port: UInt16
    @State private var copied: String?

    var body: some View {
        GroupBox("手動加入（搜尋到但連不上時用）") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(WebRTCSupport.localIPv4Addresses(), id: \.self) { entry in
                    let parts = entry.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2 {
                        let address = "\(parts[1]):\(port)"
                        HStack {
                            Text(address).font(.body.monospaced()).textSelection(.enabled)
                            Text(Self.kind(parts[0])).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(copied == address ? "已複製" : "複製") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(address, forType: .string)
                                copied = address
                            }
                        }
                    }
                }
                Text("複製後可整串貼到加入者「手動加入」的 IP 欄位，連接埠會自動帶入。").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func kind(_ interface: String) -> String {
        if interface.hasPrefix("utun") || interface.hasPrefix("ipsec") || interface.hasPrefix("ppp") { return "\(interface)・VPN" }
        if interface.hasPrefix("bridge") || interface.hasPrefix("vmnet") { return "\(interface)・虛擬網卡，通常別台連不到" }
        return "\(interface)・區網"
    }
}

// MARK: - Audio

private struct PresenterPanel: View {
    @Bindable var audio: RoomAudio
    let snapshot: RoomSnapshot
    let name: (MemberID) -> String

    private var isSharing: Bool { snapshot.stream != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("你是播歌者。擷取範圍是整個 App，不是單一瀏覽器分頁；你聽的是來源 App 的原音，不會再播一次回傳。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("來源 App", selection: Binding(
                    get: { audio.selectedSource },
                    set: { if let id = $0 { audio.switchSource(to: id) } }
                )) {
                    ForEach(audio.sources) { Text($0.name).tag(Optional($0.bundleID)) }
                }
                Button("重新整理") { Task { await audio.loadSources() } }
                Button(isSharing ? "停止分享" : "開始分享") {
                    isSharing ? audio.stopSharing() : audio.startSharing()
                }
                .buttonStyle(.borderedProminent)
                .disabled(audio.selectedSource == nil)
            }
            if isSharing {
                Text(audio.isCapturing ? "分享中" : "啟動擷取中…")
                Text(String(format: "送出 %.0f kbps（每位聽眾各一份）", audio.sendKbps)).font(.caption.monospaced())
                ForEach(snapshot.members.filter { $0.id != snapshot.you }) { member in
                    Text("  \(name(member.id))：\(audio.listenerStates[member.id] ?? "—")").font(.caption.monospaced())
                }
            } else {
                Text("尚未分享").foregroundStyle(.secondary)
            }
            if let error = audio.shareError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await audio.loadSources() }
    }
}

private struct ListenerPanel: View {
    @Bindable var audio: RoomAudio
    let presenter: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusText)
            if let reason = audio.pausedReason {
                HStack {
                    Text(reason).foregroundStyle(.orange)
                    Button("繼續播放") { audio.resumeAfterDeviceChange() }
                }
            }
            HStack {
                Picker("輸出裝置", selection: $audio.outputDeviceID) {
                    Text("系統預設").tag(AudioDeviceID?.none)
                    ForEach(audio.outputDevices) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("重新整理") { audio.refreshOutputDevices() }
            }
            HStack {
                Text("本機音量")
                Slider(value: $audio.volume, in: 0...1)
                Toggle("靜音", isOn: $audio.isMuted)
            }
            Text("音量與靜音只影響你自己。").font(.caption).foregroundStyle(.secondary)
            if audio.listenState == .playing || audio.listenState == .connecting {
                let s = audio.receiveStats
                Text(String(format: "%@　收到 %.0f 封包　遺失 %.0f　補幀 %.2f%%　緩衝 %.0f ms",
                            s.codec, s.packets, s.packetsLost,
                            s.totalSamples > 0 ? s.concealedSamples / s.totalSamples * 100 : 0, s.jitterBufferMs))
                    .font(.caption.monospaced())
            }
            if let error = audio.outputError { Text(error).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusText: String {
        switch audio.listenState {
        case .idle, .waitingForPresenter: "等待 \(presenter) 開始分享"
        case .connecting: "正在連線到 \(presenter)…"
        case .playing: "正在收聽 \(presenter)（暫停的歌曲沒有聲音屬正常）"
        case .failed: "無法連到 \(presenter)（區網不可達或被防火牆阻擋）"
        }
    }
}

extension RoomRole {
    var label: String { self == .host ? "房主" : "播歌者" }
}
