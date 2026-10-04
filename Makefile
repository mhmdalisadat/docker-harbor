SHELL := /bin/bash
.DEFAULT_GOAL := help

S := scripts

.PHONY: help init setup prepare deploy up down restart status ps logs pull backup restore \
        traefik-config update-upstream config lint

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

init: ## Create .env from .env.example (never overwrites)
	@if [ -f .env ]; then echo ".env already exists"; else cp .env.example .env && chmod 600 .env && echo "created .env — edit it, then: make deploy"; fi

setup: ## Validate .env, generate secrets, render harbor.yml, run prepare if needed (no containers touched)
	@bash $(S)/setup.sh

prepare: ## Like setup, but always re-run Harbor's prepare
	@bash $(S)/setup.sh --force

deploy: ## setup + pull + start/update + healthcheck
	@bash $(S)/deploy.sh

up: deploy ## Alias for deploy

down: ## Stop and remove the containers (DATA_DIR is kept)
	docker compose down --remove-orphans

restart: ## Restart all containers
	docker compose restart

status: ## Healthcheck (pass ARGS=--local to skip the public URL check)
	@bash $(S)/healthcheck.sh 60 $(ARGS)

ps: ## Container status
	docker compose ps -a

logs: ## Follow logs (SERVICE=core to filter); files are also in LOG_DIR
	docker compose logs -f --tail=200 $(SERVICE)

pull: ## Pull the pinned images
	docker compose pull

backup: ## Archive .env + database dump + secret (+ registry with BACKUP_REGISTRY=1) into BACKUP_DIR
	@bash $(S)/backup.sh

restore: ## Restore from FILE=backups/harbor-....tar.gz
	@bash $(S)/restore.sh "$(FILE)"

traefik-config: ## Print a Traefik file-provider route (for a swarm-only Traefik)
	@bash $(S)/traefik-config.sh

update-upstream: ## Pin another Harbor release: [VERSION=vX.Y.Z] (default: latest)
	@bash $(S)/update-upstream.sh $(VERSION)

config: ## Print the effective compose configuration
	docker compose config

lint: ## shellcheck the scripts (via docker)
	docker run --rm -v "$(CURDIR):/mnt" -w /mnt koalaman/shellcheck:stable -x $(S)/*.sh
