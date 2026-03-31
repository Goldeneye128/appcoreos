package cli

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/appcoreos/appcorectl/internal/security"
)

func (a *app) newBootstrapCommand() *cobra.Command {
	cmd := &cobra.Command{Use: "bootstrap", Short: "Day-0 bootstrap operations"}
	cmd.AddCommand(a.newBootstrapStatusCommand(), a.newBootstrapClaimCommand(), a.newBootstrapWaitCommand())
	return cmd
}

func (a *app) newBootstrapStatusCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Get bootstrap status",
		RunE: func(cmd *cobra.Command, _ []string) error {
			r, err := a.buildRuntime(true)
			if err != nil {
				return err
			}
			if err := r.ensureServerTrustForBootstrap(cmd); err != nil {
				return err
			}
			c, err := r.newClient()
			if err != nil {
				return err
			}
			payload, err := runGet(context.Background(), c, "/v1/bootstrap/status", nil)
			if err != nil {
				return err
			}
			return printRead(cmd, r.output, payload)
		},
	}
}

func (a *app) newBootstrapClaimCommand() *cobra.Command {
	var token string
	var clientCAFile string
	var wait bool
	var waitTimeout int
	var waitInterval int
	cmd := &cobra.Command{
		Use:   "claim",
		Short: "Claim appliance during bootstrap",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if strings.TrimSpace(token) == "" {
				return validateError("--token is required", "pass the bootstrap token from the appliance")
			}

			r, err := a.buildRuntime(true)
			if err != nil {
				return err
			}
			if err := r.ensureServerTrustForBootstrap(cmd); err != nil {
				return err
			}

			var pem []byte
			var generated *security.LocalClientPKI
			if strings.TrimSpace(clientCAFile) != "" {
				pem, err = os.ReadFile(clientCAFile)
				if err != nil {
					return validateError("failed reading --client-ca-file", err.Error())
				}
			} else {
				generated, err = security.EnsureLocalClientPKI(r.targetName)
				if err != nil {
					return fmt.Errorf("generate local client PKI: %w", err)
				}
				pem = generated.CACertPEM

				profile := r.cfg.Targets[r.targetName]
				updated := false
				if profile.CertPath == "" {
					profile.CertPath = generated.ClientCertPath
					updated = true
				}
				if profile.KeyPath == "" {
					profile.KeyPath = generated.ClientKeyPath
					updated = true
				}
				if updated {
					r.cfg.Targets[r.targetName] = profile
					if err := r.saveConfig(); err != nil {
						return err
					}
				}
				// Keep runtime target in sync so post-claim readiness checks use mTLS immediately.
				r.target.CertPath = profile.CertPath
				r.target.KeyPath = profile.KeyPath
			}
			c, err := r.newClient()
			if err != nil {
				return err
			}
			headers := map[string]string{"X-Bootstrap-Token": strings.TrimSpace(token)}
			body := map[string]string{"client_ca_pem": string(pem)}
			if err := c.PostJSON(context.Background(), "/v1/bootstrap/claim", nil, headers, body, nil); err != nil {
				return err
			}
			if generated != nil {
				_, _ = fmt.Fprintf(cmd.OutOrStdout(), "Generated local client PKI in %s\n", generated.TargetDir)
				_, _ = fmt.Fprintf(cmd.OutOrStdout(), "Using client cert: %s\n", generated.ClientCertPath)
				_, _ = fmt.Fprintln(cmd.OutOrStdout(), "Note: --ca still configures server TLS trust; generated CA is for client mTLS.")
			}
			if wait {
				_, _ = fmt.Fprintln(cmd.OutOrStdout(), "Waiting for post-claim API readiness...")
				if err := waitForBootstrapReady(r, waitTimeout, waitInterval); err != nil {
					return err
				}
			}
			_, _ = fmt.Fprintln(cmd.OutOrStdout(), "Bootstrap claim succeeded.")
			return nil
		},
	}
	cmd.Flags().StringVar(&token, "token", "", "Bootstrap token")
	cmd.Flags().StringVar(&clientCAFile, "client-ca-file", "", "Path to PEM CA certificate for client auth (auto-generated if omitted)")
	cmd.Flags().BoolVar(&wait, "wait", true, "Wait for API readiness after claim")
	cmd.Flags().IntVar(&waitTimeout, "wait-timeout", 120, "Wait timeout in seconds")
	cmd.Flags().IntVar(&waitInterval, "wait-interval", 3, "Poll interval in seconds")
	return cmd
}

func (a *app) newBootstrapWaitCommand() *cobra.Command {
	var timeoutSeconds int
	var intervalSeconds int
	cmd := &cobra.Command{
		Use:   "wait",
		Short: "Wait for API readiness after bootstrap claim",
		RunE: func(cmd *cobra.Command, _ []string) error {
			r, err := a.buildRuntime(true)
			if err != nil {
				return err
			}
			if err := r.ensureServerTrustForBootstrap(cmd); err != nil {
				return err
			}
			return waitForBootstrapReady(r, timeoutSeconds, intervalSeconds)
		},
	}
	cmd.Flags().IntVar(&timeoutSeconds, "timeout", 120, "Wait timeout in seconds")
	cmd.Flags().IntVar(&intervalSeconds, "interval", 3, "Poll interval in seconds")
	return cmd
}

func (r *runtime) ensureServerTrustForBootstrap(cmd *cobra.Command) error {
	if r.target.Insecure || strings.TrimSpace(r.target.CAPath) != "" {
		return nil
	}
	caPath, err := security.PinServerCertificate(r.targetName, r.target.URL)
	if err != nil {
		return validateError(
			"failed to establish TLS trust for bootstrap",
			"set target CA with --ca, or use --insecure for local development",
		)
	}
	profile := r.cfg.Targets[r.targetName]
	profile.CAPath = caPath
	r.cfg.Targets[r.targetName] = profile
	if err := r.saveConfig(); err != nil {
		return err
	}
	r.target.CAPath = caPath
	_, _ = fmt.Fprintf(cmd.ErrOrStderr(), "Pinned server certificate for %q at %s\n", r.targetName, caPath)
	return nil
}

func waitForBootstrapReady(r *runtime, timeoutSeconds int, intervalSeconds int) error {
	if timeoutSeconds < 1 {
		return validateError("invalid wait timeout", "set --timeout/--wait-timeout to at least 1 second")
	}
	if intervalSeconds < 1 {
		return validateError("invalid wait interval", "set --interval/--wait-interval to at least 1 second")
	}

	deadline := time.Now().Add(time.Duration(timeoutSeconds) * time.Second)
	var lastErr error

	for {
		c, err := r.newClient()
		if err != nil {
			lastErr = err
		} else {
			statusPayload, err := runGet(context.Background(), c, "/v1/bootstrap/status", nil)
			if err != nil {
				lastErr = err
			} else if claimed, _ := boolFromMap(statusPayload, "claimed"); claimed {
				// Readiness condition: bootstrap marked claimed and /v1/info succeeds.
				if _, err := runGet(context.Background(), c, "/v1/info", nil); err == nil {
					return nil
				} else {
					lastErr = err
				}
			}
		}

		if time.Now().After(deadline) {
			if lastErr != nil {
				return &cliError{
					code: ExitCodeTransport,
					msg:  "timed out waiting for bootstrap readiness",
					hint: lastErr.Error(),
				}
			}
			return &cliError{
				code: ExitCodeTransport,
				msg:  "timed out waiting for bootstrap readiness",
				hint: "check agent.service and API reachability",
			}
		}
		time.Sleep(time.Duration(intervalSeconds) * time.Second)
	}
}

func boolFromMap(payload any, key string) (bool, bool) {
	m, ok := payload.(map[string]any)
	if !ok {
		return false, false
	}
	value, ok := m[key]
	if !ok {
		return false, false
	}
	asBool, ok := value.(bool)
	if !ok {
		return false, false
	}
	return asBool, true
}
