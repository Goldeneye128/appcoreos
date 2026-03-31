package cli

import (
	"context"
	"fmt"
	"net/url"
	"strconv"
	"strings"

	"github.com/spf13/cobra"
)

func (a *app) newInfoCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "info",
		Short: "Get appliance info",
		RunE: func(cmd *cobra.Command, _ []string) error {
			return a.runReadCommand(cmd, "/v1/info", nil)
		},
	}
}

func (a *app) newStateCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "state",
		Short: "Get appliance state",
		RunE: func(cmd *cobra.Command, _ []string) error {
			return a.runReadCommand(cmd, "/v1/state", nil)
		},
	}
}

func (a *app) newServicesCommand() *cobra.Command {
	cmd := &cobra.Command{Use: "services", Aliases: []string{"service"}, Short: "Manage services"}
	cmd.AddCommand(
		&cobra.Command{
			Use:   "list",
			Short: "List services",
			RunE: func(cmd *cobra.Command, _ []string) error {
				return a.runReadCommand(cmd, "/v1/services", nil)
			},
		},
		&cobra.Command{
			Use:   "get <unit>",
			Short: "Get service details",
			Args: func(_ *cobra.Command, args []string) error {
				if len(args) != 1 || strings.TrimSpace(args[0]) == "" {
					return validateError("services get requires one unit name", "run: appcorectl services get nginx.service")
				}
				return nil
			},
			RunE: func(cmd *cobra.Command, args []string) error {
				unit := url.PathEscape(strings.TrimSpace(args[0]))
				return a.runReadCommand(cmd, "/v1/services/"+unit, nil)
			},
		},
		a.newServiceRestartCommand(),
	)
	return cmd
}

func (a *app) newServiceRestartCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "restart <unit>",
		Short: "Restart a service",
		Args: func(_ *cobra.Command, args []string) error {
			if len(args) != 1 || strings.TrimSpace(args[0]) == "" {
				return validateError("services restart requires one unit name", "run: appcorectl services restart nginx.service")
			}
			return nil
		},
		RunE: func(cmd *cobra.Command, args []string) error {
			r, err := a.buildRuntime(true)
			if err != nil {
				return err
			}
			c, err := r.newClient()
			if err != nil {
				return err
			}
			unit := url.PathEscape(strings.TrimSpace(args[0]))
			if err := runPost(context.Background(), c, "/v1/services/"+unit+"/restart", map[string]any{}); err != nil {
				return err
			}
			_, _ = fmt.Fprintf(cmd.OutOrStdout(), "Service %q restart requested.\n", args[0])
			return nil
		},
	}
}

func (a *app) newContainersCommand() *cobra.Command {
	cmd := &cobra.Command{Use: "containers", Aliases: []string{"container"}, Short: "Manage containers"}
	cmd.AddCommand(
		&cobra.Command{
			Use:   "list",
			Short: "List containers",
			RunE: func(cmd *cobra.Command, _ []string) error {
				return a.runReadCommand(cmd, "/v1/containers", nil)
			},
		},
		a.newContainerLogsCommand(),
	)
	return cmd
}

func (a *app) newContainerLogsCommand() *cobra.Command {
	var tail int
	cmd := &cobra.Command{
		Use:   "logs <name>",
		Short: "Read container logs",
		Args: func(_ *cobra.Command, args []string) error {
			if len(args) != 1 || strings.TrimSpace(args[0]) == "" {
				return validateError("containers logs requires one container name", "run: appcorectl containers logs <name> --tail 200")
			}
			if tail <= 0 {
				return validateError("--tail must be greater than 0", "use a positive integer, e.g. --tail 200")
			}
			return nil
		},
		RunE: func(cmd *cobra.Command, args []string) error {
			query := url.Values{"tail": []string{strconv.Itoa(tail)}}
			name := url.PathEscape(strings.TrimSpace(args[0]))
			return a.runReadTextCommand(cmd, "/v1/containers/"+name+"/logs", query)
		},
	}
	cmd.Flags().IntVar(&tail, "tail", 200, "Tail line count")
	return cmd
}

func (a *app) newLogsCommand() *cobra.Command {
	cmd := &cobra.Command{Use: "logs", Short: "Read host logs"}
	var tail int
	var unit string
	journal := &cobra.Command{
		Use:   "journal",
		Short: "Read journal logs",
		Args: func(_ *cobra.Command, _ []string) error {
			if tail <= 0 {
				return validateError("--tail must be greater than 0", "use a positive integer, e.g. --tail 200")
			}
			return nil
		},
		RunE: func(cmd *cobra.Command, _ []string) error {
			query := url.Values{"tail": []string{strconv.Itoa(tail)}}
			if strings.TrimSpace(unit) != "" {
				query.Set("unit", strings.TrimSpace(unit))
			}
			return a.runReadTextCommand(cmd, "/v1/logs/journal", query)
		},
	}
	journal.Flags().IntVar(&tail, "tail", 200, "Tail line count")
	journal.Flags().StringVar(&unit, "unit", "", "Filter by systemd unit")
	cmd.AddCommand(journal)
	return cmd
}

func (a *app) newNetworkCommand() *cobra.Command {
	cmd := &cobra.Command{Use: "network", Short: "Inspect network state"}
	cmd.AddCommand(&cobra.Command{
		Use:   "interfaces",
		Short: "List network interfaces",
		RunE: func(cmd *cobra.Command, _ []string) error {
			return a.runReadCommand(cmd, "/v1/network/interfaces", nil)
		},
	})
	return cmd
}

func (a *app) newHostCommand() *cobra.Command {
	cmd := &cobra.Command{Use: "host", Short: "Host lifecycle operations"}
	cmd.AddCommand(
		&cobra.Command{
			Use:   "update-status",
			Short: "Get update status",
			RunE: func(cmd *cobra.Command, _ []string) error {
				return a.runReadCommand(cmd, "/v1/host/update-status", nil)
			},
		},
		&cobra.Command{
			Use:   "update",
			Short: "Trigger host update",
			RunE: func(cmd *cobra.Command, _ []string) error {
				r, err := a.buildRuntime(true)
				if err != nil {
					return err
				}
				c, err := r.newClient()
				if err != nil {
					return err
				}
				if err := runPost(context.Background(), c, "/v1/host/update", map[string]any{}); err != nil {
					return err
				}
				_, _ = fmt.Fprintln(cmd.OutOrStdout(), "Host update requested.")
				return nil
			},
		},
		a.newHostRebootCommand(),
	)
	return cmd
}

func (a *app) newHostRebootCommand() *cobra.Command {
	var yes bool
	cmd := &cobra.Command{
		Use:   "reboot",
		Short: "Reboot host",
		Args: func(_ *cobra.Command, _ []string) error {
			if !yes {
				return validateError("host reboot requires --yes", "run: appcorectl host reboot --yes")
			}
			return nil
		},
		RunE: func(cmd *cobra.Command, _ []string) error {
			r, err := a.buildRuntime(true)
			if err != nil {
				return err
			}
			c, err := r.newClient()
			if err != nil {
				return err
			}
			if err := runPost(context.Background(), c, "/v1/host/reboot", map[string]any{}); err != nil {
				return err
			}
			_, _ = fmt.Fprintln(cmd.OutOrStdout(), "Host reboot requested.")
			return nil
		},
	}
	cmd.Flags().BoolVar(&yes, "yes", false, "Confirm reboot action")
	return cmd
}

func (a *app) runReadCommand(cmd *cobra.Command, path string, query url.Values) error {
	r, err := a.buildRuntime(true)
	if err != nil {
		return err
	}
	c, err := r.newClient()
	if err != nil {
		return err
	}
	payload, err := runGet(context.Background(), c, path, query)
	if err != nil {
		return err
	}
	return printRead(cmd, r.output, payload)
}

func (a *app) runReadTextCommand(cmd *cobra.Command, path string, query url.Values) error {
	r, err := a.buildRuntime(true)
	if err != nil {
		return err
	}
	c, err := r.newClient()
	if err != nil {
		return err
	}
	payload, err := c.GetText(context.Background(), path, query, nil)
	if err != nil {
		return err
	}
	if _, err := fmt.Fprint(cmd.OutOrStdout(), payload); err != nil {
		return err
	}
	if !strings.HasSuffix(payload, "\n") {
		_, _ = fmt.Fprintln(cmd.OutOrStdout())
	}
	return nil
}
