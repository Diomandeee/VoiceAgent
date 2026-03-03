import Foundation
import Supabase
import PostgREST
import Realtime
import ComposableArchitecture
import OpenClawCore
import OpenClawSupabase

// MARK: - Hub Client (Supabase wrapper)

public struct HubClient: Sendable {
    public var fetchThreads: @Sendable (_ category: String?, _ type: ThreadType?, _ limit: Int) async throws -> [HubThread]
    public var fetchMessages: @Sendable (_ threadId: UUID, _ limit: Int, _ before: Date?) async throws -> [HubMessage]
    public var createThread: @Sendable (_ type: ThreadType, _ category: String, _ title: String, _ subtitle: String?, _ sessionKey: String?, _ macTaskId: UUID?) async throws -> HubThread
    public var sendMessage: @Sendable (_ threadId: UUID, _ content: String, _ contentType: ContentType, _ embedData: EmbedData?, _ senderType: SenderType, _ senderLabel: String) async throws -> HubMessage
    public var updateThread: @Sendable (_ threadId: UUID, _ fields: [String: String]) async throws -> Void
    public var markRead: @Sendable (_ threadId: UUID) async throws -> Void
    public var togglePin: @Sendable (_ threadId: UUID, _ pinned: Bool) async throws -> Void
    public var toggleMute: @Sendable (_ threadId: UUID, _ muted: Bool) async throws -> Void
    public var addReaction: @Sendable (_ messageId: UUID, _ emoji: String) async throws -> Void
    public var addBookmark: @Sendable (_ threadId: UUID?, _ messageId: UUID?, _ note: String?) async throws -> Void
    public var resolveThread: @Sendable (_ threadId: UUID) async throws -> Void
    public var subscribeToMessages: @Sendable (_ threadId: UUID) -> AsyncStream<HubMessage>
    public var subscribeToThreadUpdates: @Sendable () -> AsyncStream<HubThread>
    public var fetchUnreadCounts: @Sendable (_ userId: UUID) async throws -> [UUID: Int]
}

extension HubClient: DependencyKey {
    public static let liveValue = HubClient(
        fetchThreads: { category, type, limit in
            var query = supabase.from("hub_threads").select()
            if let category { query = query.eq("category", value: category) }
            if let type { query = query.eq("type", value: type.rawValue) }
            let threads: [HubThread] = try await query
                .order("last_message_at", ascending: false)
                .limit(limit)
                .execute()
                .value
            return threads
        },
        fetchMessages: { threadId, limit, before in
            var query = supabase.from("hub_messages")
                .select()
                .eq("thread_id", value: threadId.uuidString)
            if let before {
                query = query.lt("created_at", value: ISO8601DateFormatter().string(from: before))
            }
            let messages: [HubMessage] = try await query
                .order("created_at", ascending: false)
                .limit(limit)
                .execute()
                .value
            return messages.reversed()
        },
        createThread: { type, category, title, subtitle, sessionKey, macTaskId in
            var values: [String: String] = [
                "type": type.rawValue,
                "category": category,
                "title": title,
                "subtitle": subtitle ?? "",
            ]
            if let sessionKey { values["session_key"] = sessionKey }
            if let macTaskId { values["mac_task_id"] = macTaskId.uuidString }
            let thread: HubThread = try await supabase.from("hub_threads")
                .insert(values).select().single().execute().value
            return thread
        },
        sendMessage: { threadId, content, contentType, embedData, senderType, senderLabel in
            struct MessageInsert: Encodable {
                let thread_id: String
                let sender_type: String
                let sender_label: String
                let content: String
                let content_type: String
                var embed_data: EmbedData?
            }
            let insert = MessageInsert(
                thread_id: threadId.uuidString,
                sender_type: senderType.rawValue,
                sender_label: senderLabel,
                content: content,
                content_type: contentType.rawValue,
                embed_data: embedData
            )
            let message: HubMessage = try await supabase.from("hub_messages")
                .insert(insert).select().single().execute().value
            return message
        },
        updateThread: { threadId, fields in
            try await supabase.from("hub_threads")
                .update(fields)
                .eq("id", value: threadId.uuidString)
                .execute()
        },
        markRead: { threadId in
            let deviceKey = "device_uuid"
            let deviceId: UUID
            if let stored = KeychainHelper.read(key: deviceKey), let uuid = UUID(uuidString: stored) {
                deviceId = uuid
            } else {
                let newId = UUID()
                _ = KeychainHelper.save(key: deviceKey, value: newId.uuidString)
                deviceId = newId
            }
            try await supabase.from("hub_thread_reads")
                .upsert([
                    "thread_id": threadId.uuidString,
                    "user_id": deviceId.uuidString,
                    "last_read_at": ISO8601DateFormatter().string(from: Date()),
                ])
                .execute()
        },
        togglePin: { threadId, pinned in
            try await supabase.from("hub_threads")
                .update(["is_pinned": String(pinned)])
                .eq("id", value: threadId.uuidString)
                .execute()
        },
        toggleMute: { threadId, muted in
            try await supabase.from("hub_threads")
                .update(["is_muted": String(muted)])
                .eq("id", value: threadId.uuidString)
                .execute()
        },
        addReaction: { messageId, emoji in
            try await supabase.from("hub_reactions")
                .insert(["message_id": messageId.uuidString, "emoji": emoji])
                .execute()
        },
        addBookmark: { threadId, messageId, note in
            var values: [String: String] = [:]
            if let threadId { values["thread_id"] = threadId.uuidString }
            if let messageId { values["message_id"] = messageId.uuidString }
            if let note { values["note"] = note }
            try await supabase.from("hub_bookmarks").insert(values).execute()
        },
        resolveThread: { threadId in
            try await supabase.from("hub_threads")
                .update(["is_resolved": "true"])
                .eq("id", value: threadId.uuidString)
                .execute()
        },
        subscribeToMessages: { threadId in
            AsyncStream { continuation in
                let channel = supabase.realtimeV2.channel("hub-messages-\(threadId.uuidString)")
                let insertions = channel.postgresChange(InsertAction.self, table: "hub_messages")
                Task {
                    await channel.subscribe()
                    for await insertion in insertions {
                        if let message = try? insertion.decodeRecord(as: HubMessage.self, decoder: JSONDecoder()) {
                            if message.threadId == threadId {
                                continuation.yield(message)
                            }
                        }
                    }
                }
                continuation.onTermination = { _ in
                    Task { await supabase.realtimeV2.removeChannel(channel) }
                }
            }
        },
        subscribeToThreadUpdates: {
            AsyncStream { continuation in
                let channel = supabase.realtimeV2.channel("hub-threads")
                let updates = channel.postgresChange(UpdateAction.self, table: "hub_threads")
                Task {
                    await channel.subscribe()
                    for await update in updates {
                        if let thread = try? update.decodeRecord(as: HubThread.self, decoder: JSONDecoder()) {
                            continuation.yield(thread)
                        }
                    }
                }
                continuation.onTermination = { _ in
                    Task { await supabase.realtimeV2.removeChannel(channel) }
                }
            }
        },
        fetchUnreadCounts: { userId in
            struct ReadRecord: Decodable {
                let threadId: UUID
                let lastReadAt: Date
                enum CodingKeys: String, CodingKey {
                    case threadId = "thread_id"
                    case lastReadAt = "last_read_at"
                }
            }
            let reads: [ReadRecord] = try await supabase.from("hub_thread_reads")
                .select("thread_id, last_read_at")
                .eq("user_id", value: userId.uuidString)
                .execute().value
            var readMap: [UUID: Date] = [:]
            for r in reads { readMap[r.threadId] = r.lastReadAt }

            struct ThreadSummary: Decodable {
                let id: UUID
                let lastMessageAt: Date?
                let messageCount: Int
                enum CodingKeys: String, CodingKey {
                    case id
                    case lastMessageAt = "last_message_at"
                    case messageCount = "message_count"
                }
            }
            let threads: [ThreadSummary] = try await supabase.from("hub_threads")
                .select("id, last_message_at, message_count")
                .gt("message_count", value: 0)
                .execute().value

            var counts: [UUID: Int] = [:]
            let formatter = ISO8601DateFormatter()
            for thread in threads {
                guard let lastMsg = thread.lastMessageAt else { continue }
                if let lastRead = readMap[thread.id] {
                    if lastRead >= lastMsg { continue }
                    struct MsgId: Decodable { let id: UUID }
                    let msgs: [MsgId] = try await supabase.from("hub_messages")
                        .select("id")
                        .eq("thread_id", value: thread.id.uuidString)
                        .gt("created_at", value: formatter.string(from: lastRead))
                        .execute().value
                    if !msgs.isEmpty { counts[thread.id] = msgs.count }
                } else {
                    counts[thread.id] = thread.messageCount
                }
            }
            return counts
        }
    )
}

extension DependencyValues {
    public var hubClient: HubClient {
        get { self[HubClient.self] }
        set { self[HubClient.self] = newValue }
    }
}

// MARK: - Supabase singleton

private let supabase = SupabaseClient(
    supabaseURL: URL(string: OpenClawConfig.supabaseUrlString)!,
    supabaseKey: OpenClawConfig.supabaseAnonKey
)
