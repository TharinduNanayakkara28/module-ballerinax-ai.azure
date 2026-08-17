// Copyright (c) 2025 WSO2 LLC. (http://www.wso2.org).
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/test;

// Streaming is exercised against both surfaces `chatStream`/`generateStream` support: the legacy
// (deployment-scoped, `api-version` query parameter) route and the v1 GA (`/v1`, deployment sent as `model`)
// route. Both mock resources (see `test_services.bal`) serve the same canned `getStreamingChunkEvents()` SSE
// sequence for any `stream: true` request, so the two providers are expected to observe identical results.
final OpenAiModelProvider legacyStreamingProvider =
    check new (SERVICE_URL, API_KEY, "gpt4streaming", API_VERSION);
final OpenAiModelProvider v1StreamingProvider =
    check new (SERVICE_URL_V1, API_KEY, "gpt4streaming");

@test:Config
function testChatStreamLegacy() returns error? {
    check assertChatStream(legacyStreamingProvider);
}

@test:Config
function testChatStreamV1() returns error? {
    check assertChatStream(v1StreamingProvider);
}

function assertChatStream(OpenAiModelProvider provider) returns error? {
    stream<ai:ChatCompletionChunk, ai:Error?> chunkStream =
        check provider->chatStream({role: ai:USER, content: "Say hello."});

    string content = "";
    string reasoning = "";
    ai:FinishReason? finishReason = ();
    ai:CompletionTokenUsage? usage = ();

    while true {
        record {|ai:ChatCompletionChunk value;|}|ai:Error? next = chunkStream.next();
        if next is () {
            break;
        }
        if next is ai:Error {
            test:assertFail("Unexpected error while reading the chunk stream: " + next.message());
        }
        ai:ChatCompletionChunk chunk = next.value;
        ai:CompletionTokenUsage? chunkUsage = chunk.usage;
        if chunkUsage is ai:CompletionTokenUsage {
            usage = chunkUsage;
        }
        foreach ai:ChatCompletionChunkChoice choice in chunk.choices {
            string? deltaContent = choice.delta.content;
            if deltaContent is string {
                content += deltaContent;
            }
            // Reasoning ("thinking") fragments streamed via Azure's `reasoning_content`
            // extension must be mapped onto `delta.reasoning`.
            string? deltaReasoning = choice.delta.reasoning;
            if deltaReasoning is string {
                reasoning += deltaReasoning;
            }
            ai:FinishReason? choiceFinishReason = choice.finishReason;
            if choiceFinishReason is ai:FinishReason {
                finishReason = choiceFinishReason;
            }
        }
    }

    test:assertEquals(content, STREAMING_CONTENT_TEXT);
    test:assertEquals(reasoning, STREAMING_REASONING_TEXT);
    test:assertEquals(finishReason, ai:STOP);
    test:assertEquals(usage, {promptTokens: 5, completionTokens: 3, totalTokens: 8});
}

@test:Config
function testGenerateStreamLegacy() returns error? {
    check assertGenerateStream(legacyStreamingProvider);
}

@test:Config
function testGenerateStreamV1() returns error? {
    check assertGenerateStream(v1StreamingProvider);
}

function assertGenerateStream(OpenAiModelProvider provider) returns error? {
    stream<string, ai:Error?> textStream = check provider->generateStream(`Say hello.`);

    string result = "";
    while true {
        record {|string value;|}|ai:Error? next = textStream.next();
        if next is () {
            break;
        }
        if next is ai:Error {
            test:assertFail("Unexpected error while reading the text stream: " + next.message());
        }
        result += next.value;
    }

    // Only the answer text is surfaced; reasoning fragments are not part of the
    // `string` stream that `generateStream` promises.
    test:assertEquals(result, STREAMING_CONTENT_TEXT);
}

@test:Config
function testGenerateStreamWithUnsupportedType() returns error? {
    stream<int, ai:Error?>|ai:Error result = legacyStreamingProvider->generateStream(`Say hello.`);
    test:assertTrue(result is ai:Error, "Expected an error for a non-string expected type");

    string message = (<ai:Error>result).message();
    test:assertTrue(message.includes("This data type is not supported for streaming"),
            string `unexpected error message: ${message}`);
}

@test:Config
function testChatStreamUnsupportedForResponsesApi() returns error? {
    OpenAiModelProvider responsesProvider =
        check new (SERVICE_URL, API_KEY, "gpt4streaming", API_VERSION, apiType = RESPONSES);
    stream<ai:ChatCompletionChunk, ai:Error?>|ai:Error result =
        responsesProvider->chatStream({role: ai:USER, content: "Say hello."});
    test:assertTrue(result is ai:Error, "Expected an error when streaming a Responses API provider");

    string message = (<ai:Error>result).message();
    test:assertTrue(message.includes("apiType = CHAT_COMPLETIONS"),
            string `unexpected error message: ${message}`);
}
