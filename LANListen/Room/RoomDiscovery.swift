import Foundation
import Network
import RoomCore

@MainActor @Observable
final class RoomDiscovery {
    struct Room: Identifiable, Hashable {
        let id: String
        let endpoint: NWEndpoint
        let name: String
        let creatorShortID: String
        let isCompatible: Bool
        /// Direct addresses from the TXT record, tried after the Bonjour endpoint if it can't connect.
        let fallbacks: [NWEndpoint]

        var joinCandidates: [NWEndpoint] { [endpoint] + fallbacks }
    }

    private(set) var rooms: [Room] = []
    private(set) var problem: String?
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RoomProtocol.bonjourType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.rooms = results.compactMap(Self.room).sorted { $0.name < $1.name } }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.problem = nil
                case .waiting(let error), .failed(let error):
                    self?.problem = "無法搜尋區網房間（\(error)）。請確認「系統設定 → 隱私權與安全性 → 區域網路」已允許 LAN Listen，或改用手動位址。"
                default: break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private static func room(_ result: NWBrowser.Result) -> Room? {
        guard case .service(let name, _, _, _) = result.endpoint,
              case .bonjour(let txt) = result.metadata else { return nil }
        return Room(
            id: name,
            endpoint: result.endpoint,
            name: txt["room"] ?? name,
            creatorShortID: txt["creator"] ?? "?",
            isCompatible: txt["v"] == String(RoomProtocol.version),
            fallbacks: fallbacks(txt)
        )
    }

    private static func fallbacks(_ txt: NWTXTRecord) -> [NWEndpoint] {
        guard let portText = txt["port"], let port = NWEndpoint.Port(portText), let addrs = txt["addrs"] else { return [] }
        return addrs.split(separator: ",").map { .hostPort(host: NWEndpoint.Host(String($0)), port: port) }
    }
}
