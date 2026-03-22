import Foundation
import SwiftData

/// A GGUF model stored on disk.
@Model
final class StoredModel {
    var name: String = ""
    var filename: String = ""
    var sizeBytes: Int64 = 0
    var quantization: String = ""
    var paramCountB: Double = 0.0
    var downloadedAt: Date = Date()
    var lastUsedAt: Date?
    var huggingFaceId: String = ""
    var isLoaded: Bool = false
    var scope: String = "home"

    init(name: String, filename: String, sizeBytes: Int64, quantization: String = "", paramCountB: Double = 0.0) {
        self.name = name
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.quantization = quantization
        self.paramCountB = paramCountB
        self.downloadedAt = Date()
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var tier: ModelTier {
        ModelTier.classify(paramCountB: paramCountB)
    }
}

/// A chat message in a session.
@Model
final class ChatMessage {
    var role: String = "user"   // "user", "assistant", "system"
    var content: String = ""
    var timestamp: Date = Date()
    var tokenCount: Int = 0
    var model: String = ""
    var routedVia: String = "local"  // "local", peer ID, "fleet"
    var session: ChatSession?

    init(role: String, content: String, model: String = "", routedVia: String = "local") {
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.model = model
        self.routedVia = routedVia
    }
}

/// A chat session (conversation).
@Model
final class ChatSession {
    var title: String = "New Chat"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var model: String = ""
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)
    var messages: [ChatMessage] = []

    init(title: String = "New Chat", model: String = "") {
        self.title = title
        self.model = model
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

/// Persistent activity event.
@Model
final class ActivityEvent {
    var kind: String = ""
    var detail: String = ""
    var timestamp: Date = Date()

    init(kind: String, detail: String = "") {
        self.kind = kind
        self.detail = detail
        self.timestamp = Date()
    }
}
