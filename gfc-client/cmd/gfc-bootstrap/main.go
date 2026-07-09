package main

import (
	"fmt"
	"log"
	"os"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/dataplane"
	"github.com/278946647/sip-proxy/gfc-client/internal/network"
	"github.com/278946647/sip-proxy/gfc-client/internal/reversessh"
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
	if len(os.Args) > 1 && os.Args[1] == "--rollback-network" {
		result, err := network.New(cfg).RollbackNetwork()
		if err != nil {
			fmt.Fprintf(os.Stderr, "rollback network failed: %s\n", err)
			os.Exit(1)
		}
		fmt.Printf("%v\n", result)
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "--apply-network" {
		result, err := network.New(cfg).ApplyNetwork()
		if err != nil {
			fmt.Fprintf(os.Stderr, "apply network failed: %s\n", err)
			os.Exit(1)
		}
		reversessh.RequestRestoreAfterNetwork()
		if ok, msg := reversessh.New(cfg).RestoreAfterNetwork(); msg != "" {
			fmt.Printf("reverse ssh restore: %s (ok=%v)\n", msg, ok)
		}
		fmt.Printf("%v\n", result)
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "--reapply" {
		ok, msg := engine.ReapplyLocal(true)
		if !ok {
			fmt.Fprintf(os.Stderr, "reapply failed: %s\n", msg)
			os.Exit(1)
		}
		fmt.Println(msg)
		return
	}

	ok, msg := engine.ReapplyLocal(false)
	if !ok {
		fmt.Fprintf(os.Stderr, "bootstrap failed: %s\n", msg)
		os.Exit(1)
	}
	fmt.Println(msg)
}
