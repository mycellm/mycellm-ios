import Foundation

/// Typed constructors for all protocol messages.
/// Wire-compatible with Python `mycellm.transport.messages`.
enum MessageBuilders {

    static func ping(from peer: String) -> MessageEnvelope {
        MessageEnvelope(type: .ping, payload: [:], fromPeer: peer)
    }

    static func pong(from peer: String, requestId: String) -> MessageEnvelope {
        MessageEnvelope(type: .pong, payload: [:], fromPeer: peer, id: requestId)
    }

    static func inferenceRequest(
        from peer: String,
        model: String,
        messages: [[String: String]],
        temperature: Double = 0.7,
        maxTokens: Int = 2048,
        stream: Bool = false
    ) -> MessageEnvelope {
        let chatMessages: [CBORValue] = messages.map { msg in
            .map(msg.mapValues { .string($0) })
        }
        return MessageEnvelope(
            type: .inferenceReq,
            payload: [
                "model": .string(model),
                "messages": .array(chatMessages),
                "temperature": .double(temperature),
                "max_tokens": .int(Int64(maxTokens)),
                "stream": .bool(stream),
            ],
            fromPeer: peer
        )
    }

    static func inferenceResponse(
        from peer: String,
        requestId: String,
        text: String,
        model: String = "",
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        finishReason: String = "stop"
    ) -> MessageEnvelope {
        MessageEnvelope(
            type: .inferenceResp,
            payload: [
                "text": .string(text),
                "model": .string(model),
                "prompt_tokens": .int(Int64(promptTokens)),
                "completion_tokens": .int(Int64(completionTokens)),
                "finish_reason": .string(finishReason),
            ],
            fromPeer: peer,
            id: requestId
        )
    }

    static func inferenceStreamChunk(
        from peer: String,
        requestId: String,
        text: String,
        finishReason: String? = nil
    ) -> MessageEnvelope {
        var payload: [String: CBORValue] = ["text": .string(text)]
        if let reason = finishReason {
            payload["finish_reason"] = .string(reason)
        } else {
            payload["finish_reason"] = .null
        }
        return MessageEnvelope(type: .inferenceStream, payload: payload, fromPeer: peer, id: requestId)
    }

    static func inferenceDone(from peer: String, requestId: String) -> MessageEnvelope {
        MessageEnvelope(type: .inferenceDone, payload: [:], fromPeer: peer, id: requestId)
    }

    static func error(
        from peer: String,
        requestId: String,
        code: ErrorCode,
        message: String = ""
    ) -> MessageEnvelope {
        MessageEnvelope(
            type: .error,
            payload: [
                "error_code": .string(code.rawValue),
                "error_message": .string(message.isEmpty ? code.rawValue : message),
            ],
            fromPeer: peer,
            id: requestId
        )
    }

    static func creditReceipt(
        from peer: String,
        counterparty: String,
        amount: Double,
        reason: String,
        signature: String = ""
    ) -> MessageEnvelope {
        MessageEnvelope(
            type: .creditReceipt,
            payload: [
                "counterparty": .string(counterparty),
                "amount": .double(amount),
                "reason": .string(reason),
                "signature": .string(signature),
            ],
            fromPeer: peer
        )
    }

    static func signedCreditReceipt(
        from peer: String,
        consumerId: String,
        seederId: String,
        model: String,
        tokens: Int,
        cost: Double,
        timestamp: Double,
        signature: String
    ) -> MessageEnvelope {
        MessageEnvelope(
            type: .creditReceipt,
            payload: [
                "consumer_id": .string(consumerId),
                "seeder_id": .string(seederId),
                "model": .string(model),
                "tokens": .int(Int64(tokens)),
                "cost": .double(cost),
                "timestamp": .double(timestamp),
                "signature": .string(signature),
            ],
            fromPeer: peer
        )
    }

    static func peerAnnounce(
        from peer: String,
        addresses: [String],
        capabilities: [String: CBORValue]
    ) -> MessageEnvelope {
        MessageEnvelope(
            type: .peerAnnounce,
            payload: [
                "addresses": .array(addresses.map { .string($0) }),
                "capabilities": .map(capabilities),
            ],
            fromPeer: peer
        )
    }

    static func peerQuery(from peer: String, model: String = "") -> MessageEnvelope {
        MessageEnvelope(type: .peerQuery, payload: ["model": .string(model)], fromPeer: peer)
    }

    static func peerResponse(
        from peer: String,
        requestId: String,
        peers: [[String: CBORValue]]
    ) -> MessageEnvelope {
        MessageEnvelope(
            type: .peerResponse,
            payload: ["peers": .array(peers.map { .map($0) })],
            fromPeer: peer,
            id: requestId
        )
    }

    static func peerExchange(from peer: String, knownPeers: [[String: CBORValue]]) -> MessageEnvelope {
        MessageEnvelope(
            type: .peerExchange,
            payload: ["peers": .array(knownPeers.map { .map($0) })],
            fromPeer: peer
        )
    }

    static func inferenceRelay(
        from peer: String,
        targetPeer: String,
        model: String,
        messages: [[String: String]],
        via: [String] = [],
        temperature: Double = 0.7,
        maxTokens: Int = 2048,
        stream: Bool = false
    ) -> MessageEnvelope {
        let chatMessages: [CBORValue] = messages.map { msg in
            .map(msg.mapValues { .string($0) })
        }
        return MessageEnvelope(
            type: .inferenceRelay,
            payload: [
                "target_peer": .string(targetPeer),
                "model": .string(model),
                "messages": .array(chatMessages),
                "via": .array(via.map { .string($0) }),
                "temperature": .double(temperature),
                "max_tokens": .int(Int64(maxTokens)),
                "stream": .bool(stream),
            ],
            fromPeer: peer
        )
    }

    static func fleetCommand(
        from peer: String,
        command: String,
        params: [String: CBORValue] = [:],
        fleetAdminKey: String = ""
    ) -> MessageEnvelope {
        MessageEnvelope(
            type: .fleetCommand,
            payload: [
                "command": .string(command),
                "params": .map(params),
                "fleet_admin_key": .string(fleetAdminKey),
            ],
            fromPeer: peer
        )
    }

    static func fleetResponse(
        from peer: String,
        requestId: String,
        success: Bool,
        data: [String: CBORValue] = [:],
        error: String = ""
    ) -> MessageEnvelope {
        MessageEnvelope(
            type: .fleetResponse,
            payload: [
                "success": .bool(success),
                "data": .map(data),
                "error": .string(error),
            ],
            fromPeer: peer,
            id: requestId
        )
    }
}
