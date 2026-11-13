import AVFoundation
import Foundation
import WebRTC

/// The real connection to GPT-Live: one WebRTC peer with a microphone track going out, the tutor's voice coming in on the
/// audio track, and the data channel "oai-events" carrying JSON events both ways. This is the maintained Google WebRTC
/// build (`stasel/WebRTC`) because OpenAI ships no Swift SDK for Live.
///
/// Sequence, from OpenAI's WebRTC guide (guides/voice-webrtc?api=live): add the microphone track, create the data channel
/// BEFORE the offer, set the local description, wait for ICE gathering to finish, hand the offer to our server, apply the
/// answer it returns. Do not send `session.start` on the channel.
///
/// While this object is alive it owns the microphone and the speaker. `close()` gives the audio session back.
@MainActor
final class LiveWebRTCTransport: NSObject, LiveTransport {
    var onMessage: ((String) -> Void)?
    var onClosed: ((String) -> Void)?

    static let dataChannelLabel = "oai-events"
    private static let gatheringTimeout: TimeInterval = 10
    /// How long a "disconnected" peer gets to recover on its own before it counts as lost.
    private static let disconnectGrace: TimeInterval = 6
    /// Time for the audio unit to stop after the peer closes, so the next audio user does not fight it for the session.
    private static let teardownSettle: UInt64 = 300_000_000

    private var factory: RTCPeerConnectionFactory?
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var micTrack: RTCAudioTrack?
    private var tornDown = false
    private var disconnectTimer: Task<Void, Never>?

    // MARK: - LiveTransport

    func prepareOffer() async throws -> String {
        configureAudioSession()
        let factory = RTCPeerConnectionFactory()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherOnce
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw LiveFailure(reason: "peer_connection_unavailable")
        }
        self.factory = factory
        self.peer = peer

        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "student-mic")
        guard peer.add(track, streamIds: ["student"]) != nil else {
            throw LiveFailure(reason: "microphone_track_not_added")
        }
        micTrack = track

        let channelConfiguration = RTCDataChannelConfiguration()
        guard let channel = peer.dataChannel(forLabel: Self.dataChannelLabel, configuration: channelConfiguration) else {
            throw LiveFailure(reason: "data_channel_not_created")
        }
        channel.delegate = self
        self.channel = channel

        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: constraints) { description, error in
                if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: LiveFailure(reason: "create_offer_failed"))
                }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(offer) { error in
                if error != nil {
                    continuation.resume(throwing: LiveFailure(reason: "set_local_description_failed"))
                } else {
                    continuation.resume()
                }
            }
        }

        // No trickle: OpenAI's session endpoint wants the finished offer, candidates included.
        let deadline = Date().addingTimeInterval(Self.gatheringTimeout)
        while peer.iceGatheringState != .complete {
            if Date() >= deadline { throw LiveFailure(reason: "ice_gathering_timeout") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let sdp = peer.localDescription?.sdp, !sdp.isEmpty else {
            throw LiveFailure(reason: "empty_local_description")
        }
        return sdp
    }

    func applyAnswer(_ sdp: String) async throws {
        guard let peer else { throw LiveFailure(reason: "no_peer_connection") }
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(answer) { error in
                if error != nil {
                    continuation.resume(throwing: LiveFailure(reason: "set_remote_description_failed"))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func send(_ text: String) -> Bool {
        guard let channel, channel.readyState == .open else { return false }
        return channel.sendData(RTCDataBuffer(data: Data(text.utf8), isBinary: false))
    }

    func setMicEnabled(_ enabled: Bool) {
        micTrack?.isEnabled = enabled
    }

    func close() async {
        guard !tornDown else { return }
        tornDown = true
        disconnectTimer?.cancel()
        let hadPeer = peer != nil
        micTrack?.isEnabled = false
        channel?.delegate = nil
        channel?.close()
        peer?.delegate = nil
        peer?.close()
        channel = nil
        micTrack = nil
        peer = nil
        factory = nil
        if hadPeer { try? await Task.sleep(nanoseconds: Self.teardownSettle) }
    }

    // MARK: - Audio

    /// Echo cancellation matters: the tutor's voice comes out of the iPad speaker next to its own microphone.
    /// `voiceChat` mode turns on the hardware echo canceller; `defaultToSpeaker` keeps the voice on the loudspeaker.
    private func configureAudioSession() {
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
        configuration.categoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
        RTCAudioSessionConfiguration.setWebRTC(configuration)
    }

    // MARK: - Reporting a lost connection

    private func reportClosed(_ reason: String) {
        guard !tornDown else { return }
        disconnectTimer?.cancel()
        onClosed?(reason)
    }
}

// MARK: - WebRTC callbacks (arrive on WebRTC's own threads; hop to the main actor in order)

extension LiveWebRTCTransport: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.peerStateChanged(newState) }
        }
    }
}

extension LiveWebRTCTransport {
    fileprivate func peerStateChanged(_ state: RTCPeerConnectionState) {
        switch state {
        case .failed:
            reportClosed("peer_failed")
        case .closed:
            reportClosed("peer_closed")
        case .disconnected:
            // Wi-Fi blips recover by themselves; only a peer that stays disconnected counts as lost.
            disconnectTimer?.cancel()
            disconnectTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.disconnectGrace * 1_000_000_000))
                guard !Task.isCancelled, let self, self.peer?.connectionState == .disconnected else { return }
                self.reportClosed("peer_disconnected_\(Int(Self.disconnectGrace))s")
            }
        case .connected:
            disconnectTimer?.cancel()
        default:
            break
        }
    }
}

extension LiveWebRTCTransport: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .closed else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.reportClosed("data_channel_closed") }
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary, let text = String(data: buffer.data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onMessage?(text) }
        }
    }
}
