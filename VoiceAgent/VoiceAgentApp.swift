import SwiftUI
import ComposableArchitecture
import OpenClawCore

@main
struct VoiceAgentApp: App {
    init() {
        KeychainHelper.service = "com.openclaw.voiceagent"
    }

    var body: some Scene {
        WindowGroup {
            DirectVoiceView(
                store: Store(initialState: DirectVoiceFeature.State()) {
                    DirectVoiceFeature()
                }
            )
        }
    }
}
