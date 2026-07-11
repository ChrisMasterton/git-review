import Foundation
import GitReviewCore
import Testing

@Test func commitRequestReservesVisibleOutputWithoutStreaming() throws {
    let request = OpenRouterCommitRequest(model: "openrouter/auto", prompt: "Describe the changes")
    let data = try JSONEncoder().encode(request)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let reasoning = try #require(json["reasoning"] as? [String: Any])

    #expect(json["stream"] as? Bool == false)
    #expect(json["max_completion_tokens"] as? Int == 800)
    #expect(json["max_tokens"] == nil)
    #expect(reasoning["effort"] as? String == "minimal")
    #expect(reasoning["exclude"] as? Bool == true)
}

@Test func lengthLimitedCommitResponseIsRejected() throws {
    let data = Data(#"""
    {
        "model": "google/gemini-3.5-flash-20260519",
        "choices": [{
            "finish_reason": "length",
            "native_finish_reason": "MAX_TOKENS",
            "message": {"content": "Track the Camping Pack UR"}
        }]
    }
    """#.utf8)
    let response = try JSONDecoder().decode(OpenRouterCommitResponse.self, from: data)

    #expect(throws: OpenRouterCommitResponseError.outputTruncated) {
        try response.completion(fallbackModel: "openrouter/auto")
    }
}

@Test func completeCommitResponseReturnsMessageAndResolvedModel() throws {
    let data = Data(#"""
    {
        "model": "google/gemini-3.5-flash-20260519",
        "choices": [{
            "finish_reason": "stop",
            "native_finish_reason": "STOP",
            "message": {"content": "Configure local packages\n\nTrack camping asset metadata."}
        }]
    }
    """#.utf8)
    let response = try JSONDecoder().decode(OpenRouterCommitResponse.self, from: data)

    let completion = try response.completion(fallbackModel: "openrouter/auto")

    #expect(completion.message == "Configure local packages\n\nTrack camping asset metadata.")
    #expect(completion.model == "google/gemini-3.5-flash-20260519")
}
