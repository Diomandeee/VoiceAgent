import Foundation
import Supabase
import PostgREST
import Realtime
import ComposableArchitecture
import OpenClawCore
import OpenClawSupabase

// MARK: - Infrastructure Client (mesh nodes, pulse, tasks)

public struct InfraClient: Sendable {
    public var fetchNodes: @Sendable () async throws -> [MeshNode]
    public var fetchActivePulseSessions: @Sendable () async throws -> [PulseSession]
    public var fetchTaskQueueStats: @Sendable () async throws -> TaskQueueStats
    public var fetchRecentTasks: @Sendable (_ limit: Int) async throws -> [MACTask]
    public var createMACTask: @Sendable (_ content: String, _ project: String?, _ priority: Int, _ model: String?, _ source: String?) async throws -> MACTask
    public var pausePulseSession: @Sendable (_ sessionId: UUID) async throws -> Void
    public var resumePulseSession: @Sendable (_ sessionId: UUID) async throws -> Void
    public var abortPulseSession: @Sendable (_ sessionId: UUID) async throws -> Void
    public var startPulseSession: @Sendable (_ projectName: String, _ projectPath: String, _ goal: String, _ maxIterations: Int) async throws -> PulseSession
    public var fetchPulseSessionDetail: @Sendable (_ sessionId: UUID) async throws -> PulseSession
    public var fetchAllPulseSessions: @Sendable (_ limit: Int) async throws -> [PulseSession]
    public var subscribeToPulseSessions: @Sendable () -> AsyncStream<PulseSession>
}

// MARK: - Live Implementation

private let infraSupabase = SupabaseClient(
    supabaseURL: URL(string: OpenClawConfig.supabaseUrlString)!,
    supabaseKey: OpenClawConfig.supabaseAnonKey
)

extension InfraClient: DependencyKey {
    public static let liveValue = InfraClient(
        fetchNodes: {
            let nodes: [MeshNode] = try await infraSupabase.from("mesh_devices")
                .select().order("last_heartbeat", ascending: false).execute().value
            return nodes
        },
        fetchActivePulseSessions: {
            let sessions: [PulseSession] = try await infraSupabase.from("pulse_sessions")
                .select()
                .in("status", values: ["running", "paused", "pending"])
                .order("updated_at", ascending: false)
                .limit(20).execute().value
            return sessions
        },
        fetchTaskQueueStats: {
            struct TaskRow: Decodable { let status: String? }
            let rows: [TaskRow] = try await infraSupabase.from("mac_tasks")
                .select("status")
                .gte("created_at", value: ISO8601DateFormatter().string(from: Calendar.current.date(byAdding: .day, value: -1, to: Date())!))
                .execute().value
            var stats = TaskQueueStats()
            for row in rows {
                switch row.status {
                case "pending": stats.pending += 1
                case "running": stats.running += 1
                case "completed", "complete": stats.completed += 1
                case "failed", "error": stats.failed += 1
                default: break
                }
            }
            return stats
        },
        fetchRecentTasks: { limit in
            let tasks: [MACTask] = try await infraSupabase.from("mac_tasks")
                .select().order("created_at", ascending: false).limit(limit).execute().value
            return tasks
        },
        createMACTask: { content, project, priority, model, source in
            var values: [String: String] = [
                "task_content": content,
                "priority": String(priority),
                "source": source ?? "openclaw-app",
                "status": "pending",
            ]
            if let project { values["project_path"] = project }
            if let model { values["model_preference"] = model }
            let task: MACTask = try await infraSupabase.from("mac_tasks")
                .insert(values).select().single().execute().value
            return task
        },
        pausePulseSession: { sessionId in
            try await infraSupabase.from("pulse_sessions")
                .update(["status": "paused"])
                .eq("id", value: sessionId.uuidString).execute()
        },
        resumePulseSession: { sessionId in
            try await infraSupabase.from("pulse_sessions")
                .update(["status": "running"])
                .eq("id", value: sessionId.uuidString).execute()
        },
        abortPulseSession: { sessionId in
            let now = ISO8601DateFormatter().string(from: Date())
            try await infraSupabase.from("pulse_sessions")
                .update(["status": "aborted", "completed_at": now])
                .eq("id", value: sessionId.uuidString).execute()
        },
        startPulseSession: { projectName, projectPath, goal, maxIterations in
            let values: [String: String] = [
                "project_name": projectName,
                "project_path": projectPath,
                "goal": goal,
                "max_iterations": String(maxIterations),
                "current_iteration": "0",
                "status": "pending",
                "created_by": "openclaw-app",
            ]
            let session: PulseSession = try await infraSupabase.from("pulse_sessions")
                .insert(values).select().single().execute().value
            return session
        },
        fetchPulseSessionDetail: { sessionId in
            let session: PulseSession = try await infraSupabase.from("pulse_sessions")
                .select().eq("id", value: sessionId.uuidString).single().execute().value
            return session
        },
        fetchAllPulseSessions: { limit in
            let sessions: [PulseSession] = try await infraSupabase.from("pulse_sessions")
                .select().order("created_at", ascending: false).limit(limit).execute().value
            return sessions
        },
        subscribeToPulseSessions: {
            AsyncStream { continuation in
                let channel = infraSupabase.realtimeV2.channel("pulse-sessions-app")
                let inserts = channel.postgresChange(InsertAction.self, table: "pulse_sessions")
                let updates = channel.postgresChange(UpdateAction.self, table: "pulse_sessions")
                Task {
                    await channel.subscribe()
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for await insertion in inserts {
                                if let session = try? insertion.decodeRecord(as: PulseSession.self, decoder: JSONDecoder()) {
                                    continuation.yield(session)
                                }
                            }
                        }
                        group.addTask {
                            for await update in updates {
                                if let session = try? update.decodeRecord(as: PulseSession.self, decoder: JSONDecoder()) {
                                    continuation.yield(session)
                                }
                            }
                        }
                    }
                }
                continuation.onTermination = { _ in
                    Task { await infraSupabase.realtimeV2.removeChannel(channel) }
                }
            }
        }
    )
}

extension DependencyValues {
    public var infraClient: InfraClient {
        get { self[InfraClient.self] }
        set { self[InfraClient.self] = newValue }
    }
}
