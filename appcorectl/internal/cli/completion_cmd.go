package cli

import (
	"fmt"

	"github.com/spf13/cobra"
)

func (a *app) newCompletionCommand(root *cobra.Command) *cobra.Command {
	return &cobra.Command{
		Use:   "completion [bash|zsh|fish]",
		Short: "Generate shell completion script",
		Args: func(_ *cobra.Command, args []string) error {
			if len(args) != 1 {
				return validateError("completion requires exactly one shell", "choose one: bash, zsh, fish")
			}
			return nil
		},
		RunE: func(cmd *cobra.Command, args []string) error {
			shell := args[0]
			switch shell {
			case "bash":
				return root.GenBashCompletion(cmd.OutOrStdout())
			case "zsh":
				return root.GenZshCompletion(cmd.OutOrStdout())
			case "fish":
				return root.GenFishCompletion(cmd.OutOrStdout(), true)
			default:
				return validateError(fmt.Sprintf("unsupported shell %q", shell), "choose one: bash, zsh, fish")
			}
		},
	}
}
