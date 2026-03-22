import Foundation
import SwiftData

/// SwiftData container configuration.
enum AppDatabase {
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            StoredModel.self,
            ChatMessage.self,
            ChatSession.self,
            ActivityEvent.self,
        ])
        let config = ModelConfiguration(
            "Mycellm",
            schema: schema,
            isStoredInMemoryOnly: false
        )
        return try ModelContainer(for: schema, configurations: [config])
    }
}
