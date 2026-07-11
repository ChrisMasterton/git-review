import Foundation

public struct OpenRouterCommitRequest: Encodable, Sendable {
    private struct Message: Encodable, Sendable {
        let role: String
        let content: String
    }

    private struct Reasoning: Encodable, Sendable {
        let effort: String
        let exclude: Bool
    }

    private let model: String
    private let messages: [Message]
    private let temperature: Double
    private let maxCompletionTokens: Int
    private let reasoning: Reasoning
    private let stream: Bool

    private enum CodingKeys: String, CodingKey {
        case model, messages, temperature, reasoning, stream
        case maxCompletionTokens = "max_completion_tokens"
    }

    public init(model: String, prompt: String) {
        self.model = model
        messages = [Message(role: "user", content: prompt)]
        temperature = 0.2
        maxCompletionTokens = 800
        reasoning = Reasoning(effort: "minimal", exclude: true)
        stream = false
    }
}

public struct OpenRouterCommitCompletion: Equatable, Sendable {
    public let message: String
    public let model: String
}

public enum OpenRouterCommitResponseError: LocalizedError, Equatable, Sendable {
    case outputTruncated
    case missingMessage
    case service(String)

    public var errorDescription: String? {
        switch self {
        case .outputTruncated:
            return "OpenRouter reached its output limit before finishing the commit message. Generate the message again."
        case .missingMessage:
            return "OpenRouter returned no commit message."
        case let .service(message):
            return message
        }
    }
}

public struct OpenRouterCommitResponse: Decodable, Sendable {
    private struct Choice: Decodable, Sendable {
        struct Message: Decodable, Sendable {
            let content: String?
        }

        let message: Message
        let finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    private struct APIError: Decodable, Sendable {
        let message: String?
    }

    private let model: String?
    private let choices: [Choice]?
    private let error: APIError?

    public var apiErrorMessage: String? { error?.message }

    public func completion(fallbackModel: String) throws -> OpenRouterCommitCompletion {
        if let message = error?.message {
            throw OpenRouterCommitResponseError.service(message)
        }
        guard let choice = choices?.first else {
            throw OpenRouterCommitResponseError.missingMessage
        }
        guard choice.finishReason != "length" else {
            throw OpenRouterCommitResponseError.outputTruncated
        }
        guard let message = choice.message.content else {
            throw OpenRouterCommitResponseError.missingMessage
        }
        return OpenRouterCommitCompletion(message: message, model: model ?? fallbackModel)
    }
}
