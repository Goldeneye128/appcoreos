package cli

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/appcoreos/appcorectl/internal/security"
)

func (a *app) newBootstrapCommand() *cobra.Command {
	cmd := &cobra.Command{Use: "bootstrap", Short: "Day-0 bootstrap operations"}
	cmd.AddCommand(a.newBootstrapStatusCommand(), a.newBootstrapClaimCommand())
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
			_, _ = fmt.Fprintln(cmd.OutOrStdout(), "Bootstrap claim succeeded.")
			return nil
		},
	}
	cmd.Flags().StringVar(&token, "token", "", "Bootstrap token")
	cmd.Flags().StringVar(&clientCAFile, "client-ca-file", "", "Path to PEM CA certificate for client auth (auto-generated if omitted)")
	return cmd
}
