package ollamamodel

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"iter"
	"net/http"
	"strings"
	"time"

	"google.golang.org/adk/model"
	"google.golang.org/genai"
)

// OllamaModel implements Google ADK's model.LLM interface against a local Ollama server.
type OllamaModel struct {
	ModelName string
	BaseURL   string
	Client    *http.Client
}

func New(modelName, baseURL string) *OllamaModel {
	cleanModel := strings.TrimPrefix(modelName, "ollama_chat/")
	cleanModel = strings.TrimPrefix(cleanModel, "ollama/")
	if baseURL == "" {
		baseURL = "http://127.0.0.1:11434"
	}
	baseURL = strings.TrimRight(baseURL, "/")
	return &OllamaModel{
		ModelName: cleanModel,
		BaseURL:   baseURL,
		Client: &http.Client{
			Timeout: 60 * time.Second,
		},
	}
}

func (m *OllamaModel) Name() string {
	return m.ModelName
}

type ollamaChatRequest struct {
	Model    string          `json:"model"`
	Messages []ollamaMessage `json:"messages"`
	Tools    []ollamaTool    `json:"tools,omitempty"`
	Stream   bool            `json:"stream"`
	Options  map[string]any  `json:"options,omitempty"`
}

type ollamaMessage struct {
	Role      string           `json:"role"`
	Content   string           `json:"content"`
	ToolCalls []ollamaToolCall `json:"tool_calls,omitempty"`
}

type ollamaToolCall struct {
	Function ollamaFunctionCall `json:"function"`
}

type ollamaFunctionCall struct {
	Name      string         `json:"name"`
	Arguments map[string]any `json:"arguments"`
}

type ollamaTool struct {
	Type     string             `json:"type"`
	Function ollamaToolFunction `json:"function"`
}

type ollamaToolFunction struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Parameters  any    `json:"parameters,omitempty"`
}

type ollamaChatResponse struct {
	Message ollamaMessage `json:"message"`
}

func (m *OllamaModel) GenerateContent(
	ctx context.Context,
	req *model.LLMRequest,
	stream bool,
) iter.Seq2[*model.LLMResponse, error] {
	return func(yield func(*model.LLMResponse, error) bool) {
		var messages []ollamaMessage

		if req.Config != nil && req.Config.SystemInstruction != nil {
			var sysParts []string
			for _, p := range req.Config.SystemInstruction.Parts {
				if p != nil && p.Text != "" {
					sysParts = append(sysParts, p.Text)
				}
			}
			if len(sysParts) > 0 {
				messages = append(messages, ollamaMessage{
					Role:    "system",
					Content: strings.Join(sysParts, "\n"),
				})
			}
		}

		for _, content := range req.Contents {
			if content == nil {
				continue
			}
			role := "user"
			if content.Role == "model" || content.Role == "assistant" {
				role = "assistant"
			}
			var textParts []string
			var toolCalls []ollamaToolCall

			for _, part := range content.Parts {
				if part == nil {
					continue
				}
				if part.Text != "" {
					textParts = append(textParts, part.Text)
				}
				if part.FunctionCall != nil {
					toolCalls = append(toolCalls, ollamaToolCall{
						Function: ollamaFunctionCall{
							Name:      part.FunctionCall.Name,
							Arguments: part.FunctionCall.Args,
						},
					})
				}
				if part.FunctionResponse != nil {
					respBytes, _ := json.Marshal(part.FunctionResponse.Response)
					messages = append(messages, ollamaMessage{
						Role:    "tool",
						Content: string(respBytes),
					})
				}
			}

			if len(textParts) > 0 || len(toolCalls) > 0 {
				messages = append(messages, ollamaMessage{
					Role:      role,
					Content:   strings.Join(textParts, "\n"),
					ToolCalls: toolCalls,
				})
			}
		}

		var tools []ollamaTool
		if req.Config != nil {
			for _, t := range req.Config.Tools {
				if t == nil {
					continue
				}
				for _, fd := range t.FunctionDeclarations {
					if fd == nil {
						continue
					}
					params := any(fd.Parameters)
					if params == nil && fd.ParametersJsonSchema != nil {
						params = fd.ParametersJsonSchema
					}
					if params == nil {
						params = map[string]any{
							"type":       "object",
							"properties": map[string]any{},
						}
					}
					tools = append(tools, ollamaTool{
						Type: "function",
						Function: ollamaToolFunction{
							Name:        fd.Name,
							Description: fd.Description,
							Parameters:  params,
						},
					})
				}
			}
		}

		chatReq := ollamaChatRequest{
			Model:    m.ModelName,
			Messages: messages,
			Tools:    tools,
			Stream:   false,
			Options: map[string]any{
				"temperature": 0.0,
			},
		}

		payloadBytes, err := json.Marshal(chatReq)
		if err != nil {
			yield(nil, fmt.Errorf("failed to marshal ollama request: %w", err))
			return
		}

		httpReq, err := http.NewRequestWithContext(
			ctx,
			http.MethodPost,
			m.BaseURL+"/api/chat",
			bytes.NewReader(payloadBytes),
		)
		if err != nil {
			yield(nil, fmt.Errorf("failed to create ollama request: %w", err))
			return
		}
		httpReq.Header.Set("Content-Type", "application/json")

		resp, err := m.Client.Do(httpReq)
		if err != nil {
			yield(nil, fmt.Errorf("ollama request failed: %w", err))
			return
		}
		defer resp.Body.Close()

		bodyBytes, err := io.ReadAll(resp.Body)
		if err != nil {
			yield(nil, fmt.Errorf("failed reading ollama response: %w", err))
			return
		}
		if resp.StatusCode >= 400 {
			yield(nil, fmt.Errorf("ollama HTTP %d: %s", resp.StatusCode, string(bodyBytes)))
			return
		}

		var chatResp ollamaChatResponse
		if err := json.Unmarshal(bodyBytes, &chatResp); err != nil {
			yield(nil, fmt.Errorf("failed to decode ollama response: %w", err))
			return
		}

		var parts []*genai.Part
		for _, tc := range chatResp.Message.ToolCalls {
			args := tc.Function.Arguments
			if args == nil {
				args = map[string]any{}
			}
			for k, v := range args {
				if v != nil {
					if _, isStr := v.(string); !isStr {
						if b, err := json.Marshal(v); err == nil {
							args[k] = string(b)
						}
					}
				}
			}
			parts = append(parts, &genai.Part{
				FunctionCall: &genai.FunctionCall{
					Name: tc.Function.Name,
					Args: args,
				},
			})
		}
		if chatResp.Message.Content != "" {
			parts = append(parts, genai.NewPartFromText(chatResp.Message.Content))
		}
		if len(parts) == 0 {
			parts = append(parts, genai.NewPartFromText("Audit step completed."))
		}

		llmResp := &model.LLMResponse{
			Content: &genai.Content{
				Role:  "model",
				Parts: parts,
			},
			TurnComplete: true,
		}
		yield(llmResp, nil)
	}
}
