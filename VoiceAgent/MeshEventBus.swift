import Foundation
import ComposableArchitecture
import OpenClawCore

// MARK: - Mesh Event Bus

public enum MeshEventCategory: String, Hashable, Sendable, CaseIterable {
    case basinTransition, consensus, tentacleHeartbeat, tentacleOffline
    case attentionShift, prediction, semanticFrame
    case agentSessionUpdate, pulseIterationComplete, poolEvent, costEvent
    case entityMention, dreamEvolution, newMessage, threadUpdate
}

public enum MeshEvent: Equatable, Sendable {
    case basinChanged(BasinState)
    case attentionShifted(AttentionTarget)
    case predictionMade(PredictionResult)
    case semanticFrameUpdated(SemanticFrame)
    case costRecorded(CostEvent)
    case messageReceived
    case threadUpdated
    case tentacleWentOffline
    case entityMentioned(String)
    case dreamEvolved(String)
}

public struct CostEvent: Equatable, Sendable {
    public let model: String
    public let estimatedCost: Double
    public let source: String

    public init(model: String, estimatedCost: Double, source: String) {
        self.model = model
        self.estimatedCost = estimatedCost
        self.source = source
    }
}

// MARK: - Event Bus

public struct MeshEventBus: Sendable {
    public var publish: @Sendable (MeshEvent) async -> Void
    public var subscribe: @Sendable (Set<MeshEventCategory>) -> AsyncStream<MeshEvent>
}

extension MeshEventBus: DependencyKey {
    public static let liveValue: MeshEventBus = {
        let storage = MeshEventStorage()
        return MeshEventBus(
            publish: { event in
                await storage.broadcast(event)
            },
            subscribe: { _ in
                AsyncStream { continuation in
                    let id = UUID()
                    Task {
                        await storage.addListener(id: id, continuation: continuation)
                    }
                    continuation.onTermination = { _ in
                        Task { await storage.removeListener(id: id) }
                    }
                }
            }
        )
    }()
}

private actor MeshEventStorage {
    var listeners: [UUID: AsyncStream<MeshEvent>.Continuation] = [:]

    func addListener(id: UUID, continuation: AsyncStream<MeshEvent>.Continuation) {
        listeners[id] = continuation
    }

    func removeListener(id: UUID) {
        listeners.removeValue(forKey: id)
    }

    func broadcast(_ event: MeshEvent) {
        for (_, continuation) in listeners {
            continuation.yield(event)
        }
    }
}

extension DependencyValues {
    public var meshEventBus: MeshEventBus {
        get { self[MeshEventBus.self] }
        set { self[MeshEventBus.self] = newValue }
    }
}
