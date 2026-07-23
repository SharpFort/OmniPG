package apisix

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// ==============================================================================
// 数据模型
// ==============================================================================

type ApisixMetadata struct {
	Model  string `json:"model"`
	Policy string `json:"policy"`
}

type ApisixResponse struct {
	Value ApisixMetadata `json:"value"`
}

// APISIXClient 定义 APISIX 交互接口（便于测试 Mock）
type APISIXClient interface {
	GetPolicy() (string, error)
	PutPolicy(model, policy string) error
}

// ==============================================================================
// HTTP 客户端实现
// ==============================================================================

type httpClient struct {
	url    string
	key    string
	client *http.Client
}

func NewHTTPClient(apiURL, apiKey string) *httpClient {
	return &httpClient{
		url:    apiURL,
		key:    apiKey,
		client: &http.Client{Timeout: 10 * time.Second},
	}
}

func (c *httpClient) GetPolicy() (string, error) {
	req, err := http.NewRequest("GET", c.url, nil)
	if err != nil {
		return "", fmt.Errorf("创建请求失败: %w", err)
	}
	req.Header.Set("X-API-KEY", c.key)

	resp, err := c.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("HTTP 请求失败: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return "", nil
	}
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("APISIX 返回 %d: %s", resp.StatusCode, string(body))
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("读取响应体失败: %w", err)
	}

	var apisixResp ApisixResponse
	if err := json.Unmarshal(body, &apisixResp); err != nil {
		return "", fmt.Errorf("解析 JSON 失败: %w", err)
	}

	return apisixResp.Value.Policy, nil
}

func (c *httpClient) PutPolicy(model, policy string) error {
	metadata := ApisixMetadata{
		Model:  model,
		Policy: policy,
	}
	payload, err := json.Marshal(metadata)
	if err != nil {
		return fmt.Errorf("序列化 JSON 失败: %w", err)
	}

	req, err := http.NewRequest(http.MethodPut, c.url, bytes.NewBuffer(payload))
	if err != nil {
		return fmt.Errorf("创建请求失败: %w", err)
	}
	req.Header.Set("X-API-KEY", c.key)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.client.Do(req)
	if err != nil {
		return fmt.Errorf("HTTP 请求失败: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("APISIX 返回 %d: %s", resp.StatusCode, string(body))
	}
	return nil
}
