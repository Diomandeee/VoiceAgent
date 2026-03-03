import SwiftUI
import ComposableArchitecture

/// Voice configuration sheet — TTS, speaker ID, Gemini observer, camera.
struct VoiceSettingsSheet: View {
    let store: StoreOf<DirectVoiceFeature>

    var body: some View {
        NavigationStack {
            List {
                // TTS Section
                Section("Text-to-Speech") {
                    HStack {
                        Label("Verbosity", systemImage: store.ttsVerbosity.icon)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { store.ttsVerbosity },
                            set: { _ in store.send(.cycleTTSVerbosity) }
                        )) {
                            ForEach(TTSVerbosity.allCases, id: \.self) { v in
                                Text(v.displayName).tag(v)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }

                    Toggle(isOn: Binding(
                        get: { !store.ttsMuted },
                        set: { _ in store.send(.toggleMute) }
                    )) {
                        Label("Audio Output", systemImage: "speaker.wave.2")
                    }
                }

                // Speaker ID Section
                Section("Speaker Identification") {
                    HStack {
                        Label("Status", systemImage: store.speakerResult.icon)
                        Spacer()
                        Text(store.speakerResult.label)
                            .foregroundStyle(.secondary)
                        if store.speakerConfidence > 0 {
                            Text("(\(Int(store.speakerConfidence * 100))%)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Toggle(isOn: Binding(
                        get: { store.speakerGateEnabled },
                        set: { _ in } // Read-only from this sheet
                    )) {
                        Label("Speaker Gate", systemImage: "person.badge.shield.checkmark")
                    }
                    .disabled(true)

                    Button {
                        store.send(.enrollSpeaker)
                    } label: {
                        Label("Enroll Voice", systemImage: "person.crop.circle.badge.plus")
                    }

                    Button(role: .destructive) {
                        store.send(.clearVoiceprint)
                    } label: {
                        Label("Clear Voiceprint", systemImage: "person.crop.circle.badge.minus")
                    }
                }

                // Gemini Observer Section
                Section("Gemini Observer") {
                    Toggle(isOn: Binding(
                        get: { store.geminiObserver.isEnabled },
                        set: { _ in store.send(.geminiObserver(.toggle)) }
                    )) {
                        Label("Silent Observer", systemImage: "eye")
                    }

                    HStack {
                        Label("Connection", systemImage: "wifi")
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(connectionColor)
                                .frame(width: 8, height: 8)
                            Text(store.geminiObserver.connectionState.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if store.geminiObserver.insightCount > 0 {
                        HStack {
                            Label("Insights", systemImage: "sparkle")
                            Spacer()
                            Text("\(store.geminiObserver.insightCount)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Always-On Section
                Section("Always-On Mode") {
                    Toggle(isOn: Binding(
                        get: { store.isAlwaysOnEnabled },
                        set: { _ in store.send(.toggleAlwaysOn) }
                    )) {
                        Label("Always Listening", systemImage: "ear.fill")
                    }

                    if store.filteredTranscriptCount > 0 {
                        HStack {
                            Label("Filtered (unknown)", systemImage: "person.fill.xmark")
                            Spacer()
                            Text("\(store.filteredTranscriptCount)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Session Section
                Section("Session") {
                    HStack {
                        Label("Turn Count", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        Text("\(store.turnCount)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Gateway", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(store.gatewayConnected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(store.gatewayConnected ? "Connected" : "Disconnected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        store.send(.resetConversation)
                    } label: {
                        Label("Reset Conversation", systemImage: "arrow.counterclockwise")
                    }

                    Button {
                        store.send(.toggleThreadBrowser)
                    } label: {
                        Label("Browse Threads", systemImage: "list.bullet")
                    }
                }
            }
            .navigationTitle("Voice Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var connectionColor: Color {
        switch store.geminiObserver.connectionState {
        case .disconnected: return .gray
        case .connecting, .settingUp: return .orange
        case .ready: return .green
        case .error: return .red
        }
    }
}
