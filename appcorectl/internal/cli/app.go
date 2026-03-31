package cli

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/appcoreos/appcorectl/internal/client"
	"github.com/appcoreos/appcorectl/internal/config"
	"github.com/appcoreos/appcorectl/internal/output"
	"github.com/appcoreos/appcorectl/internal/version"
)

const (
	ExitCodeSuccess   = 0
	ExitCodeValidate  = 2
	ExitCodeAuth      = 3
	ExitCodeTransport = 4
	ExitCodeAPI       = 5
)

type rootOptions struct {
	configPath string
	target     string
	ca         string
	cert       string
	key        string
	apiKey     string
	insecure   bool
	output     string
}

type app struct {
	opts rootOptions
}

type runtime struct {
	cfgPath    string
	cfg        *config.Config
	targetName string
	target     config.TargetProfile
	output     string
	auditPath  string
}

type cliError struct {
	code int
	msg  string
	hint string
	err  error
}

func (e *cliError) Error() string {
	msg := e.msg
	if msg == "" && e.err != nil {
		msg = e.err.Error()
	}
	if e.hint != "" {
		return fmt.Sprintf("%s\nHint: %s", msg, e.hint)
	}
	return msg
}

func (e *cliError) Unwrap() error {
	return e.err
}

func validateError(msg, hint string) error {
	return &cliError{code: ExitCodeValidate, msg: msg, hint: hint}
}

func NewRootCommand() *cobra.Command {
	a := &app{}
	cmd := &cobra.Command{
		Use:           "appcorectl",
		Short:         "Official operator CLI for AppCoreOS",
		SilenceUsage:  true,
		SilenceErrors: true,
		Version:       version.Version,
	}
	cmd.PersistentFlags().StringVar(&a.opts.configPath, "config", "", "Path to config file")
	cmd.PersistentFlags().StringVar(&a.opts.target, "target", "", "Target profile name")
	cmd.PersistentFlags().StringVar(&a.opts.ca, "ca", "", "Custom CA certificate path")
	cmd.PersistentFlags().StringVar(&a.opts.cert, "cert", "", "Client certificate path")
	cmd.PersistentFlags().StringVar(&a.opts.key, "key", "", "Client private key path")
	cmd.PersistentFlags().StringVar(&a.opts.apiKey, "api-key", "", "API key")
	cmd.PersistentFlags().BoolVar(&a.opts.insecure, "insecure", false, "Skip TLS verification (local development only)")
	cmd.PersistentFlags().StringVarP(&a.opts.output, "output", "o", "", "Output format: table|json")

	cmd.AddCommand(
		a.newTargetCommand(),
		a.newBootstrapCommand(),
		a.newInfoCommand(),
		a.newStateCommand(),
		a.newServicesCommand(),
		a.newContainersCommand(),
		a.newLogsCommand(),
		a.newNetworkCommand(),
		a.newHostCommand(),
		a.newCompletionCommand(cmd),
	)
	return cmd
}

func Execute() int {
	root := NewRootCommand()
	if err := root.Execute(); err != nil {
		mapped := mapError(err)
		_, _ = fmt.Fprintln(os.Stderr, mapped.Error())
		return mapped.code
	}
	return ExitCodeSuccess
}

func mapError(err error) *cliError {
	var existing *cliError
	if errors.As(err, &existing) {
		return existing
	}

	var apiErr *client.APIError
	if errors.As(err, &apiErr) {
		if apiErr.StatusCode == 401 || apiErr.StatusCode == 403 {
			return &cliError{code: ExitCodeAuth, msg: apiErr.Error(), hint: "verify API key and mTLS client certificate for this target"}
		}
		return &cliError{code: ExitCodeAPI, msg: apiErr.Error(), hint: "check server status and endpoint compatibility"}
	}

	var transportErr *client.TransportError
	if errors.As(err, &transportErr) {
		return &cliError{code: ExitCodeTransport, msg: transportErr.Error(), hint: "verify target URL, CA/cert files, and network reachability"}
	}

	var urlErr *url.Error
	if errors.As(err, &urlErr) {
		return &cliError{code: ExitCodeTransport, msg: err.Error(), hint: "verify HTTPS endpoint and TLS trust chain"}
	}

	var netErr net.Error
	if errors.As(err, &netErr) {
		return &cliError{code: ExitCodeTransport, msg: err.Error(), hint: "confirm host connectivity and firewall rules"}
	}

	return &cliError{code: ExitCodeAPI, msg: err.Error(), hint: "rerun with corrected parameters or inspect server logs"}
}

func (a *app) buildRuntime(requireTarget bool) (*runtime, error) {
	cfgPath, err := config.ResolveConfigPath(a.opts.configPath)
	if err != nil {
		return nil, validateError("invalid --config path", err.Error())
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		return nil, validateError("failed to load config", "fix YAML syntax or select a valid --config path")
	}

	targetName := strings.TrimSpace(a.opts.target)
	if targetName == "" {
		targetName = config.EnvString("APPCORECTL_TARGET")
	}
	if targetName == "" {
		targetName = cfg.CurrentTarget
	}

	if requireTarget && targetName == "" {
		return nil, validateError("no active target selected", "run: appcorectl target use <name>")
	}

	baseProfile := config.TargetProfile{}
	if targetName != "" {
		baseProfile, err = cfg.ActiveTarget(targetName)
		if err != nil {
			return nil, validateError(err.Error(), "run: appcorectl target ls")
		}
	}

	flagProfile := config.TargetProfile{
		CAPath:   a.opts.ca,
		CertPath: a.opts.cert,
		KeyPath:  a.opts.key,
		APIKey:   a.opts.apiKey,
		Insecure: a.opts.insecure,
	}
	merged, err := config.MergeTarget(baseProfile, flagProfile)
	if err != nil {
		return nil, validateError(err.Error(), "set both --cert and --key for mTLS")
	}

	if requireTarget && strings.TrimSpace(merged.URL) == "" {
		return nil, validateError("target URL is missing", "run: appcorectl target add <name> --url https://host:9090")
	}
	if merged.Insecure {
		_, _ = fmt.Fprintln(os.Stderr, "WARNING: TLS verification disabled via --insecure / APPCORECTL_INSECURE. Do not use in production.")
	}

	auditPath, err := config.DefaultAuditLogPath()
	if err != nil {
		return nil, validateError("failed to resolve audit log path", err.Error())
	}
	return &runtime{
		cfgPath:    cfgPath,
		cfg:        cfg,
		targetName: targetName,
		target:     merged,
		output:     config.ResolveOutput(a.opts.output, cfg.Output),
		auditPath:  auditPath,
	}, nil
}

func (r *runtime) saveConfig() error {
	if err := config.Save(r.cfgPath, r.cfg); err != nil {
		return fmt.Errorf("save config: %w", err)
	}
	return nil
}

func (r *runtime) newClient() (*client.Client, error) {
	c, err := client.New(client.Options{
		TargetName:  r.targetName,
		BaseURL:     r.target.URL,
		CAPath:      r.target.CAPath,
		CertPath:    r.target.CertPath,
		KeyPath:     r.target.KeyPath,
		APIKey:      r.target.APIKey,
		Insecure:    r.target.Insecure,
		AuditLog:    r.auditPath,
		HTTPTimeout: 20 * time.Second,
	})
	if err != nil {
		return nil, validateError(err.Error(), "review target profile with: appcorectl target ls")
	}
	return c, nil
}

func printRead(cmd *cobra.Command, format string, data any) error {
	if format != "table" && format != "json" {
		return validateError("invalid --output value", "use --output table or --output json")
	}
	if err := output.Print(cmd.OutOrStdout(), format, data); err != nil {
		return fmt.Errorf("render output: %w", err)
	}
	return nil
}

func runGet(ctx context.Context, c *client.Client, path string, query url.Values) (any, error) {
	var payload any
	if err := c.GetJSON(ctx, path, query, nil, &payload); err != nil {
		return nil, err
	}
	return payload, nil
}

func runPost(ctx context.Context, c *client.Client, path string, body any) error {
	return c.PostJSON(ctx, path, nil, nil, body, nil)
}
