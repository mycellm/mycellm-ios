import Foundation

/// Whether a model is an embedding model, decided from its name.
///
/// ⚠️ THE NAME IS ALL WE HAVE HERE, AND PYTHON KNOWS MORE. On the Python side
/// `derive_capability_tags` prefers the *backend type*: anything loaded into
/// `MLXEmbeddingsBackend` is an embedding model regardless of its name, because
/// that backend cannot generate. iOS has one GGUF backend that does both, so
/// there is no backend signal to consult and the name heuristic is the whole
/// decision.
///
/// ⚠️ AND THE BARE "embed" SUBSTRING IS NOT ENOUGH. Python's `derive_tags`
/// only looks for "embed"/"embedding", which catches `nomic-embed-text` and
/// `text-embedding-3` but misses every model actually shipped as GGUF for this
/// job — `all-MiniLM-L6-v2`, `bge-small-en`, `gte-base`, `multilingual-e5-large`
/// have no such substring. Python gets away with it because its embedding
/// models arrive through `mlx-embeddings`; a GGUF MiniLM would be mistagged
/// "chat" there too. The family list below closes that hole, and the same list
/// was added to `derive_tags` in the Python core so the two agree — a model
/// must not be an embedding model on one node and a chat model on another.
enum EmbeddingModels {

    /// Lowercased substrings that identify an embedding model. Kept in sync
    /// with `_EMBEDDING_FAMILIES` in `src/mycellm/router/model_resolver.py`.
    static let families: [String] = [
        "embed",       // nomic-embed, arctic-embed, jina-embeddings, text-embedding
        "minilm",
        "bge-",
        "gte-",
        "e5-",         // multilingual-e5, intfloat e5
        "mxbai",
        "mpnet",
        "sentence-t5",
        "paraphrase-",
        "stella-",
    ]

    /// True when `name` looks like an embedding model.
    ///
    /// Matched against the basename with any file extension removed, so a path
    /// or a `…-Q4_K_M.gguf` filename classifies the same as a bare model name.
    static func isEmbeddingModel(_ name: String) -> Bool {
        let base = (name as NSString).lastPathComponent.lowercased()
        let stem = base.hasSuffix(".gguf") ? String(base.dropLast(5)) : base
        return families.contains { stem.contains($0) }
    }

    /// Capability tags for a model name, mirroring Python's `derive_tags`.
    /// "embedding" is an override, not an addition — an embedding model is not
    /// also a chat model, and listing both would let auto-routing pick it for a
    /// chat request.
    static func tags(for name: String) -> [String] {
        if isEmbeddingModel(name) { return ["embedding"] }

        var tags = ["chat"]
        let lower = name.lowercased()
        if ["code", "coder", "starcoder", "codellama"].contains(where: lower.contains) {
            tags.append("code")
        }
        if ["reason", "think", "r1", "qwq", "o1", "o3"].contains(where: lower.contains) {
            tags.append("reasoning")
        }
        if ["vision", "vl", "llava", "pixtral"].contains(where: lower.contains) {
            tags.append("vision")
        }
        return tags
    }
}
