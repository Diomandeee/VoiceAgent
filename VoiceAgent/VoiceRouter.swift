import Foundation
import OpenClawCore

/// Classifies spoken text into an intent and target ThreadCategory.
/// Adapted from Aura's VoiceRouter — maps intents to ThreadCategory
/// instead of Discord channel IDs.
enum VoiceRouter {

    // MARK: - Intent

    enum Intent: String, CaseIterable, Codable, Sendable {
        case idea, reminder, status, general
        case koji, leads, pipeline, deliveries, accounts
        case bwb, milkmen, spore, litrpg, lifeos, acc, serenity
        case mfp, mfpCards, mfpSales
        case creative, marketing
        case research, dream, workshop
        case finance, legal
        case build, pulse, task
        case data, search
        case compCore, cogTwin
        case nko

        /// Maps to the ThreadCategory for routing.
        var category: ThreadCategory {
            switch self {
            case .idea:       return .sandbox
            case .reminder:   return .bridge
            case .status:     return .bridge
            case .general:    return .agent
            case .koji:       return .agent
            case .leads:      return .agent
            case .pipeline:   return .agent
            case .deliveries: return .agent
            case .accounts:   return .agent
            case .bwb:        return .workshop
            case .milkmen:    return .agent
            case .spore:      return .sandbox
            case .litrpg:     return .sandbox
            case .lifeos:     return .agent
            case .acc:        return .infrastructure
            case .serenity:   return .serenity
            case .mfp:        return .sandbox
            case .mfpCards:   return .sandbox
            case .mfpSales:   return .agent
            case .creative:   return .creativeDirector
            case .marketing:  return .agent
            case .research:   return .research
            case .dream:      return .sandbox
            case .workshop:   return .workshop
            case .finance:    return .agent
            case .legal:      return .bridge
            case .build:      return .compCore
            case .pulse:      return .pulseControl
            case .task:       return .dispatch
            case .data:       return .research
            case .search:     return .research
            case .compCore:   return .compCore
            case .cogTwin:    return .compCore
            case .nko:        return .sandbox
            }
        }

        var emoji: String {
            switch self {
            case .idea: return "idea"; case .reminder: return "reminder"; case .status: return "status"
            case .general: return "general"; case .koji: return "koji"; case .leads: return "leads"
            case .pipeline: return "pipeline"; case .deliveries: return "deliveries"; case .accounts: return "accounts"
            case .bwb: return "bwb"; case .milkmen: return "milkmen"; case .spore: return "spore"
            case .litrpg: return "litrpg"; case .lifeos: return "lifeos"; case .acc: return "acc"
            case .serenity: return "serenity"; case .mfp: return "mfp"; case .mfpCards: return "mfpCards"
            case .mfpSales: return "mfpSales"; case .creative: return "creative"; case .marketing: return "marketing"
            case .research: return "research"; case .dream: return "dream"; case .workshop: return "workshop"
            case .finance: return "finance"; case .legal: return "legal"; case .build: return "build"
            case .pulse: return "pulse"; case .task: return "task"; case .data: return "data"
            case .search: return "search"; case .compCore: return "compCore"; case .cogTwin: return "cogTwin"
            case .nko: return "nko"
            }
        }

        var label: String { rawValue.capitalized }
    }

    // MARK: - Classified Result

    struct Classified: Equatable, Sendable {
        let intent: Intent
        let original: String
        let processed: String
        let category: ThreadCategory
        let channelName: String?
        let confidence: Double
    }

    // MARK: - Rules

    private static let rules: [(keys: [String], intent: Intent, conf: Double)] = [
        (["remind me", "don't forget", "remember to", "set reminder", "alert me",
          "set a timer", "set timer", "wake me"],
         .reminder, 0.95),
        (["koji", "oat milk", "koatji"], .koji, 0.90),
        (["lead", "prospect", "new contact", "cold call", "outreach"], .leads, 0.90),
        (["pipeline", "forecast", "deal", "close rate", "conversion"], .pipeline, 0.90),
        (["delivery", "deliveries", "route", "drop off", "wednesday run"], .deliveries, 0.90),
        (["account", "partner", "reorder", "active customer"], .accounts, 0.85),
        (["sales", "revenue", "quota", "commission"], .pipeline, 0.85),
        (["bwb", "barista", "point of sale", "kiosk"], .bwb, 0.90),
        (["milkmen", "milk men", "delivery app"], .milkmen, 0.90),
        (["spore", "idea garden", "growth app"], .spore, 0.90),
        (["litrpg", "eternal serenity", "lit rpg", "rpg game"], .litrpg, 0.90),
        (["life os", "lifeos", "watch app", "apple watch", "accountability"], .lifeos, 0.90),
        (["command center", "agent command", "acc"], .acc, 0.85),
        (["serenity", "meditation", "therapeutic", "guided relaxation"], .serenity, 0.90),
        (["meaning full power", "mfp", "trading card", "card game"], .mfp, 0.90),
        (["card design", "card art", "physical card", "printing", "packaging", "booster pack"], .mfpCards, 0.88),
        (["tiktok shop", "creator commerce", "card sales"], .mfpSales, 0.88),
        (["creative", "design", "artwork", "visual", "brand", "adobe", "photoshop",
          "illustrator", "after effects", "indesign"], .creative, 0.85),
        (["marketing", "campaign", "social media", "content calendar", "newsletter", "blog"], .marketing, 0.85),
        (["research", "investigate", "look into", "find out about", "deep dive", "analyze"], .research, 0.90),
        (["dream", "incubate", "garden", "bloom", "seed an idea"], .dream, 0.90),
        (["workshop", "brainstorm", "evolve", "evoflow", "creative session"], .workshop, 0.85),
        (["idea", "thought", "what if", "concept", "imagine", "shower thought"], .idea, 0.85),
        (["finance", "budget", "expense", "invoice", "p&l", "profit", "cost"], .finance, 0.85),
        (["legal", "contract", "nda", "compliance", "agreement", "terms"], .legal, 0.85),
        (["create a task", "add task", "new task", "add a task", "create task",
          "make a task", "task for"], .task, 0.95),
        (["build", "implement", "code", "fix", "refactor", "deploy", "ship"], .build, 0.85),
        (["pulse", "run a pulse", "start pulse", "autonomous"], .pulse, 0.90),
        (["data", "query", "sql", "dashboard", "analytics", "metric", "chart"], .data, 0.85),
        (["search", "find", "look up", "retrieve"], .search, 0.80),
        (["comp core", "compcore", "kernel", "graph kernel", "rag"], .compCore, 0.85),
        (["cognitive twin", "twin", "fine tune", "lora", "corpus"], .cogTwin, 0.85),
        (["health", "water", "sleep", "steps", "exercise", "workout", "calories",
          "heart rate", "walked", "drank", "ate", "food", "weight"], .lifeos, 0.85),
        (["nko", "n'ko", "manding", "bambara", "script"], .nko, 0.90),
        (["status", "what's happening", "what is happening", "update",
          "how are things", "report"], .status, 0.85),
    ]

    // MARK: - Classification

    static func classify(_ text: String) -> Classified {
        if let explicit = classifyExplicit(text) { return explicit }

        let low = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for rule in rules {
            for key in rule.keys where low.contains(key) {
                let intent = rule.intent
                return Classified(
                    intent: intent,
                    original: text,
                    processed: strip(text, intent: intent),
                    category: intent.category,
                    channelName: intent.category.channelName,
                    confidence: rule.conf
                )
            }
        }

        return Classified(
            intent: .general,
            original: text,
            processed: text,
            category: .agent,
            channelName: ThreadCategory.agent.channelName,
            confidence: 0.5
        )
    }

    // MARK: - Explicit Channel Routing

    private static func classifyExplicit(_ text: String) -> Classified? {
        let low = text.lowercased()
        let patterns = [
            "send to #?(\\w[\\w-]*)",
            "post (?:in|to) #?(\\w[\\w-]*)",
            "(?:in|to) the (\\w[\\w-]*) channel",
            "route (?:to|this to) #?(\\w[\\w-]*)",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: low, range: NSRange(low.startIndex..., in: low)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: low) {
                let channelName = String(low[range])
                // Find matching ThreadCategory by channelName
                let category = ThreadCategory.conversationCapable.first {
                    $0.channelName == channelName || $0.rawValue == channelName
                } ?? .agent
                let intent = Intent.allCases.first { $0.category == category } ?? .general
                return Classified(
                    intent: intent,
                    original: text,
                    processed: text,
                    category: category,
                    channelName: category.channelName,
                    confidence: 0.95
                )
            }
        }
        return nil
    }

    // MARK: - Prefix Stripping

    private static func strip(_ text: String, intent: Intent) -> String {
        let prefixes: [String]
        switch intent {
        case .reminder:
            prefixes = ["remind me to ", "remind me ", "don't forget to ",
                        "don't forget ", "remember to ", "set reminder ",
                        "set a timer for ", "set timer for "]
        case .idea, .dream:
            prefixes = ["i have an idea ", "idea ", "what if ",
                        "seed an idea ", "incubate "]
        case .research:
            prefixes = ["research ", "look into ", "investigate ",
                        "find out about ", "deep dive into "]
        case .task:
            prefixes = ["create a task ", "create task ", "add a task ",
                        "add task ", "new task ", "make a task ", "task for "]
        case .build:
            prefixes = ["build ", "implement ", "code ", "fix "]
        case .pulse:
            prefixes = ["run a pulse on ", "start pulse for ", "pulse "]
        default:
            return text
        }
        for p in prefixes where text.lowercased().hasPrefix(p) {
            return String(text.dropFirst(p.count))
        }
        return text
    }
}
