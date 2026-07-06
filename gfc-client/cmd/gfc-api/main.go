package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"

	"github.com/278946647/sip-proxy/gfc-client/internal/api"
	"github.com/278946647/sip-proxy/gfc-client/internal/config"
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

	mode := os.Getenv("GFC_WEB_MODE")
	if mode == "" {
		mode = "api"
	}
	switch mode {
	case "both":
		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			runListener(cfg, st, cfg.WebPort, "admin")
		}()
		go func() {
			defer wg.Done()
			runListener(cfg, st, cfg.FlashPort, "flash")
		}()
		wg.Wait()
	case "flash":
		runListener(cfg, st, cfg.FlashPort, "flash")
	case "admin":
		// Legacy: Vue SPA; use api + LuCI on new deployments.
		runListener(cfg, st, cfg.WebPort, "admin")
	default:
		runListener(cfg, st, cfg.WebPort, "api")
	}
}

func runListener(cfg *config.Config, st *store.Store, port int, mode string) {
	srv := api.NewServer(cfg, st, mode)
	addr := fmt.Sprintf("0.0.0.0:%d", port)
	log.Printf("gfc-api mode=%s http://%s", mode, addr)
	if err := http.ListenAndServe(addr, srv.Router()); err != nil {
		log.Fatalf("listen %s: %v", addr, err)
	}
}
