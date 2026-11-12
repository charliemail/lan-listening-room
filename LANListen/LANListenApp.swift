import SwiftUI

@main
struct LANListenApp: App {
    @State private var room = RoomAppModel()
    #if DEV_TOOLS
    // Owned here, not by the views: SwiftUI rebuilds tab/role views, and a session owned by a
    // discarded view kept its connection playing with no UI left to stop it.
    @State private var share = ShareSession()
    @State private var listen = ListenSession()
    @State private var probe = CaptureProbeModel()
    #endif

    var body: some Scene {
        #if DEV_TOOLS
        WindowGroup("LAN Listen Dev") {
            TabView {
                RoomRootView(model: room).tabItem { Text("房間") }
                TwoMacTestView(share: share, listen: listen).tabItem { Text("雙機實驗") }
                CaptureProbeView(model: probe).tabItem { Text("擷取測試") }
            }
        }
        .windowResizability(.contentSize)
        #else
        WindowGroup("LAN Listen") {
            RoomRootView(model: room)
        }
        .windowResizability(.contentSize)
        #endif
    }
}
