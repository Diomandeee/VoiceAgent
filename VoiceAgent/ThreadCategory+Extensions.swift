import OpenClawCore

extension ThreadCategory {
    /// Categories that support interactive voice conversation.
    static var conversationCapable: [ThreadCategory] {
        [.agent, .research, .creativeDirector, .compCore, .workshop, .sandbox, .quick, .bridge, .infrastructure, .serenity,
         .caePhotoshop, .caeAfterEffects, .caePremiere, .caeIllustrator]
    }
}
