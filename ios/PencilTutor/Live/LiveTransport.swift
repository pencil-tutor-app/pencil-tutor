import Foundation

/// A failure to set up or keep a live voice connection. `reason` is a short label for the session log and for the
/// fallback decision (never a provider message, never a key).
struct LiveFailure: Error, Equatable {
    let reason: String
}

/// The audio and data connection to a GPT-Live session. The only real implementation is `LiveWebRTCTransport`;
/// tests use a fake. This is the single owner of the microphone and speaker while a live session exists: when it is
/// closed, `SpeechOutput` and `AudioRecorder` may use the audio session again.
@MainActor
protocol LiveTransport: AnyObject {
    /// A JSON text message arrived on the data channel.
    var onMessage: ((String) -> Void)? { get set }
    /// The connection died or was closed. The argument is a short reason label.
    var onClosed: ((String) -> Void)? { get set }

    /// Creates the peer connection, the microphone track and the data channel, and returns the SDP offer once ICE gathering
    /// has finished (OpenAI's session endpoint takes a complete offer; there is no trickle).
    func prepareOffer() async throws -> String
    func applyAnswer(_ sdp: String) async throws
    /// Sends one JSON text message on the data channel. False if the channel is not open.
    func send(_ text: String) -> Bool
    /// Enables or disables the local microphone track (a disabled track sends silence).
    func setMicEnabled(_ enabled: Bool)
    /// Tears the connection down and gives the audio session back. Safe to call more than once. Returns after the
    /// teardown has settled, so the next audio user does not fight it.
    func close() async
}
