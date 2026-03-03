import SwiftUI
import ComposableArchitecture
import OpenClawCore

/// Full-screen voice conversation UI — Aura "Direct to Claw" parity.
struct DirectVoiceView: View {
    @Bindable var store: StoreOf<DirectVoiceFeature>

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            statusBar

            Spacer()

            // Central voice indicator
            centralIndicator

            // Transcript overlay
            transcriptArea

            // Response card
            if !store.clawResponse.isEmpty {
                responseCard
            }

            // Gemini insight banner
            if let insight = store.geminiObserver.latestInsight {
                geminiInsightBanner(insight)
            }

            Spacer()

            // Error
            if let error = store.error {
                errorBanner(error)
            }

            // Activity trace
            if !store.activityTrace.isEmpty {
                activityTraceView
            }

            // Channel selector
            channelSelector

            // Bottom controls
            bottomControls
        }
        .background(Color(.systemBackground))
        .task {
            store.send(.startSession)
        }
        .sheet(isPresented: Binding(
            get: { store.showSettings },
            set: { _ in store.send(.toggleSettings) }
        )) {
            VoiceSettingsSheet(store: store)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: Binding(
            get: { store.showThreadBrowser },
            set: { _ in store.send(.toggleThreadBrowser) }
        )) {
            VoiceThreadBrowser(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            // Connection indicator
            Circle()
                .fill(store.gatewayConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            // Speaker ID badge
            if store.speakerResult != .unknown {
                HStack(spacing: 4) {
                    Image(systemName: store.speakerResult.icon)
                        .font(.caption2)
                    Text(store.speakerResult.label)
                        .font(.caption2.weight(.medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    store.speakerResult == .owner
                        ? Color.green.opacity(0.15)
                        : Color.orange.opacity(0.15)
                )
                .clipShape(Capsule())
            }

            // TTS verbosity badge
            Button {
                store.send(.cycleTTSVerbosity)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: store.ttsVerbosity.icon)
                        .font(.caption2)
                    Text(store.ttsVerbosity.displayName)
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Category indicator
            HStack(spacing: 4) {
                Image(systemName: store.activeCategory.icon)
                    .font(.caption2)
                Text(store.activeCategory.displayName)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(.indigo)

            // Turn counter
            Text("T\(store.turnCount)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)

            // Gemini observer dot
            if store.geminiObserver.isEnabled {
                Circle()
                    .fill(store.geminiObserver.connectionState == .ready ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                    .overlay(
                        Circle()
                            .stroke(Color.green.opacity(0.3), lineWidth: 1)
                            .scaleEffect(store.geminiObserver.connectionState == .ready ? 1.5 : 1)
                            .opacity(store.geminiObserver.connectionState == .ready ? 0 : 1)
                            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false), value: store.geminiObserver.connectionState)
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Central Indicator

    private var centralIndicator: some View {
        ZStack {
            // Outer animation ring
            if store.voiceState == .backgroundListening {
                // Breathing animation for always-on
                Circle()
                    .stroke(Color.indigo.opacity(0.2), lineWidth: 2)
                    .frame(width: 120, height: 120)
                    .scaleEffect(1.1)
                    .opacity(0.5)
                    .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: store.voiceState)
            }

            if store.voiceState == .listening {
                // Pulsing for active listening
                Circle()
                    .stroke(Color.indigo.opacity(0.3), lineWidth: 3)
                    .frame(width: 120, height: 120)
                    .scaleEffect(1.3)
                    .opacity(0)
                    .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: store.voiceState)
            }

            if store.voiceState == .processing {
                // Spinning for processing
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(Color.indigo, lineWidth: 3)
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(360))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: store.voiceState)
            }

            // Main circle
            Circle()
                .fill(circleColor)
                .frame(width: 90, height: 90)
                .shadow(color: circleColor.opacity(0.3), radius: 12, y: 4)

            Image(systemName: circleIcon)
                .font(.system(size: 32))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor, isActive: store.isListening)
        }
        .onTapGesture {
            if store.isListening {
                store.send(.stopListening)
            } else {
                store.send(.startListening)
            }
        }
        .padding(.vertical, 20)
    }

    private var circleColor: Color {
        switch store.voiceState {
        case .idle: return .indigo
        case .listening: return .red
        case .processing: return .orange
        case .responded: return .green
        case .error: return .red.opacity(0.7)
        case .backgroundListening: return .indigo.opacity(0.6)
        }
    }

    private var circleIcon: String {
        switch store.voiceState {
        case .idle: return "mic.fill"
        case .listening: return "waveform"
        case .processing: return "ellipsis"
        case .responded: return "checkmark"
        case .error: return "exclamationmark.triangle"
        case .backgroundListening: return "ear"
        }
    }

    // MARK: - Transcript Area

    private var transcriptArea: some View {
        Group {
            if !store.interimTranscript.isEmpty {
                Text(store.interimTranscript)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
            } else if !store.finalTranscript.isEmpty && store.voiceState == .processing {
                Text(store.finalTranscript)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(minHeight: 40)
        .animation(.easeInOut(duration: 0.2), value: store.interimTranscript)
    }

    // MARK: - Response Card

    private var responseCard: some View {
        ScrollView {
            Text(store.clawResponse)
                .font(.body)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 200)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Gemini Insight Banner

    private func geminiInsightBanner(_ insight: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.caption)
                .foregroundStyle(.purple)
            Text(insight)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button {
                store.send(.geminiObserver(.clearInsight))
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
            Button {
                store.send(.clearError)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Activity Trace

    private var activityTraceView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(store.activityTrace) { entry in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(traceColor(entry.level))
                                .frame(width: 5, height: 5)
                            Text(entry.message)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(traceColor(entry.level))
                            Spacer()
                            Text(entry.timestamp, style: .time)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.quaternary)
                        }
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 80)
            .background(Color(.secondarySystemBackground).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .onChange(of: store.activityTrace.last?.id) { _, newId in
                if let newId {
                    withAnimation { proxy.scrollTo(newId, anchor: .bottom) }
                }
            }
        }
    }

    private func traceColor(_ level: DirectVoiceFeature.State.TraceEntry.TraceLevel) -> Color {
        switch level {
        case .info: return .secondary
        case .success: return .green
        case .error: return .red
        case .processing: return .orange
        }
    }

    // MARK: - Channel Selector

    private var channelSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ThreadCategory.conversationCapable, id: \.self) { category in
                    Button {
                        store.send(.selectCategory(category))
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: category.icon)
                                .font(.caption2)
                            Text(category.displayName)
                                .font(.caption2.weight(.medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            store.activeCategory == category
                                ? Color.indigo.opacity(0.15)
                                : Color(.tertiarySystemFill)
                        )
                        .foregroundStyle(
                            store.activeCategory == category
                                ? .indigo
                                : .secondary
                        )
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        HStack(spacing: 20) {
            // Always-on toggle
            Button {
                store.send(.toggleAlwaysOn)
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: store.isAlwaysOnEnabled ? "ear.fill" : "ear")
                        .font(.title3)
                        .foregroundStyle(store.isAlwaysOnEnabled ? .green : .secondary)
                    Text("Always")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Mute toggle
            Button {
                store.send(.toggleMute)
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: store.ttsMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.title3)
                        .foregroundStyle(store.ttsMuted ? .orange : .secondary)
                    Text(store.ttsMuted ? "Muted" : "Sound")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Main mic button
            Button {
                if store.isListening {
                    store.send(.stopListening)
                } else {
                    store.send(.startListening)
                }
            } label: {
                Circle()
                    .fill(store.isListening ? Color.red : Color.indigo)
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: store.isListening ? "stop.fill" : "mic.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: (store.isListening ? Color.red : Color.indigo).opacity(0.3), radius: 8, y: 4)
            }
            .disabled(store.micPermission == .denied)

            // Model picker
            Menu {
                ForEach(AgentModel.allCases, id: \.self) { model in
                    Button {
                        store.send(.selectModel(model))
                    } label: {
                        Label(model.displayName, systemImage: model.icon)
                    }
                }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: store.selectedModel.icon)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(store.selectedModel.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Settings
            Button {
                store.send(.toggleSettings)
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Settings")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 30)
    }
}
