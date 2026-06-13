package main

import (
	"log"

	"github.com/278946647/sip-proxy/gfc-client/internal/agent"
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
	log.Printf("gfc-agent v%s starting poll=%ds", config.Version, cfg.PollSeconds)
	agent.NewRunner(cfg, st).Run()
}
