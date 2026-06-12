# GFC control plane — use gfc-compose instead of raw docker-compose.
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
GFC_COMPOSE := bash $(ROOT)/deploy/control/gfc-compose.sh

.PHONY: up down build ps logs repair upgrade-web upgrade redeploy-web

up:
	$(GFC_COMPOSE) up -d

down:
	$(GFC_COMPOSE) down

build:
	$(GFC_COMPOSE) build

ps:
	$(GFC_COMPOSE) ps

logs:
	$(GFC_COMPOSE) logs -f --tail=100

repair:
	sudo bash $(ROOT)/deploy/control/repair-control.sh

upgrade:
	sudo bash $(ROOT)/deploy/control/upgrade-control.sh

redeploy-web:
	sudo bash $(ROOT)/deploy/control/redeploy-web.sh

upgrade-web: redeploy-web
