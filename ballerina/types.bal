// Copyright (c) 2025 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
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
import ballerina/http;
import ballerinax/azure.openai.chat;

# Configurations for controlling the behaviours when communicating with a remote HTTP endpoint.
@display {label: "Connection Configuration"}
public type ConnectionConfig record {|

    # The HTTP version understood by the client
    @display {label: "HTTP Version"}
    http:HttpVersion httpVersion = http:HTTP_2_0;

    # Configurations related to HTTP/1.x protocol
    @display {label: "HTTP1 Settings"}
    http:ClientHttp1Settings http1Settings?;

    # Configurations related to HTTP/2 protocol
    @display {label: "HTTP2 Settings"}
    http:ClientHttp2Settings http2Settings?;

    # The maximum time to wait (in seconds) for a response before closing the connection
    @display {label: "Timeout"}
    decimal timeout = 60;

    # The choice of setting `forwarded`/`x-forwarded` header
    @display {label: "Forwarded"}
    string forwarded = "disable";

    # Configurations associated with request pooling
    @display {label: "Pool Configuration"}
    http:PoolConfiguration poolConfig?;

    # HTTP caching related configurations
    @display {label: "Cache Configuration"}
    http:CacheConfig cache?;

    # Specifies the way of handling compression (`accept-encoding`) header
    @display {label: "Compression"}
    http:Compression compression = http:COMPRESSION_AUTO;

    # Configurations associated with the behaviour of the Circuit Breaker
    @display {label: "Circuit Breaker Configuration"}
    http:CircuitBreakerConfig circuitBreaker?;

    # Configurations associated with retrying
    @display {label: "Retry Configuration"}
    http:RetryConfig retryConfig?;

    # Configurations associated with inbound response size limits
    @display {label: "Response Limit Configuration"}
    http:ResponseLimitConfigs responseLimits?;

    # SSL/TLS-related options
    @display {label: "Secure Socket Configuration"}
    http:ClientSecureSocket secureSocket?;

    # Proxy server related options
    @display {label: "Proxy Configuration"}
    http:ProxyConfig proxy?;

    # Enables the inbound payload validation functionality which provided by the constraint package. Enabled by default
    @display {label: "Payload Validation"}
    boolean validation = true;
|};

# The Azure OpenAI API surface used by the `OpenAiModelProvider`.
#
# The concrete wire route is derived from both this value and the shape of the `serviceUrl`:
#
# | `apiType` | `serviceUrl` ends with `/v1` (v1 GA) | otherwise (legacy) |
# | --- | --- | --- |
# | `CHAT_COMPLETIONS` | `POST {serviceUrl}/chat/completions` via the `azure.openai.chat` connector | `POST {legacyBase}/deployments/{deploymentId}/chat/completions?api-version={apiVersion}` |
# | `RESPONSES` | `POST {serviceUrl}/responses` via the `azure.openai.responses` connector | `POST {legacyBase}/responses?api-version={apiVersion}` |
#
# On the legacy surface `legacyBase` is the `serviceUrl` completed with `/openai` when it is a bare origin
# (e.g. `https://<resource>.openai.azure.com`) and used verbatim when it already carries a path (e.g. an API
# Management base path).
@display {label: "OpenAI API Type"}
public enum ApiType {
    # Use the OpenAI Chat Completions API (`/chat/completions`)
    CHAT_COMPLETIONS = "chat_completions",
    # Use the OpenAI Responses API (`/responses`)
    RESPONSES = "responses"
}

# Reasoning effort level for reasoning models (`gpt-5`/`o`-series).
#
# The supported set follows the Azure OpenAI specification. Not every model supports every value (for example,
# `MINIMAL` is only supported by the original `gpt-5` reasoning models, `XHIGH` only by `gpt-5.1-codex-max` and
# later, and `NONE` only by `gpt-5.1`+). Passing an unsupported value for the target deployment results in an
# error from the service.
public enum ReasoningEffort {
    # No reasoning; supported by `gpt-5.1` and later.
    NONE = "none",
    # The smallest amount of reasoning; supported by the original `gpt-5` reasoning models.
    MINIMAL = "minimal",
    # Favours speed and fewer reasoning tokens.
    LOW = "low",
    # Balances reasoning depth and latency.
    MEDIUM = "medium",
    # Favours more complete reasoning.
    HIGH = "high",
    # The largest amount of reasoning; supported by `gpt-5.1-codex-max` and later.
    XHIGH = "xhigh"
}

// ===== Streaming (`chatStream`) wire types =====
//
// The generated `azure.openai.chat` connector already models the Chat Completions streaming schema
// (`OpenAIChatCompletionStreamResponseDelta`, `OpenAIChatCompletionMessageToolCallChunk`, ...), including the
// Azure-specific `reasoning_content` extension. It is not reused directly for parsing here because it declares
// `content`/`refusal`/`reasoning_content`/`usage` as optional but not nilable, whereas Azure sends each of these
// as an explicit JSON `null` on chunks that don't carry that field; binding the raw SSE payload straight to the
// generated type therefore fails `cloneWithType` on those chunks.
//
// These module-local mirrors keep the same field set but declare EVERY field Azure may send as `null` nilable,
// including inside the tool-call chunks - Azure omits `id`/`type` on the tool-call fragments that follow the
// first one on some api-versions and sends them as explicit `null` on others, and the connector's
// `OpenAIChatCompletionMessageToolCallChunk` types both as non-nilable. Since a bind failure now fails the whole
// stream (see `AzureOpenAiChunkIterator`), tolerating those nulls here is what keeps a well-formed response from
// being reported as a wire error. Fields this module does not surface (`system_fingerprint`, `object`,
// `created`, `logprobs`, ...) are simply not modeled: every record here is open, so they bind and are ignored.

# Wire shape of a Chat Completions streaming chunk (`chat.completion.chunk`), as sent by Azure over SSE.
type ChatCompletionChunk record {
    # Unique identifier for the completion; stable across all chunks of one response
    string id?;
    # The model that produced the completion
    string model?;
    # Choices in this chunk; empty in the final usage-only chunk
    ChatCompletionChunkChoice[] choices;
    # Token usage, present only in the final chunk when `stream_options.include_usage` is set. Azure sends this
    # key with an explicit JSON `null` on every other chunk, so the field must be nilable, not just optional, or
    # `cloneWithType` rejects every intermediate chunk.
    chat:OpenAICompletionUsage? usage?;
};

# A single choice within a streamed chunk.
type ChatCompletionChunkChoice record {
    # Index of the choice in the list of choices
    int index;
    # The incremental message content for this chunk
    ChatCompletionChunkDelta delta;
    # Reason the model stopped generating tokens; `()` until the final chunk
    string? finish_reason?;
};

# The incremental delta for a streamed choice. Azure sends `role`/`content`/`refusal`/`reasoning_content` as
# explicit JSON `null` on chunks that don't carry that field (e.g. a tool-call-only delta), so these must be
# nilable, not just optional, or `cloneWithType` rejects the chunk.
type ChatCompletionChunkDelta record {
    # Role of the author, sent only on the first delta (typically "assistant")
    string? role?;
    # Text content chunk
    string? content?;
    # Refusal message chunk, if the model refuses
    string? refusal?;
    # Incremental tool calls being streamed
    ChatCompletionMessageToolCallChunk[]? tool_calls?;
    # Azure-specific extension carrying the reasoning/chain-of-thought fragment streamed by supported reasoning
    # ("thinking") models, e.g. `o3`, `o4-mini`
    string? reasoning_content?;
};

# An incremental tool call within a streamed delta. Mirrors the connector's
# `OpenAIChatCompletionMessageToolCallChunk` with `id`/`type` nilable: Azure sends both only on the first
# fragment of a call and may send them as explicit `null` on the fragments that follow.
type ChatCompletionMessageToolCallChunk record {
    # Index used to accumulate fragments of the same tool call across chunks
    int index;
    # The ID of the tool call; only on the first fragment of the call
    string? id?;
    # The type of the tool; only `function` is supported
    string? 'type?;
    # The function name/arguments fragment
    ChatCompletionMessageToolCallChunkFunction? 'function?;
};

# The function fragment of a streamed tool call, with both fields nilable for the same reason as
# `ChatCompletionMessageToolCallChunk`.
type ChatCompletionMessageToolCallChunkFunction record {
    # Name of the function to call; only on the first fragment of the call
    string? name?;
    # Incremental JSON-string fragment of the function arguments
    string? arguments?;
};

# Converts one parsed Azure wire chunk into the normalized chunk that `chatStream` returns.
#
# + w - The parsed Azure wire chunk
# + return - The normalized chunk
isolated function toAiChunk(ChatCompletionChunk w) returns ai:ChatCompletionChunk {
    ai:ChatCompletionChunkChoice[] choices = [];
    foreach ChatCompletionChunkChoice c in w.choices {
        ai:ChatCompletionChunkDelta delta = {};
        string? content = c.delta?.content;
        if content is string {
            delta.content = content;
        }
        ai:ROLE? role = mapRole(c.delta?.role);
        if role is ai:ROLE {
            delta.role = role;
        }
        string? reasoning = c.delta?.reasoning_content;
        if reasoning is string {
            delta.reasoning = reasoning;
        }
        ChatCompletionMessageToolCallChunk[]? wireToolCalls = c.delta?.tool_calls;
        if wireToolCalls is ChatCompletionMessageToolCallChunk[] {
            ai:ToolCallChunk[] toolCalls = [];
            foreach ChatCompletionMessageToolCallChunk tc in wireToolCalls {
                ai:ToolCallChunk toolCall = {index: tc.index};
                string? id = tc?.id;
                if id is string {
                    toolCall.id = id;
                }
                ChatCompletionMessageToolCallChunkFunction? fn = tc?.'function;
                if fn is ChatCompletionMessageToolCallChunkFunction {
                    ai:FunctionCallChunk functionCallChunk = {};
                    string? name = fn?.name;
                    if name is string {
                        functionCallChunk.name = name;
                    }
                    string? args = fn?.arguments;
                    if args is string {
                        functionCallChunk.arguments = args;
                    }
                    toolCall.'function = functionCallChunk;
                }
                toolCalls.push(toolCall);
            }
            delta.toolCalls = toolCalls;
        }
        choices.push({index: c.index, delta, finishReason: mapFinishReason(c?.finish_reason)});
    }

    ai:ChatCompletionChunk chunk = {id: w.id, model: w.model, choices};
    chat:OpenAICompletionUsage? usage = w?.usage;
    if usage is chat:OpenAICompletionUsage {
        chunk.usage = {
            promptTokens: usage.prompt_tokens,
            completionTokens: usage.completion_tokens,
            totalTokens: usage.total_tokens
        };
    }
    return chunk;
}

# Safe string→enum lookup for the streamed delta role (no raw cast that could panic).
#
# + role - The wire role string, if present
# + return - The normalized role, or `()` for an absent/unrecognized value
isolated function mapRole(string? role) returns ai:ROLE? {
    match role {
        "system" => {
            return ai:SYSTEM;
        }
        "user" => {
            return ai:USER;
        }
        "assistant" => {
            return ai:ASSISTANT;
        }
        _ => {
            return ();
        }
    }
}

# Safe string→enum lookup for the streamed finish reason.
#
# + finishReason - The wire finish-reason string, if present
# + return - The normalized finish reason, or `()` for an absent/unrecognized value
isolated function mapFinishReason(string? finishReason) returns ai:FinishReason? {
    match finishReason {
        "stop" => {
            return ai:STOP;
        }
        "length" => {
            return ai:LENGTH;
        }
        "tool_calls"|"function_call" => {
            return ai:TOOL_CALLS;
        }
        "content_filter" => {
            return ai:CONTENT_FILTER;
        }
        _ => {
            return ();
        }
    }
}
