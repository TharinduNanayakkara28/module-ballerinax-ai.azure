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

type AzureChatUserMessage record {|
    *ai:ChatUserMessage;
    string content;
|};

type AzureChatSystemMessage record {|
    *ai:ChatSystemMessage;
    string content;
|};

// ── Streaming types (Chat Completions `chat.completion.chunk`) ───────────────
// Azure OpenAI streams the Chat Completions API as server-sent events, one
// `chat.completion.chunk` object per event. The shape matches OpenAI's Chat
// Completions chunk, plus Azure's content-filter additions
// (`prompt_filter_results` and per-choice `content_filter_results`).

# A streamed chunk of a chat completion response (object: "chat.completion.chunk")
type ChatCompletionChunk record {
    # Unique identifier for the completion, shared across all chunks
    string id;
    # Object type, always "chat.completion.chunk"
    string 'object;
    # Unix timestamp (seconds) when the completion was created
    int created;
    # The model (deployment) used to generate the completion
    string model;
    # Fingerprint of the backend configuration the model runs with
    string system_fingerprint?;
    # Choices in this chunk; empty in the final usage-only chunk
    ChatCompletionChunkChoice[] choices;
    # Token usage, present only in the final chunk when stream_options.include_usage is set
    ChatCompletionUsage usage?;
    # Content-filter results for each input prompt, sent by Azure on the first chunk(s)
    PromptFilterResult[] prompt_filter_results?;
};

# A single choice within a streamed chunk
type ChatCompletionChunkChoice record {
    # Index of the choice in the list of choices
    int index;
    # The incremental content for this choice
    ChatCompletionChunkDelta delta;
    # Reason the model stopped, null until the final chunk for this choice
    # (e.g., "stop", "length", "tool_calls", "content_filter")
    string? finish_reason = ();
    # Content-filter results for the generated output (Azure only)
    ContentFilterResults content_filter_results?;
};

# The incremental delta for a streamed choice
type ChatCompletionChunkDelta record {
    # Role of the author, sent only on the first delta (typically "assistant")
    string role?;
    # Text content chunk
    string content?;
    # Refusal message chunk, if the model refuses
    string refusal?;
    # Incremental tool calls being streamed
    ChunkToolCall[] tool_calls?;
    # Azure-specific extension carrying the reasoning/chain-of-thought fragment
    # streamed by supported reasoning ("thinking") models, e.g. `o3`, `o4-mini`
    string reasoning_content?;
};

# An incremental tool call within a streamed delta
type ChunkToolCall record {
    # Index of the tool call, used to accumulate fragments across chunks
    int index;
    # Unique identifier for the tool call, sent on the first fragment
    string id?;
    # Tool type, sent on the first fragment (always "function")
    string 'type?;
    # The function name/arguments fragment
    ChunkToolCallFunction 'function?;
};

# Function name/arguments fragment in a streamed tool call
type ChunkToolCallFunction record {
    # Name of the function, sent on the first fragment
    string name?;
    # Partial JSON string chunk of the function arguments; accumulate across chunks
    string arguments?;
};

# Token usage for a streamed completion (final chunk when include_usage is set)
type ChatCompletionUsage record {
    # Number of tokens in the prompt
    int prompt_tokens;
    # Number of tokens in the generated completion
    int completion_tokens;
    # Total number of tokens used (prompt + completion)
    int total_tokens;
};

// ── Azure-specific: content-filter types ────────────────────────────────────

# Result of a content-filter category that reports a severity level
type ContentFilterSeverityResult record {
    # Whether the content was filtered for this category
    boolean filtered;
    # Severity level ("safe", "low", "medium", "high")
    string severity;
};

# Result of a content-filter category that reports a boolean detection
type ContentFilterDetectedResult record {
    # Whether the content was filtered for this category
    boolean filtered;
    # Whether the pattern was detected
    boolean detected;
};

# Set of content-filter results for a piece of content.
# Categories are present only when the filter ran for them.
type ContentFilterResults record {
    # Hateful content category result
    ContentFilterSeverityResult hate?;
    # Self-harm content category result
    ContentFilterSeverityResult self_harm?;
    # Sexual content category result
    ContentFilterSeverityResult sexual?;
    # Violent content category result
    ContentFilterSeverityResult violence?;
    # Jailbreak detection result
    ContentFilterDetectedResult jailbreak?;
    # Protected-material (text) detection result
    ContentFilterDetectedResult protected_material_text?;
    # Protected-material (code) detection result
    ContentFilterDetectedResult protected_material_code?;
    # Profanity detection result
    ContentFilterDetectedResult profanity?;
    # Error encountered while running the filter, if any
    ContentFilterError 'error?;
};

# Error reported when a content filter could not be evaluated
type ContentFilterError record {
    # Error code
    int code;
    # Error message
    string message;
};

# Content-filter results for one input prompt (top-level prompt_filter_results)
type PromptFilterResult record {
    # Index of the prompt these results apply to
    int prompt_index;
    # Content-filter results for the prompt
    ContentFilterResults content_filter_results;
};

// ── Wire → normalized mapping ──────────────────────────────────────────────
// Projects an Azure OpenAI `chat.completion.chunk` (the wire types above) onto
// the normalized `ai:ChatCompletionChunk` that `chatStream` must return. Only the
// subset the `ai` type can hold is mapped; Azure content-filter results and other
// fields are ignored.

# Maps an Azure OpenAI wire chunk onto the normalized `ai:ChatCompletionChunk`.
# Forwards tool calls on every chunk (not just the first), so argument fragments
# stream through correctly.
#
# + w - The parsed Azure OpenAI wire chunk
# + return - The normalized chunk consumed by the `ai` module
isolated function toAiChunk(ChatCompletionChunk w) returns ai:ChatCompletionChunk {
    ai:ChatCompletionChunkChoice[] choices = [];
    foreach ChatCompletionChunkChoice c in w.choices {
        ai:ChatCompletionChunkDelta delta = {content: c.delta?.content};
        ai:ROLE? role = mapRole(c.delta?.role);
        if role is ai:ROLE {
            delta.role = role;
        }
        string? reasoning = c.delta?.reasoning_content;
        if reasoning is string {
            delta.reasoning = reasoning;
        }
        ChunkToolCall[]? wireToolCalls = c.delta?.tool_calls;
        if wireToolCalls is ChunkToolCall[] {
            ai:ToolCallChunk[] toolCalls = [];
            foreach ChunkToolCall t in wireToolCalls {
                ai:ToolCallChunk toolCall = {index: t.index};
                string? id = t?.id;
                if id is string {
                    toolCall.id = id;
                }
                ChunkToolCallFunction? fn = t?.'function;
                if fn is ChunkToolCallFunction {
                    ai:FunctionCallChunk functionFragment = {};
                    string? name = fn?.name;
                    if name is string {
                        functionFragment.name = name;
                    }
                    string? arguments = fn?.arguments;
                    if arguments is string {
                        functionFragment.arguments = arguments;
                    }
                    toolCall.'function = functionFragment;
                }
                toolCalls.push(toolCall);
            }
            delta.toolCalls = toolCalls;
        }
        choices.push({index: c.index, delta, finishReason: mapFinishReason(c.finish_reason)});
    }

    ai:ChatCompletionChunk chunk = {id: w.id, model: w.model, choices};
    ChatCompletionUsage? usage = w.usage;
    if usage is ChatCompletionUsage {
        chunk.usage = {
            promptTokens: usage.prompt_tokens,
            completionTokens: usage.completion_tokens,
            totalTokens: usage.total_tokens
        };
    }
    return chunk;
}

# Safely maps an Azure OpenAI role string onto the `ai:ROLE` enum; returns `()` for
# absent or unrecognized values rather than panicking on a cast.
#
# + role - The role string from the wire delta
# + return - The mapped `ai:ROLE`, or `()` when absent/unrecognized
isolated function mapRole(string? role) returns ai:ROLE? {
    // Streamed response deltas only carry the "assistant" role; "system"/"user"
    // are handled for completeness. ("function" is request-only and the `ai`
    // enum member is not accessible here, so it is intentionally omitted.)
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
    }
    return ();
}

# Safely maps an Azure OpenAI finish reason onto the `ai:FinishReason` enum. The `ai`
# enum has no `function_call` member, so the deprecated `function_call` value is
# folded into `tool_calls`. Returns `()` for absent or unrecognized values.
#
# + finishReason - The finish reason from the wire chunk
# + return - The mapped `ai:FinishReason`, or `()` when absent/unrecognized
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
    }
    return ();
}

