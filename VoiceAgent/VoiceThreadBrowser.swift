import SwiftUI
import ComposableArchitecture
import OpenClawCore


/// Voice thread list — browse and switch between voice conversation threads.
struct VoiceThreadBrowser: View {
    let store: StoreOf<DirectVoiceFeature>

    @State private var threads: [HubThread] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading threads...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if threads.isEmpty {
                    ContentUnavailableView(
                        "No Voice Threads",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Voice conversations will appear here after your first session.")
                    )
                } else {
                    List(threads) { thread in
                        Button {
                            store.send(.switchThread(thread.id))
                            store.send(.toggleThreadBrowser)
                        } label: {
                            threadRow(thread)
                        }
                    }
                }
            }
            .navigationTitle("Voice Threads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.send(.createNewThread(store.activeCategory))
                        store.send(.toggleThreadBrowser)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .task {
                await loadThreads()
            }
        }
    }

    private func threadRow(_ thread: HubThread) -> some View {
        HStack(spacing: 12) {
            // Category icon
            let category = ThreadCategory(rawValue: thread.category) ?? .agent
            Image(systemName: category.icon)
                .font(.title3)
                .foregroundStyle(.indigo)
                .frame(width: 36, height: 36)
                .background(Color.indigo.opacity(0.1))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(category.displayName)
                        .font(.caption)
                        .foregroundStyle(.indigo)

                    Text("\(thread.messageCount) msgs")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let lastMsg = thread.lastMessageAt {
                        Text(lastMsg, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Active indicator
            if thread.id == store.activeThreadId {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func loadThreads() async {
        isLoading = true
        do {
            // Fetch conversation threads across voice-capable categories
            @Dependency(\.hubClient) var hubClient
            let allThreads = try await hubClient.fetchThreads(nil, .conversation, 50)
            threads = allThreads.filter { thread in
                guard let category = ThreadCategory(rawValue: thread.category) else { return false }
                return ThreadCategory.conversationCapable.contains(category)
            }
        } catch {
            NSLog("[VoiceThreadBrowser] Failed to load threads: %@", error.localizedDescription)
        }
        isLoading = false
    }
}
