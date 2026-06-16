package main

import (
	"fmt"
	"log"
	"os"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/dataplane"
	"github.com/278946647/sip-proxy/gfc-client/internal/store"
)

func main() {
	cfg := config.Load()
	if err := cfg.EnsureDirs(); err != nil {
		log.Fatal(err)
	}
	st, err := store.Open(cfg.Paths.DBFile)
	if err != nil {
		log.Fatal(err)
	}
	defer st.Close()

	engine := dataplane.New(cfg)
	if len(os.Args) > 1 && os.Args[1] == "--reapply" {
		ok, msg := engine.ReapplyLocal(true)
		if !ok {
			fmt.Fprintf(os.Stderr, "reapply failed: %s\n", msg)
			os.Exit(1)
		}
		fmt.Println(msg)
		return
	}

	ok, msg := engine.BootstrapIdle()
	if !ok {
		fmt.Fprintf(os.Stderr, "bootstrap failed: %s\n", msg)
		os.Exit(1)
	}
	fmt.Println(msg)
}
