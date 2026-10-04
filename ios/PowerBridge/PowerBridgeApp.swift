import SwiftUI

@main
struct PowerBridgeApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup { Dashboard().environmentObject(store).preferredColorScheme(.dark).tint(.mint) }
    }
}
