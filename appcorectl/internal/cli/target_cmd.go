package cli

import (
	"fmt"
	"net/url"
	"os"
	"sort"
	"strings"

	"github.com/spf13/cobra"

	"github.com/appcoreos/appcorectl/internal/config"
	"github.com/appcoreos/appcorectl/internal/security"
)

func (a *app) newTargetCommand() *cobra.Command {
	cmd := &cobra.Command{Use: "target", Short: "Manage API target profiles"}
	cmd.AddCommand(
		a.newTargetAddCommand(),
		a.newTargetUseCommand(),
		a.newTargetRemoveCommand(),
		a.newTargetListCommand(),
	)
	return cmd
}

func (a *app) newTargetAddCommand() *cobra.Command {
	var urlRaw, ca, cert, key, apiKey string
	var insecure bool
	cmd := &cobra.Command{
		Use:   "add <name>",
		Short: "Add or update a target profile",
		Args: func(_ *cobra.Command, args []string) error {
			if len(args) != 1 {
				return validateError("target add requires exactly one profile name", "run: appcorectl target add mylab --url https://host:9090")
			}
			if strings.TrimSpace(urlRaw) == "" {
				return validateError("--url is required", "use --url https://host:9090")
			}
			parsed, err := url.Parse(strings.TrimSpace(urlRaw))
			if err != nil || parsed.Scheme != "https" {
				return validateError("--url must be a valid https URL", "example: --url https://node1.example.com:9090")
			}
			if (cert == "") != (key == "") {
				return validateError("--cert and --key must be set together", "set both mTLS file paths")
			}
			return nil
		},
		RunE: func(cmd *cobra.Command, args []string) error {
			r, err := a.buildRuntime(false)
			if err != nil {
				return err
			}
			name := strings.TrimSpace(args[0])
			r.cfg.Targets[name] = config.TargetProfile{
				URL:      strings.TrimSpace(urlRaw),
				CAPath:   strings.TrimSpace(ca),
				CertPath: strings.TrimSpace(cert),
				KeyPath:  strings.TrimSpace(key),
				APIKey:   strings.TrimSpace(apiKey),
				Insecure: insecure,
			}
			if r.cfg.CurrentTarget == "" {
				r.cfg.CurrentTarget = name
			}
			if err := r.saveConfig(); err != nil {
				return err
			}
			_, _ = fmt.Fprintf(cmd.OutOrStdout(), "Saved target %q\n", name)
			return nil
		},
	}
	cmd.Flags().StringVar(&urlRaw, "url", "", "Target URL (https://host:9090)")
	cmd.Flags().StringVar(&ca, "ca", "", "CA certificate path")
	cmd.Flags().StringVar(&cert, "cert", "", "Client certificate path")
	cmd.Flags().StringVar(&key, "key", "", "Client key path")
	cmd.Flags().StringVar(&apiKey, "api-key", "", "API key")
	cmd.Flags().BoolVar(&insecure, "insecure", false, "Skip TLS verification (local development only)")
	return cmd
}

func (a *app) newTargetUseCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "use <name>",
		Short: "Select default target profile",
		Args: func(_ *cobra.Command, args []string) error {
			if len(args) != 1 {
				return validateError("target use requires exactly one profile name", "run: appcorectl target use <name>")
			}
			return nil
		},
		RunE: func(cmd *cobra.Command, args []string) error {
			r, err := a.buildRuntime(false)
			if err != nil {
				return err
			}
			name := strings.TrimSpace(args[0])
			if _, ok := r.cfg.Targets[name]; !ok {
				return validateError(fmt.Sprintf("target %q not found", name), "run: appcorectl target ls")
			}
			r.cfg.CurrentTarget = name
			if err := r.saveConfig(); err != nil {
				return err
			}
			_, _ = fmt.Fprintf(cmd.OutOrStdout(), "Using target %q\n", name)
			return nil
		},
	}
}

func (a *app) newTargetListCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "ls",
		Short: "List configured target profiles",
		RunE: func(cmd *cobra.Command, _ []string) error {
			r, err := a.buildRuntime(false)
			if err != nil {
				return err
			}
			rows := make([]map[string]any, 0, len(r.cfg.Targets))
			for name, profile := range r.cfg.Targets {
				rows = append(rows, map[string]any{
					"name":     name,
					"current":  name == r.cfg.CurrentTarget,
					"url":      profile.URL,
					"ca":       profile.CAPath,
					"cert":     profile.CertPath,
					"key":      profile.KeyPath,
					"api_key":  security.RedactSecret(profile.APIKey),
					"insecure": profile.Insecure,
				})
			}
			return printRead(cmd, r.output, rows)
		},
	}
}

func (a *app) newTargetRemoveCommand() *cobra.Command {
	var purgePKI bool
	cmd := &cobra.Command{
		Use:     "rm <name>",
		Aliases: []string{"remove", "delete"},
		Short:   "Remove a target profile",
		Args: func(_ *cobra.Command, args []string) error {
			if len(args) != 1 || strings.TrimSpace(args[0]) == "" {
				return validateError("target rm requires exactly one profile name", "run: appcorectl target rm <name>")
			}
			return nil
		},
		RunE: func(cmd *cobra.Command, args []string) error {
			r, err := a.buildRuntime(false)
			if err != nil {
				return err
			}
			name := strings.TrimSpace(args[0])
			if _, ok := r.cfg.Targets[name]; !ok {
				return validateError(fmt.Sprintf("target %q not found", name), "run: appcorectl target ls")
			}

			delete(r.cfg.Targets, name)
			if r.cfg.CurrentTarget == name {
				r.cfg.CurrentTarget = ""
				if len(r.cfg.Targets) > 0 {
					names := make([]string, 0, len(r.cfg.Targets))
					for targetName := range r.cfg.Targets {
						names = append(names, targetName)
					}
					sort.Strings(names)
					r.cfg.CurrentTarget = names[0]
				}
			}
			if err := r.saveConfig(); err != nil {
				return err
			}

			_, _ = fmt.Fprintf(cmd.OutOrStdout(), "Removed target %q from config.\n", name)
			if r.cfg.CurrentTarget != "" {
				_, _ = fmt.Fprintf(cmd.OutOrStdout(), "Current target is now %q.\n", r.cfg.CurrentTarget)
			}

			if !purgePKI {
				_, _ = fmt.Fprintln(cmd.OutOrStdout(), "Local PKI was not removed. Use --purge-pki to delete generated PKI for this target.")
				return nil
			}

			pkiDir, err := security.LocalPKITargetDir(name)
			if err != nil {
				return fmt.Errorf("resolve local PKI directory: %w", err)
			}
			if err := os.RemoveAll(pkiDir); err != nil {
				return fmt.Errorf("remove local PKI directory: %w", err)
			}
			_, _ = fmt.Fprintf(cmd.OutOrStdout(), "Removed local PKI directory %q.\n", pkiDir)
			return nil
		},
	}
	cmd.Flags().BoolVar(&purgePKI, "purge-pki", false, "Also remove generated local PKI directory for this target")
	return cmd
}
