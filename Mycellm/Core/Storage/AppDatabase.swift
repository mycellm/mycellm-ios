import Foundation
import SwiftData

extension Notification.Name {
    /// Posted when chat sync is toggled. `MycellmApp` rebuilds the container —
    /// the only way to attach or detach CloudKit from a SwiftData store.
    static let chatSyncSettingChanged = Notification.Name("mycellm.chatSyncSettingChanged")
}

/// SwiftData container configuration.
///
/// ⚠️ TWO STORES, BECAUSE SYNC IS PER-STORE AND NOT EVERYTHING SHOULD SYNC.
/// SwiftData syncs a whole configuration to CloudKit or none of it, and only
/// chat belongs in iCloud: model inventory describes files that live on *this*
/// device (and which are deliberately excluded from backup — syncing a
/// catalogue of them would contradict that), and the activity log is local
/// telemetry nobody wants merged across devices. So chat gets its own store
/// with CloudKit on, and everything else stays put.
enum AppDatabase {

    /// Chat — synced to the user's private CloudKit database.
    static let chatTypes: [any PersistentModel.Type] = [ChatSession.self, ChatMessage.self]

    /// Device-local: model inventory and activity telemetry.
    static let localTypes: [any PersistentModel.Type] = [StoredModel.self, ActivityEvent.self]

    /// ⚠️ THE PRE-SPLIT STORE IS THE *DEFAULT* ONE, NOT A NAMED "Mycellm".
    /// `MycellmApp` built its container with
    /// `ModelContainer(for: StoredModel.self, …)` — no configuration — so
    /// SwiftData used the default store, `default.store`. A migration that went
    /// looking for `Mycellm.store` would find nothing, conclude there was
    /// nothing to carry, and mark itself done: chat history left behind in a
    /// file nothing opens again, with no error anywhere.
    static let localStoreName = "MycellmLocal"
    static let chatStoreName = "MycellmChat"

    /// SwiftData's default store filename, which is what every build so far has
    /// actually been writing to.
    static let legacyStoreFilename = "default.store"

    /// The CloudKit container from the App ID's iCloud capability. Must match
    /// `com.apple.developer.icloud-container-identifiers` in the entitlements or
    /// the container fails to open at launch.
    static let cloudContainerID = "iCloud.com.mycellm.app"

    /// Whether the chat store is attached to CloudKit. Read at container
    /// creation — SwiftData fixes this per configuration, so changing it means
    /// rebuilding the container (see `Preferences.chatSyncEnabled`).
    static var syncEnabled: Bool {
        UserDefaults.standard.bool(forKey: Preferences.chatSyncKey)
    }

    /// What the *live* container was built with, as opposed to what the
    /// preference now says. They differ after a toggle and before a relaunch,
    /// which is exactly when the UI needs to explain itself.
    nonisolated(unsafe) private(set) static var activeSyncSetting: Bool?

    /// Build the container, falling back to the original single store if the
    /// split cannot be opened.
    ///
    /// ⚠️ A STORAGE REORGANISATION MUST NEVER BRICK THE APP. This threw on
    /// device and `MycellmApp` stored the `try?` result — nil — then rendered
    /// its `if let container` branch, which has no else. The app launched to a
    /// black screen with no node, no UI and no error: every symptom of a crash
    /// except the crash. Whatever goes wrong with two configurations, opening
    /// the store the app has always used is still possible, so that is the
    /// floor. Sync and the split are features; launching is not.
    static func makeContainer() -> ModelContainer? {
        do {
            return try makeSplitContainer()
        } catch {
            LogBroadcaster.shared.error(
                "mycellm.storage",
                "Split container failed (\(error)) — falling back to the single store. "
                + "Chat sync is unavailable this launch.")
            splitFailure = String(describing: error)
            if let legacy = try? makeLegacyContainer() { return legacy }
            // ⚠️ NO `try!` HERE. The last resort existed so the UI could still
            // come up and explain itself; written with try! it did the opposite,
            // turning a degraded launch into a hard crash on the one path that
            // only runs when everything else has already failed.
            let memory = ModelConfiguration(
                schema: Schema(localTypes + chatTypes),
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            return try? ModelContainer(for: Schema(localTypes + chatTypes), configurations: memory)
        }
    }

    /// Why the split container failed, if it did — surfaced in Settings so a
    /// silent fallback isn't invisible.
    nonisolated(unsafe) private(set) static var splitFailure: String?

    /// The pre-split arrangement: one default store holding everything, no
    /// CloudKit. Exactly what every build before this one used.
    static func makeLegacyContainer() throws -> ModelContainer {
        activeSyncSetting = false
        // ⚠️ `cloudKitDatabase: .none` IS LOAD-BEARING. Omit the configuration
        // and SwiftData defaults to `.automatic`, which turns CloudKit ON
        // whenever the app carries an iCloud entitlement — so the fallback
        // failed with exactly the CloudKit error it was meant to escape, and
        // the "safe" path was as broken as the one it replaced.
        let config = ModelConfiguration(
            schema: Schema(localTypes + chatTypes),
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: Schema(localTypes + chatTypes), configurations: config)
    }

    private static func makeSplitContainer() throws -> ModelContainer {
        activeSyncSetting = syncEnabled
        // ⚠️ THE LEGACY STORE IS READ BEFORE ANYTHING ELSE OPENS. Once the new
        // configurations exist, the old file is nobody's business — and if a
        // narrower schema were pointed at it, SwiftData would migrate the file
        // and drop the tables this migration exists to read.
        let carried = ChatMigration.readLegacyIfNeeded()

        let local = ModelConfiguration(
            localStoreName,
            schema: Schema(localTypes),
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        // ⚠️ THE STORE IS THE SAME FILE EITHER WAY — only whether CloudKit is
        // attached to it changes. That is what makes the toggle safe: turning
        // sync on doesn't move anyone's chat anywhere, it just starts
        // replicating the store that already exists, and turning it off stops
        // replicating without touching a byte on disk.
        let chat = ModelConfiguration(
            chatStoreName,
            schema: Schema(chatTypes),
            isStoredInMemoryOnly: false,
            cloudKitDatabase: syncEnabled ? .private(cloudContainerID) : .none
        )

        let container = try ModelContainer(
            for: Schema(localTypes + chatTypes),
            configurations: local, chat
        )

        if let carried {
            ChatMigration.write(carried, into: container)
        }
        return container
    }
}

/// One-time carry-over of chat history from the pre-split store.
///
/// ⚠️ COPIES, NEVER MOVES. The legacy file is left byte-for-byte intact and is
/// simply never opened again — so a migration that half-runs, duplicates, or
/// hits a CloudKit error costs nothing that can't be recovered by hand. Deleting
/// the source to keep things tidy would turn every bug in this file into
/// permanent loss of a user's chat history, which is not a trade worth making
/// for a few megabytes.
enum ChatMigration {

    private static let doneKey = "chat_migrated_to_cloud_store_v1"

    /// Plain values, so the snapshot outlives the container it came from.
    /// `PersistentModel` instances are bound to their context and go stale the
    /// moment it is torn down.
    struct Snapshot {
        struct Message {
            var role: String, content: String, timestamp: Date
            var tokenCount: Int, model: String, routedVia: String, sourceNode: String
            var tokensPerSecond: Double, durationMs: Int, isError: Bool
        }
        struct Session {
            var title: String, createdAt: Date, updatedAt: Date, model: String
            var messages: [Message]
        }
        var sessions: [Session]
    }

    /// True once the carry-over has run, so it never repeats and never
    /// duplicates a user's history.
    static var hasMigrated: Bool {
        UserDefaults.standard.bool(forKey: doneKey)
    }

    /// Read chat out of the legacy store, if there is one and we haven't yet.
    static func readLegacyIfNeeded() -> Snapshot? {
        guard !hasMigrated else { return nil }

        // Nothing to carry on a fresh install — the common case, and it must
        // not leave a store file behind just by looking.
        guard legacyStoreExists() else {
            UserDefaults.standard.set(true, forKey: doneKey)
            return nil
        }

        do {
            // ⚠️ OPENED WITH THE *ORIGINAL* SCHEMA, ALL FOUR TYPES. Passing the
            // new narrower schema would make SwiftData treat this as a model
            // change and migrate the file — dropping the chat tables before
            // they could be read. Matching the original schema means no
            // migration happens at all. `allowsSave: false` is the second belt.
            let legacySchema = Schema(AppDatabase.localTypes + AppDatabase.chatTypes)
            // No name → the default store, which is the one the app has been
            // using all along.
            let config = ModelConfiguration(
                schema: legacySchema,
                isStoredInMemoryOnly: false,
                allowsSave: false,
                cloudKitDatabase: .none
            )
            let legacy = try ModelContainer(for: legacySchema, configurations: config)
            let context = ModelContext(legacy)

            let sessions = try context.fetch(FetchDescriptor<ChatSession>())
            let snapshot = Snapshot(sessions: sessions.map { s in
                Snapshot.Session(
                    title: s.title, createdAt: s.createdAt, updatedAt: s.updatedAt,
                    model: s.model,
                    messages: (s.messages ?? [])
                        .sorted { $0.timestamp < $1.timestamp }
                        .map { m in
                            Snapshot.Message(
                                role: m.role, content: m.content, timestamp: m.timestamp,
                                tokenCount: m.tokenCount, model: m.model,
                                routedVia: m.routedVia, sourceNode: m.sourceNode,
                                tokensPerSecond: m.tokensPerSecond, durationMs: m.durationMs,
                                isError: m.isError
                            )
                        }
                )
            })
            LogBroadcaster.shared.info(
                "mycellm.storage",
                "Chat migration: read \(snapshot.sessions.count) sessions from the legacy store")
            return snapshot
        } catch {
            // A failed read leaves the flag unset, so it retries next launch
            // rather than silently abandoning the user's history.
            LogBroadcaster.shared.error(
                "mycellm.storage", "Chat migration: could not read legacy store — \(error)")
            return nil
        }
    }

    /// Insert the snapshot into the synced store and mark the job done.
    static func write(_ snapshot: Snapshot, into container: ModelContainer) {
        let context = ModelContext(container)
        do {
            // Guard against a partially-completed previous run: if the target
            // already holds sessions, don't stack another copy on top.
            let existing = try context.fetchCount(FetchDescriptor<ChatSession>())
            guard existing == 0 else {
                LogBroadcaster.shared.info(
                    "mycellm.storage",
                    "Chat migration: target already holds \(existing) sessions — skipping")
                UserDefaults.standard.set(true, forKey: doneKey)
                return
            }

            for s in snapshot.sessions {
                let session = ChatSession()
                session.title = s.title
                session.createdAt = s.createdAt
                session.updatedAt = s.updatedAt
                session.model = s.model
                context.insert(session)

                for m in s.messages {
                    let message = ChatMessage(
                        role: m.role, content: m.content,
                        model: m.model, routedVia: m.routedVia
                    )
                    // The initializer stamps `timestamp` with now; carried
                    // messages must keep their original ordering, so it is
                    // overwritten rather than left as the migration's clock.
                    message.timestamp = m.timestamp
                    message.tokenCount = m.tokenCount
                    message.sourceNode = m.sourceNode
                    message.tokensPerSecond = m.tokensPerSecond
                    message.durationMs = m.durationMs
                    message.isError = m.isError
                    message.session = session
                    context.insert(message)
                }
            }
            try context.save()
            UserDefaults.standard.set(true, forKey: doneKey)
            LogBroadcaster.shared.info(
                "mycellm.storage",
                "Chat migration: carried \(snapshot.sessions.count) sessions into the synced store")
        } catch {
            LogBroadcaster.shared.error(
                "mycellm.storage", "Chat migration: write failed — \(error). Legacy store is untouched.")
        }
    }

    /// Does a pre-split store file exist? SwiftData names it after the
    /// configuration and puts it in Application Support.
    static func legacyStoreExists() -> Bool {
        guard let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
        return FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(AppDatabase.legacyStoreFilename).path)
    }
}
