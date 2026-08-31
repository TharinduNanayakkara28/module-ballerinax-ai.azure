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

// GPT-5-series deployments (`REASONING_DEPLOYMENT`, see `test_services.bal`) can reject a streaming Chat
// Completions request. `chatStream`/`generateStream` must surface Azure's own error message plus a hint pointing
// at `apiType = RESPONSES`, rather than an opaque "failed to open the SSE stream" error.

@test:Config
function testChatStreamRejectedForGpt5SeriesLegacy() returns error? {
    check assertChatStreamRejectedForGpt5Series(
        check new (SERVICE_URL, API_KEY, REASONING_DEPLOYMENT, API_VERSION));
}

@test:Config
function testChatStreamRejectedForGpt5SeriesV1() returns error? {
    check assertChatStreamRejectedForGpt5Series(check new (SERVICE_URL_V1, API_KEY, REASONING_DEPLOYMENT));
}

function assertChatStreamRejectedForGpt5Series(OpenAiModelProvider provider) returns error? {
    stream<ai:ChatCompletionChunk, ai:Error?>|ai:Error result =
        provider->chatStream({role: ai:USER, content: "Say hello."});
    test:assertTrue(result is ai:Error, "Expected an error when streaming a rejected GPT-5-series deployment");

    string message = (<ai:Error>result).message();
    test:assertTrue(message.includes("Streaming is not supported for this model"),
            string `Azure's own error message was not surfaced: ${message}`);
    test:assertTrue(message.includes("apiType = RESPONSES"),
            string `expected a hint pointing at the Responses API: ${message}`);
}

// ===== Chat Completions: tool calls, malformed chunks, and old api-versions =====

// Azure streams a tool call as a first fragment carrying id/type/name followed by argument-only fragments that
// send `id`/`type` as explicit JSON `null`. All of it must survive as a single accumulated tool call.
@test:Config
function testChatStreamToolCalls() returns error? {
    OpenAiModelProvider provider = check new (SERVICE_URL, API_KEY, TOOL_STREAM_DEPLOYMENT, API_VERSION);
    stream<ai:ChatCompletionChunk, ai:Error?> chunkStream =
        check provider->chatStream({role: ai:USER, content: "Weather in Paris?"});

    string toolName = "";
    string toolId = "";
    string arguments = "";
    ai:FinishReason? finishReason = ();

    while true {
        record {|ai:ChatCompletionChunk value;|}|ai:Error? next = chunkStream.next();
        if next is () {
            break;
        }
        if next is ai:Error {
            test:assertFail("Unexpected error while reading the tool-call stream: " + next.message());
        }
        foreach ai:ChatCompletionChunkChoice choice in next.value.choices {
            ai:ToolCallChunk[]? toolCalls = choice.delta.toolCalls;
            if toolCalls is ai:ToolCallChunk[] {
                foreach ai:ToolCallChunk toolCall in toolCalls {
                    test:assertEquals(toolCall.index, 0, "all fragments belong to the same tool call");
                    string? id = toolCall.id;
                    if id is string {
                        toolId = id;
                    }
                    ai:FunctionCallChunk? fn = toolCall.'function;
                    if fn is ai:FunctionCallChunk {
                        string? name = fn.name;
                        if name is string {
                            toolName = name;
                        }
                        string? args = fn.arguments;
                        if args is string {
                            arguments += args;
                        }
                    }
                }
            }
            ai:FinishReason? choiceFinishReason = choice.finishReason;
            if choiceFinishReason is ai:FinishReason {
                finishReason = choiceFinishReason;
            }
        }
    }

    test:assertEquals(toolId, STREAMING_TOOL_CALL_ID);
    test:assertEquals(toolName, PARALLEL_TOOL_NAME);
    test:assertEquals(arguments, STREAMING_TOOL_ARGUMENTS);
    test:assertEquals(finishReason, ai:TOOL_CALLS);
}

// A chunk that is not valid JSON must fail the stream. Skipping it would silently truncate the answer, which is
// indistinguishable to the caller from the model simply having stopped.
@test:Config
function testChatStreamMalformedChunkFailsStream() returns error? {
    OpenAiModelProvider provider = check new (SERVICE_URL, API_KEY, MALFORMED_STREAM_DEPLOYMENT, API_VERSION);
    stream<ai:ChatCompletionChunk, ai:Error?> chunkStream =
        check provider->chatStream({role: ai:USER, content: "Say hello."});

    // The well-formed chunk before the malformed one is still delivered.
    record {|ai:ChatCompletionChunk value;|}|ai:Error? first = chunkStream.next();
    test:assertTrue(first is record {|ai:ChatCompletionChunk value;|}, "the first chunk must be delivered");

    record {|ai:ChatCompletionChunk value;|}|ai:Error? second = chunkStream.next();
    test:assertTrue(second is ai:Error, "a malformed chunk must fail the stream, not be skipped");
    string message = (<ai:Error>second).message();
    test:assertTrue(message.includes("Invalid or malformed chunk"),
            string `unexpected error message: ${message}`);

    // Once terminated, the stream stays terminated instead of resuming reads.
    test:assertTrue(chunkStream.next() is (), "a terminated stream must not resume");
}

// `stream_options` only reached the Chat Completions schema in api-version 2024-08-01-preview. On an older
// legacy api-version it must be omitted, or Azure rejects the whole request. The mock asserts the wire shape;
// this test drives it and confirms the stream still works (without a usage chunk).
@test:Config
function testChatStreamOmitsStreamOptionsOnOldApiVersion() returns error? {
    OpenAiModelProvider provider = check new (SERVICE_URL, API_KEY, "gpt4streaming", OLD_API_VERSION);
    stream<ai:ChatCompletionChunk, ai:Error?> chunkStream =
        check provider->chatStream({role: ai:USER, content: "Say hello."});

    string content = "";
    while true {
        record {|ai:ChatCompletionChunk value;|}|ai:Error? next = chunkStream.next();
        if next is () {
            break;
        }
        if next is ai:Error {
            test:assertFail("Unexpected error while reading the chunk stream: " + next.message());
        }
        foreach ai:ChatCompletionChunkChoice choice in next.value.choices {
            string? deltaContent = choice.delta.content;
            if deltaContent is string {
                content += deltaContent;
            }
        }
    }
    test:assertEquals(content, STREAMING_CONTENT_TEXT);
}

// ===== Responses API streaming =====
//
// The Responses API streams `type`-discriminated lifecycle events rather than repeated deltas of one envelope,
// so it exercises an entirely separate iterator. Every scenario runs against both the legacy and the v1 GA
// surface, which serve identical canned event sequences.

@test:Config
function testResponsesChatStreamLegacy() returns error? {
    check assertResponsesChatStream(check newResponsesStreamProvider(SERVICE_URL, RESPONSES_STREAM_DEPLOYMENT));
}

@test:Config
function testResponsesChatStreamV1() returns error? {
    check assertResponsesChatStream(check newResponsesStreamProvider(SERVICE_URL_V1, RESPONSES_STREAM_DEPLOYMENT));
}

function assertResponsesChatStream(OpenAiModelProvider provider) returns error? {
    stream<ai:ChatCompletionChunk, ai:Error?> chunkStream =
        check provider->chatStream({role: ai:USER, content: "Say hello."});

    string content = "";
    string reasoning = "";
    string firstChunkId = "";
    ai:ROLE? firstRole = ();
    ai:FinishReason? finishReason = ();
    ai:CompletionTokenUsage? usage = ();
    boolean firstChunkSeen = false;

    while true {
        record {|ai:ChatCompletionChunk value;|}|ai:Error? next = chunkStream.next();
        if next is () {
            break;
        }
        if next is ai:Error {
            test:assertFail("Unexpected error while reading the Responses chunk stream: " + next.message());
        }
        ai:ChatCompletionChunk chunk = next.value;
        if !firstChunkSeen {
            firstChunkSeen = true;
            firstChunkId = chunk.id ?: "";
            firstRole = chunk.choices.length() > 0 ? chunk.choices[0].delta.role : ();
        }
        ai:CompletionTokenUsage? chunkUsage = chunk.usage;
        if chunkUsage is ai:CompletionTokenUsage {
            usage = chunkUsage;
        }
        foreach ai:ChatCompletionChunkChoice choice in chunk.choices {
            string? deltaContent = choice.delta.content;
            if deltaContent is string {
                content += deltaContent;
            }
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
    // Reasoning fragments arrive as `response.reasoning_summary_text.delta`, which Azure only sends when the
    // request asked for a reasoning summary.
    test:assertEquals(reasoning, STREAMING_REASONING_TEXT);
    test:assertEquals(finishReason, ai:STOP);
    // Usage must survive even though the envelope omits `input_tokens_details`/`output_tokens_details`.
    test:assertEquals(usage, {promptTokens: 5, completionTokens: 3, totalTokens: 8});
    // Chunk shape parity with the Chat Completions surface: a stable id and an opening assistant role.
    test:assertEquals(firstChunkId, RESPONSES_STREAM_ID, "chunks must carry the stream-wide response id");
    test:assertEquals(firstRole, ai:ASSISTANT, "the first chunk must open with the assistant role");
}

@test:Config
function testResponsesChatStreamToolCallsLegacy() returns error? {
    check assertResponsesToolCallStream(
        check newResponsesStreamProvider(SERVICE_URL, RESPONSES_STREAM_TOOLS_DEPLOYMENT));
}

@test:Config
function testResponsesChatStreamToolCallsV1() returns error? {
    check assertResponsesToolCallStream(
        check newResponsesStreamProvider(SERVICE_URL_V1, RESPONSES_STREAM_TOOLS_DEPLOYMENT));
}

function assertResponsesToolCallStream(OpenAiModelProvider provider) returns error? {
    stream<ai:ChatCompletionChunk, ai:Error?> chunkStream =
        check provider->chatStream({role: ai:USER, content: "Weather in Paris?"});

    string toolName = "";
    string toolId = "";
    string arguments = "";
    ai:FinishReason? finishReason = ();

    while true {
        record {|ai:ChatCompletionChunk value;|}|ai:Error? next = chunkStream.next();
        if next is () {
            break;
        }
        if next is ai:Error {
            test:assertFail("Unexpected error while reading the Responses tool-call stream: " + next.message());
        }
        foreach ai:ChatCompletionChunkChoice choice in next.value.choices {
            ai:ToolCallChunk[]? toolCalls = choice.delta.toolCalls;
            if toolCalls is ai:ToolCallChunk[] {
                foreach ai:ToolCallChunk toolCall in toolCalls {
                    test:assertEquals(toolCall.index, 0, "all fragments belong to the same tool call");
                    string? id = toolCall.id;
                    if id is string {
                        toolId = id;
                    }
                    ai:FunctionCallChunk? fn = toolCall.'function;
                    if fn is ai:FunctionCallChunk {
                        string? name = fn.name;
                        if name is string {
                            toolName = name;
                        }
                        string? args = fn.arguments;
                        if args is string {
                            arguments += args;
                        }
                    }
                }
            }
            ai:FinishReason? choiceFinishReason = choice.finishReason;
            if choiceFinishReason is ai:FinishReason {
                finishReason = choiceFinishReason;
            }
        }
    }

    // The tool-call correlation id must be `call_id` (what a tool result is echoed back with), not the internal
    // `item_id` the delta events are keyed by.
    test:assertEquals(toolId, STREAMING_TOOL_CALL_ID);
    test:assertEquals(toolName, PARALLEL_TOOL_NAME);
    test:assertEquals(arguments, STREAMING_TOOL_ARGUMENTS);
    test:assertEquals(finishReason, ai:TOOL_CALLS);
}

// Hitting the output-token cap is an ordinary early stop, exactly as `finish_reason: "length"` is on the Chat
// Completions surface: the partial text must survive and the terminal chunk must report `LENGTH`, rather than
// the stream failing and discarding what the model did produce.
@test:Config
function testResponsesChatStreamIncompleteYieldsLengthFinishReason() returns error? {
    OpenAiModelProvider provider =
        check newResponsesStreamProvider(SERVICE_URL, RESPONSES_STREAM_INCOMPLETE_DEPLOYMENT);
    stream<ai:ChatCompletionChunk, ai:Error?> chunkStream =
        check provider->chatStream({role: ai:USER, content: "Say hello."});

    string content = "";
    ai:FinishReason? finishReason = ();
    while true {
        record {|ai:ChatCompletionChunk value;|}|ai:Error? next = chunkStream.next();
        if next is () {
            break;
        }
        if next is ai:Error {
            test:assertFail("An incomplete response must not fail the stream: " + next.message());
        }
        foreach ai:ChatCompletionChunkChoice choice in next.value.choices {
            string? deltaContent = choice.delta.content;
            if deltaContent is string {
                content += deltaContent;
            }
            ai:FinishReason? choiceFinishReason = choice.finishReason;
            if choiceFinishReason is ai:FinishReason {
                finishReason = choiceFinishReason;
            }
        }
    }

    test:assertEquals(content, STREAMING_CONTENT_TEXT, "partial output must survive an incomplete response");
    test:assertEquals(finishReason, ai:LENGTH);
}

// A `response.failed` must surface Azure's own message. Its `code` here (`content_filter`) is outside the
// connector's closed error-code union, which is exactly the case that used to lose the message.
@test:Config
function testResponsesChatStreamFailedSurfacesAzureMessage() returns error? {
    OpenAiModelProvider provider =
        check newResponsesStreamProvider(SERVICE_URL, RESPONSES_STREAM_FAILED_DEPLOYMENT);
    stream<ai:ChatCompletionChunk, ai:Error?> chunkStream =
        check provider->chatStream({role: ai:USER, content: "Say hello."});

    ai:Error? failure = ();
    while true {
        record {|ai:ChatCompletionChunk value;|}|ai:Error? next = chunkStream.next();
        if next is () {
            break;
        }
        if next is ai:Error {
            failure = next;
            break;
        }
    }

    test:assertTrue(failure is ai:Error, "a 'response.failed' event must fail the stream");
    test:assertEquals((<ai:Error>failure).message(), RESPONSES_STREAM_FAILURE_MESSAGE);
}

// A top-level `error` event (a mid-stream rate limit, say) is distinct from a `response.failed` envelope and
// must also fail the stream with Azure's message.
@test:Config
function testResponsesChatStreamErrorEvent() returns error? {
    OpenAiModelProvider provider =
        check newResponsesStreamProvider(SERVICE_URL, RESPONSES_STREAM_ERROR_DEPLOYMENT);
    stream<ai:ChatCompletionChunk, ai:Error?> chunkStream =
        check provider->chatStream({role: ai:USER, content: "Say hello."});

    ai:Error? failure = ();
    while true {
        record {|ai:ChatCompletionChunk value;|}|ai:Error? next = chunkStream.next();
        if next is () {
            break;
        }
        if next is ai:Error {
            failure = next;
            break;
        }
    }

    test:assertTrue(failure is ai:Error, "a top-level 'error' event must fail the stream");
    test:assertEquals((<ai:Error>failure).message(), RESPONSES_STREAM_ERROR_MESSAGE);
}

// `generateStream` must work over the Responses surface too, projecting only the answer text - reasoning
// fragments are not part of the `string` stream it promises.
@test:Config
function testResponsesGenerateStream() returns error? {
    OpenAiModelProvider provider = check newResponsesStreamProvider(SERVICE_URL_V1, RESPONSES_STREAM_DEPLOYMENT);
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
    test:assertEquals(result, STREAMING_CONTENT_TEXT);
}

// A reasoning effort is set so the provider must ask for a reasoning summary alongside it; the mock asserts that
// pairing, and the text/reasoning assertions above confirm the deltas actually arrive.
function newResponsesStreamProvider(string serviceUrl, string deploymentId) returns OpenAiModelProvider|error =>
    serviceUrl == SERVICE_URL_V1
        ? new (serviceUrl, API_KEY, deploymentId, reasoningEffort = LOW, temperature = (), apiType = RESPONSES)
        : new (serviceUrl, API_KEY, deploymentId, API_VERSION, reasoningEffort = LOW, temperature = (),
                apiType = RESPONSES);
