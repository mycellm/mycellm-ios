import Foundation

/// All protocol message types. Wire-compatible with Python `MessageType(str, Enum)`.
enum MessageType: String, Sendable, CaseIterable {
    // Handshake
    case nodeHello = "node_hello"
    case nodeHelloAck = "node_hello_ack"

    // Discovery
    case peerAnnounce = "peer_announce"
    case peerQuery = "peer_query"
    case peerResponse = "peer_response"

    // Inference
    case inferenceReq = "inference_req"
    case inferenceResp = "inference_resp"
    case inferenceStream = "inference_stream"
    case inferenceDone = "inference_done"

    // Health
    case ping = "ping"
    case pong = "pong"

    // Accounting
    case creditReceipt = "credit_receipt"

    // Multi-hop
    case inferenceRelay = "inference_relay"

    // Peer exchange
    case peerExchange = "peer_exchange"

    // Fleet management
    case fleetCommand = "fleet_command"
    case fleetResponse = "fleet_response"

    // NAT traversal (hole punching)
    case punchRequest = "punch_request"
    case punchInitiate = "punch_initiate"
    case punchResponse = "punch_response"
    case punchResult = "punch_result"

    // DHT gateway
    case dhtQuery = "dht_query"
    case dhtResponse = "dht_response"

    // Error
    case error = "error"
}
