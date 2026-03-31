package main

import (
	"os"

	"github.com/appcoreos/appcorectl/internal/cli"
)

func main() {
	os.Exit(cli.Execute())
}
