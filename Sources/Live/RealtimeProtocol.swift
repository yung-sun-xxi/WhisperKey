import Foundation

// OpenAI Realtime API, GA interface, over a WebSocket. Every name below was checked against
// the live docs on 2026-10-05:
//
// Connection — https://developers.openai.com/api/docs/guides/realtime-websocket
//   wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1, header `Authorization: Bearer <key>`.
//   No `OpenAI-Beta` header: it selects the beta interface (https://developers.openai.com/api/docs/guides/realtime,
//   "Beta to GA migration").
//
// Client events — https://developers.openai.com/api/reference/resources/realtime/client-events
//   session.update { session: { type: "realtime", instructions, output_modalities: ["audio"],
//     audio: { input: { format: { type: "audio/pcm", rate: 24000 }, transcription: { model },
//                       turn_detection: { type: "semantic_vad", create_response, interrupt_response } },
//              output: { format: { type: "audio/pcm", rate: 24000 }, voice } } } }
//   input_audio_buffer.append { audio }           (base64)
//   response.create                               (no fields needed)
//   response.cancel { response_id? }
//   conversation.item.create { item: { type: "function_call_output", call_id, output } }
//
// Server events — https://developers.openai.com/api/reference/resources/realtime/server-events
//   session.created / session.updated { session: { id } }
//   input_audio_buffer.speech_started { item_id, audio_start_ms }
//   input_audio_buffer.speech_stopped { item_id, audio_end_ms }
//   response.created { response: { id } }
//   response.output_audio.delta { response_id, item_id, delta }   (beta name was response.audio.delta)
//   response.output_audio.done { response_id, item_id }
//   response.done { response: { id, status, usage: { total_tokens, input_tokens, output_tokens,
//     input_token_details: { text_tokens, audio_tokens, image_tokens, cached_tokens,
//       cached_tokens_details: { text_tokens, audio_tokens, image_tokens } },
//     output_token_details: { text_tokens, audio_tokens } } } }
//   response.function_call_arguments.done { response_id, item_id, call_id, name, arguments }
//   conversation.item.input_audio_transcription.completed { item_id, transcript,
//     usage: { type: "tokens", input_tokens, output_tokens, total_tokens, input_token_details: { audio_tokens } }
//          | { type: "duration", seconds } }
//   error { error: { type, code, message, param, event_id } }
//
// Models — gpt-realtime-2.1 is the model in the GA WebSocket and conversation guides; the
// transcription model list (client events, audio.input.transcription.model) includes
// gpt-4o-mini-transcribe, which the prototype ran without trouble.

// MARK: - Session configuration

public struct RealtimeSessionConfig: Equatable, Sendable {
    public static let defaultModel = "gpt-realtime-2.1"
    public static let defaultVoice = "ash"
    public static let defaultTranscriptionModel = "gpt-4o-mini-transcribe"

    /// Goes into the connection URL (`RealtimeTransport.makeRequest`), not into session.update.
    public var model: String
    public var instructions: String
    public var voice: String
    public var transcriptionModel: String

    public init(
        model: String = RealtimeSessionConfig.defaultModel,
        instructions: String,
        voice: String = RealtimeSessionConfig.defaultVoice,
        transcriptionModel: String = RealtimeSessionConfig.defaultTranscriptionModel
    ) {
        self.model = model
        self.instructions = instructions
        self.voice = voice
        self.transcriptionModel = transcriptionModel
    }
}

// MARK: - Client events

public enum RealtimeClientEvent: Equatable, Sendable, Encodable {
    case sessionUpdate(RealtimeSessionConfig)
    /// Raw PCM16 24 kHz mono bytes; base64-encoded on the wire.
    case inputAudioAppend(Data)
    case responseCreate
    case responseCancel(responseID: String?)
    case functionCallOutput(callID: String, output: String)

    public var type: String {
        switch self {
        case .sessionUpdate: return "session.update"
        case .inputAudioAppend: return "input_audio_buffer.append"
        case .responseCreate: return "response.create"
        case .responseCancel: return "response.cancel"
        case .functionCallOutput: return "conversation.item.create"
        }
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func jsonString() throws -> String {
        String(decoding: try jsonData(), as: UTF8.self)
    }

    private enum Key: String, CodingKey {
        case type, session, audio, response_id, item
        case model, instructions, output_modalities, input, output, format, rate, transcription
        case turn_detection, create_response, interrupt_response, voice, call_id
    }

    public func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: Key.self)
        try root.encode(type, forKey: .type)
        switch self {
        case .sessionUpdate(let config):
            var session = root.nestedContainer(keyedBy: Key.self, forKey: .session)
            try session.encode("realtime", forKey: .type)
            // No `model`: the URL's `?model=` chooses it, and the reference says `model` cannot
            // be changed by session.update.
            try session.encode(config.instructions, forKey: .instructions)
            try session.encode(["audio"], forKey: .output_modalities)
            var audio = session.nestedContainer(keyedBy: Key.self, forKey: .audio)

            var input = audio.nestedContainer(keyedBy: Key.self, forKey: .input)
            try Self.encodePCMFormat(into: &input)
            // No transcription prompt: on noise the transcriber returned the prompt itself as
            // the user's words (prototype journal, 2026-10-02).
            var transcription = input.nestedContainer(keyedBy: Key.self, forKey: .transcription)
            try transcription.encode(config.transcriptionModel, forKey: .model)
            var turn = input.nestedContainer(keyedBy: Key.self, forKey: .turn_detection)
            try turn.encode("semantic_vad", forKey: .type)
            try turn.encode(true, forKey: .create_response)
            try turn.encode(true, forKey: .interrupt_response)

            var output = audio.nestedContainer(keyedBy: Key.self, forKey: .output)
            try Self.encodePCMFormat(into: &output)
            try output.encode(config.voice, forKey: .voice)

        case .inputAudioAppend(let data):
            try root.encode(LivePCM.base64(data), forKey: .audio)

        case .responseCreate:
            break

        case .responseCancel(let responseID):
            try root.encodeIfPresent(responseID, forKey: .response_id)

        case .functionCallOutput(let callID, let output):
            var item = root.nestedContainer(keyedBy: Key.self, forKey: .item)
            try item.encode("function_call_output", forKey: .type)
            try item.encode(callID, forKey: .call_id)
            try item.encode(output, forKey: .output)
        }
    }

    private static func encodePCMFormat(into container: inout KeyedEncodingContainer<Key>) throws {
        var format = container.nestedContainer(keyedBy: Key.self, forKey: .format)
        try format.encode("audio/pcm", forKey: .type)
        try format.encode(LivePCM.sampleRate, forKey: .rate)
    }
}

// MARK: - Server event payloads

public struct RealtimeUsage: Equatable, Sendable, Decodable {
    public struct InputTokenDetails: Equatable, Sendable, Decodable {
        public struct CachedTokenDetails: Equatable, Sendable, Decodable {
            public var textTokens: Int
            public var audioTokens: Int
            public var imageTokens: Int

            public init(textTokens: Int = 0, audioTokens: Int = 0, imageTokens: Int = 0) {
                self.textTokens = textTokens
                self.audioTokens = audioTokens
                self.imageTokens = imageTokens
            }

            private enum CodingKeys: String, CodingKey {
                case textTokens = "text_tokens", audioTokens = "audio_tokens", imageTokens = "image_tokens"
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                textTokens = try c.decodeIfPresent(Int.self, forKey: .textTokens) ?? 0
                audioTokens = try c.decodeIfPresent(Int.self, forKey: .audioTokens) ?? 0
                imageTokens = try c.decodeIfPresent(Int.self, forKey: .imageTokens) ?? 0
            }
        }

        public var textTokens: Int
        public var audioTokens: Int
        public var imageTokens: Int
        public var cachedTokens: Int
        public var cachedTokensDetails: CachedTokenDetails?

        public init(
            textTokens: Int = 0,
            audioTokens: Int = 0,
            imageTokens: Int = 0,
            cachedTokens: Int = 0,
            cachedTokensDetails: CachedTokenDetails? = nil
        ) {
            self.textTokens = textTokens
            self.audioTokens = audioTokens
            self.imageTokens = imageTokens
            self.cachedTokens = cachedTokens
            self.cachedTokensDetails = cachedTokensDetails
        }

        private enum CodingKeys: String, CodingKey {
            case textTokens = "text_tokens", audioTokens = "audio_tokens", imageTokens = "image_tokens"
            case cachedTokens = "cached_tokens", cachedTokensDetails = "cached_tokens_details"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            textTokens = try c.decodeIfPresent(Int.self, forKey: .textTokens) ?? 0
            audioTokens = try c.decodeIfPresent(Int.self, forKey: .audioTokens) ?? 0
            imageTokens = try c.decodeIfPresent(Int.self, forKey: .imageTokens) ?? 0
            cachedTokens = try c.decodeIfPresent(Int.self, forKey: .cachedTokens) ?? 0
            cachedTokensDetails = try c.decodeIfPresent(CachedTokenDetails.self, forKey: .cachedTokensDetails)
        }
    }

    public struct OutputTokenDetails: Equatable, Sendable, Decodable {
        public var textTokens: Int
        public var audioTokens: Int

        public init(textTokens: Int = 0, audioTokens: Int = 0) {
            self.textTokens = textTokens
            self.audioTokens = audioTokens
        }

        private enum CodingKeys: String, CodingKey {
            case textTokens = "text_tokens", audioTokens = "audio_tokens"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            textTokens = try c.decodeIfPresent(Int.self, forKey: .textTokens) ?? 0
            audioTokens = try c.decodeIfPresent(Int.self, forKey: .audioTokens) ?? 0
        }
    }

    public var totalTokens: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var inputTokenDetails: InputTokenDetails?
    public var outputTokenDetails: OutputTokenDetails?

    public init(
        totalTokens: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        inputTokenDetails: InputTokenDetails? = nil,
        outputTokenDetails: OutputTokenDetails? = nil
    ) {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.inputTokenDetails = inputTokenDetails
        self.outputTokenDetails = outputTokenDetails
    }

    private enum CodingKeys: String, CodingKey {
        case totalTokens = "total_tokens", inputTokens = "input_tokens", outputTokens = "output_tokens"
        case inputTokenDetails = "input_token_details", outputTokenDetails = "output_token_details"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        inputTokenDetails = try c.decodeIfPresent(InputTokenDetails.self, forKey: .inputTokenDetails)
        outputTokenDetails = try c.decodeIfPresent(OutputTokenDetails.self, forKey: .outputTokenDetails)
    }
}

public struct RealtimeResponseDone: Equatable, Sendable {
    public var responseID: String
    /// `completed`, `cancelled`, `failed`, `incomplete` or `in_progress`.
    public var status: String?
    public var usage: RealtimeUsage?

    public init(responseID: String, status: String?, usage: RealtimeUsage?) {
        self.responseID = responseID
        self.status = status
        self.usage = usage
    }
}

public struct RealtimeFunctionCall: Equatable, Sendable {
    public var callID: String
    public var name: String
    /// The arguments as the model wrote them: a JSON string.
    public var arguments: String
    public var responseID: String?
    public var itemID: String?

    public init(callID: String, name: String, arguments: String, responseID: String?, itemID: String?) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.responseID = responseID
        self.itemID = itemID
    }
}

public enum RealtimeTranscriptionUsage: Equatable, Sendable {
    case tokens(inputTokens: Int, outputTokens: Int, totalTokens: Int, inputAudioTokens: Int)
    case duration(seconds: Double)
}

public struct RealtimeError: Equatable, Sendable, Error {
    public var type: String
    public var code: String?
    public var message: String
    public var param: String?
    /// The `event_id` of the client event that caused the error, when there is one.
    public var clientEventID: String?

    public init(type: String, code: String?, message: String, param: String?, clientEventID: String?) {
        self.type = type
        self.code = code
        self.message = message
        self.param = param
        self.clientEventID = clientEventID
    }

    /// The docs say most errors are recoverable and the session stays open, and publish no list
    /// of Realtime error codes. Fatal here: server errors, and the account-level codes of the
    /// general API (bad key, no quota) plus the session-age limit. Anything else — typically a
    /// rejected client command — leaves the session running.
    public var isFatal: Bool {
        if type == "server_error" { return true }
        guard let code else { return false }
        return Self.fatalCodes.contains(code)
    }

    static let fatalCodes: Set<String> = ["invalid_api_key", "insufficient_quota", "session_expired"]
}

// MARK: - Server events

public enum RealtimeServerEvent: Equatable, Sendable {
    case sessionCreated(sessionID: String?)
    case sessionUpdated(sessionID: String?)
    case speechStarted(itemID: String?, audioStartMs: Int?)
    case speechStopped(itemID: String?, audioEndMs: Int?)
    case responseCreated(responseID: String)
    case outputAudioDelta(responseID: String, itemID: String, audio: Data)
    case outputAudioDone(responseID: String, itemID: String)
    case responseDone(RealtimeResponseDone)
    case functionCallArgumentsDone(RealtimeFunctionCall)
    case inputTranscriptionCompleted(itemID: String, transcript: String, usage: RealtimeTranscriptionUsage?)
    case error(RealtimeError)
    /// Any event this client does not handle. Never a decoding failure.
    case unknown(type: String)

    public enum DecodingError: Error, Equatable {
        case notJSON
        case missingType
        case malformed(type: String, reason: String)
    }

    public static func decode(_ text: String) throws -> RealtimeServerEvent {
        try decode(Data(text.utf8))
    }

    public static func decode(_ data: Data) throws -> RealtimeServerEvent {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DecodingError.notJSON
        }
        guard let json = object as? [String: Any] else { throw DecodingError.notJSON }
        guard let type = json["type"] as? String else { throw DecodingError.missingType }
        guard let kind = Kind(rawValue: type) else { return .unknown(type: type) }
        do {
            return try kind.decode(data)
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.malformed(type: type, reason: String(describing: error))
        }
    }

    private enum Kind: String {
        case sessionCreated = "session.created"
        case sessionUpdated = "session.updated"
        case speechStarted = "input_audio_buffer.speech_started"
        case speechStopped = "input_audio_buffer.speech_stopped"
        case responseCreated = "response.created"
        case outputAudioDelta = "response.output_audio.delta"
        case outputAudioDone = "response.output_audio.done"
        case responseDone = "response.done"
        case functionCallArgumentsDone = "response.function_call_arguments.done"
        case inputTranscriptionCompleted = "conversation.item.input_audio_transcription.completed"
        case error = "error"

        func decode(_ data: Data) throws -> RealtimeServerEvent {
            let decoder = JSONDecoder()
            switch self {
            case .sessionCreated:
                return .sessionCreated(sessionID: try decoder.decode(SessionWire.self, from: data).session?.id)
            case .sessionUpdated:
                return .sessionUpdated(sessionID: try decoder.decode(SessionWire.self, from: data).session?.id)
            case .speechStarted:
                let wire = try decoder.decode(SpeechWire.self, from: data)
                return .speechStarted(itemID: wire.item_id, audioStartMs: wire.audio_start_ms)
            case .speechStopped:
                let wire = try decoder.decode(SpeechWire.self, from: data)
                return .speechStopped(itemID: wire.item_id, audioEndMs: wire.audio_end_ms)
            case .responseCreated:
                return .responseCreated(responseID: try decoder.decode(ResponseWire.self, from: data).response.id)
            case .outputAudioDelta:
                let wire = try decoder.decode(AudioDeltaWire.self, from: data)
                guard let audio = Data(base64Encoded: wire.delta) else {
                    throw DecodingError.malformed(type: rawValue, reason: "delta is not base64")
                }
                return .outputAudioDelta(responseID: wire.response_id, itemID: wire.item_id, audio: audio)
            case .outputAudioDone:
                let wire = try decoder.decode(AudioDoneWire.self, from: data)
                return .outputAudioDone(responseID: wire.response_id, itemID: wire.item_id)
            case .responseDone:
                let response = try decoder.decode(ResponseWire.self, from: data).response
                return .responseDone(RealtimeResponseDone(
                    responseID: response.id,
                    status: response.status,
                    usage: response.usage
                ))
            case .functionCallArgumentsDone:
                let wire = try decoder.decode(FunctionCallWire.self, from: data)
                return .functionCallArgumentsDone(RealtimeFunctionCall(
                    callID: wire.call_id,
                    name: wire.name,
                    arguments: wire.arguments,
                    responseID: wire.response_id,
                    itemID: wire.item_id
                ))
            case .inputTranscriptionCompleted:
                let wire = try decoder.decode(TranscriptionWire.self, from: data)
                return .inputTranscriptionCompleted(
                    itemID: wire.item_id,
                    transcript: wire.transcript,
                    usage: wire.usage?.value
                )
            case .error:
                let wire = try decoder.decode(ErrorWire.self, from: data).error
                return .error(RealtimeError(
                    type: wire.type,
                    code: wire.code,
                    message: wire.message,
                    param: wire.param,
                    clientEventID: wire.event_id
                ))
            }
        }
    }
}

// MARK: - Wire shapes (snake_case as on the wire)

private struct SessionWire: Decodable {
    struct Session: Decodable { let id: String? }
    let session: Session?
}

private struct SpeechWire: Decodable {
    let item_id: String?
    let audio_start_ms: Int?
    let audio_end_ms: Int?
}

private struct ResponseWire: Decodable {
    struct Response: Decodable {
        let id: String
        let status: String?
        let usage: RealtimeUsage?
    }
    let response: Response
}

private struct AudioDeltaWire: Decodable {
    let response_id: String
    let item_id: String
    let delta: String
}

private struct AudioDoneWire: Decodable {
    let response_id: String
    let item_id: String
}

private struct FunctionCallWire: Decodable {
    let call_id: String
    let name: String
    let arguments: String
    let response_id: String?
    let item_id: String?
}

private struct TranscriptionWire: Decodable {
    struct Usage: Decodable {
        struct InputDetails: Decodable { let audio_tokens: Int? }
        let type: String?
        let input_tokens: Int?
        let output_tokens: Int?
        let total_tokens: Int?
        let input_token_details: InputDetails?
        let seconds: Double?

        var value: RealtimeTranscriptionUsage? {
            if type == "duration" || (type == nil && seconds != nil) {
                return seconds.map { .duration(seconds: $0) }
            }
            return .tokens(
                inputTokens: input_tokens ?? 0,
                outputTokens: output_tokens ?? 0,
                totalTokens: total_tokens ?? 0,
                inputAudioTokens: input_token_details?.audio_tokens ?? 0
            )
        }
    }
    let item_id: String
    let transcript: String
    let usage: Usage?
}

private struct ErrorWire: Decodable {
    struct Body: Decodable {
        let type: String
        let code: String?
        let message: String
        let param: String?
        let event_id: String?
    }
    let error: Body
}
