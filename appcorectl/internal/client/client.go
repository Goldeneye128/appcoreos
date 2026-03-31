package client

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Options configures the API client.
type Options struct {
	TargetName  string
	BaseURL     string
	CAPath      string
	CertPath    string
	KeyPath     string
	APIKey      string
	Insecure    bool
	AuditLog    string
	HTTPTimeout time.Duration
}

// APIError indicates a non-2xx API response.
type APIError struct {
	StatusCode int
	Method     string
	Path       string
	Body       string
}

func (e *APIError) Error() string {
	if e.Body == "" {
		return fmt.Sprintf("API %s %s returned status %d", e.Method, e.Path, e.StatusCode)
	}
	return fmt.Sprintf("API %s %s returned status %d: %s", e.Method, e.Path, e.StatusCode, e.Body)
}

// TransportError wraps lower-level transport/TLS failures.
type TransportError struct {
	Err error
}

func (e *TransportError) Error() string {
	return e.Err.Error()
}

func (e *TransportError) Unwrap() error {
	return e.Err
}

// Client is an AppCoreOS API client.
type Client struct {
	baseURL    *url.URL
	httpClient *http.Client
	apiKey     string
	audit      *auditLogger
	targetName string
}

func New(opts Options) (*Client, error) {
	if strings.TrimSpace(opts.BaseURL) == "" {
		return nil, errors.New("target URL is empty")
	}
	parsed, err := url.Parse(opts.BaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse target URL: %w", err)
	}
	if parsed.Scheme != "https" {
		return nil, errors.New("target URL must use https")
	}
	tlsConfig, err := buildTLSConfig(opts)
	if err != nil {
		return nil, err
	}
	transport := &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   10 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 15 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		TLSClientConfig:       tlsConfig,
	}
	timeout := opts.HTTPTimeout
	if timeout <= 0 {
		timeout = 20 * time.Second
	}
	return &Client{
		baseURL: parsed,
		httpClient: &http.Client{
			Timeout:   timeout,
			Transport: transport,
		},
		apiKey:     opts.APIKey,
		audit:      newAuditLogger(opts.AuditLog),
		targetName: opts.TargetName,
	}, nil
}

func buildTLSConfig(opts Options) (*tls.Config, error) {
	tlsConfig := &tls.Config{
		MinVersion: tls.VersionTLS12,
	}
	if opts.Insecure {
		tlsConfig.InsecureSkipVerify = true
	}
	if strings.TrimSpace(opts.CAPath) != "" {
		caPath, err := filepath.Abs(opts.CAPath)
		if err != nil {
			return nil, fmt.Errorf("resolve CA path: %w", err)
		}
		pem, err := os.ReadFile(caPath)
		if err != nil {
			return nil, fmt.Errorf("read CA file: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, errors.New("parse CA PEM failed")
		}
		tlsConfig.RootCAs = pool
	}
	if opts.CertPath != "" || opts.KeyPath != "" {
		if opts.CertPath == "" || opts.KeyPath == "" {
			return nil, errors.New("both client cert and key are required for mTLS")
		}
		certPath, err := filepath.Abs(opts.CertPath)
		if err != nil {
			return nil, fmt.Errorf("resolve client cert path: %w", err)
		}
		keyPath, err := filepath.Abs(opts.KeyPath)
		if err != nil {
			return nil, fmt.Errorf("resolve client key path: %w", err)
		}
		pair, err := tls.LoadX509KeyPair(certPath, keyPath)
		if err != nil {
			return nil, fmt.Errorf("load client cert/key: %w", err)
		}
		tlsConfig.Certificates = []tls.Certificate{pair}
	}
	return tlsConfig, nil
}

func (c *Client) GetJSON(ctx context.Context, path string, query url.Values, headers map[string]string, out any) error {
	_, err := c.doJSON(ctx, http.MethodGet, path, query, headers, nil, out)
	return err
}

func (c *Client) PostJSON(ctx context.Context, path string, query url.Values, headers map[string]string, body any, out any) error {
	_, err := c.doJSON(ctx, http.MethodPost, path, query, headers, body, out)
	return err
}

func (c *Client) doJSON(
	ctx context.Context,
	method string,
	path string,
	query url.Values,
	headers map[string]string,
	body any,
	out any,
) (int, error) {
	relative, err := url.Parse(path)
	if err != nil {
		return 0, fmt.Errorf("parse request path: %w", err)
	}
	if query != nil {
		relative.RawQuery = query.Encode()
	}
	endpoint := c.baseURL.ResolveReference(relative)

	var bodyReader io.Reader
	if body != nil {
		bytesBody, err := json.Marshal(body)
		if err != nil {
			return 0, fmt.Errorf("marshal request body: %w", err)
		}
		bodyReader = bytes.NewReader(bytesBody)
	}

	req, err := http.NewRequestWithContext(ctx, method, endpoint.String(), bodyReader)
	if err != nil {
		return 0, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.apiKey)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		c.audit.write(auditEntry{Timestamp: time.Now().UTC(), Target: c.targetName, Verb: method, Path: path, ResultStatus: 0, Error: err.Error()})
		return 0, &TransportError{Err: err}
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, fmt.Errorf("read response body: %w", err)
	}
	c.audit.write(auditEntry{Timestamp: time.Now().UTC(), Target: c.targetName, Verb: method, Path: path, ResultStatus: resp.StatusCode})

	if resp.StatusCode >= 400 {
		trimmed := strings.TrimSpace(string(respBody))
		return resp.StatusCode, &APIError{StatusCode: resp.StatusCode, Method: method, Path: path, Body: trimmed}
	}
	if out == nil || len(respBody) == 0 {
		return resp.StatusCode, nil
	}
	if err := json.Unmarshal(respBody, out); err != nil {
		return resp.StatusCode, fmt.Errorf("decode response json: %w", err)
	}
	return resp.StatusCode, nil
}

type auditEntry struct {
	Timestamp    time.Time `json:"timestamp"`
	Target       string    `json:"target"`
	Verb         string    `json:"verb"`
	Path         string    `json:"path"`
	ResultStatus int       `json:"result_status"`
	Error        string    `json:"error,omitempty"`
}

type auditLogger struct {
	path string
	mu   sync.Mutex
}

func newAuditLogger(path string) *auditLogger {
	if strings.TrimSpace(path) == "" {
		return &auditLogger{}
	}
	return &auditLogger{path: path}
}

func (l *auditLogger) write(entry auditEntry) {
	if l.path == "" {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()

	if err := os.MkdirAll(filepath.Dir(l.path), 0o700); err != nil {
		return
	}
	f, err := os.OpenFile(l.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	_ = enc.Encode(entry)
}
