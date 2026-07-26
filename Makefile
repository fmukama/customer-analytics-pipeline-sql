# ---------------------------------------------------------------------------
# Inventory & Order Management System - developer CLI
#
# Requirements: Docker + Compose v2.17+, GNU Make, uv.
# A local Python interpreter and a local psql client are NOT required:
#   * SQL is applied by the psql binary already inside the postgres container.
#   * Python tooling runs through `uv run`, which manages its own interpreter.
#
# Run these from Git Bash (recipes use POSIX quoting).
# ---------------------------------------------------------------------------

# .env is optional - docker-compose.yml and the defaults below both cope
# without it. If present, its values win over the ?= defaults.
-include .env
export

# Git Bash (MSYS) rewrites POSIX-looking arguments into Windows paths before
# docker ever sees them, turning `-f /sql/01_schema.sql` into
# `C:/Program Files/Git/sql/01_schema.sql`. This disables that conversion.
# The variable is inert on Linux and macOS.
MSYS_NO_PATHCONV := 1

# uv's cache and this repo can live on different drives on Windows, where
# hardlinking is unsupported; copying removes a warning on every sync.
UV_LINK_MODE := copy

POSTGRES_USER ?= postgres
POSTGRES_DB   ?= ecom_inventory
POSTGRES_PORT ?= 5432
ADMINER_PORT  ?= 8080

DC   := docker compose
UV   := uv run
# -v ON_ERROR_STOP=1 is essential: without it psql reports success even when a
# statement fails, which would silently hide a broken migration.
PSQL := $(DC) exec -T postgres psql -v ON_ERROR_STOP=1 -U $(POSTGRES_USER) -d $(POSTGRES_DB)

.PHONY: help env deps up down destroy restart status logs psql init-db seed \
        reports demo lint fmt test verify all diagrams clean

help:
	@echo "Environment"
	@echo "  make env       - Create .env from .env.example (if missing)"
	@echo "  make deps      - Resolve and install Python deps via uv (writes uv.lock)"
	@echo ""
	@echo "Containers"
	@echo "  make up        - Start PostgreSQL 16 + Adminer, block until healthy"
	@echo "  make down      - Stop containers, KEEP the data volume"
	@echo "  make destroy   - Stop containers and DELETE the data volume"
	@echo "  make restart   - down + up (data preserved)"
	@echo "  make status    - Show container state and health"
	@echo "  make logs      - Tail the PostgreSQL log"
	@echo "  make psql      - Open an interactive psql shell in the container"
	@echo ""
	@echo "Database"
	@echo "  make init-db   - Apply 01_schema, 02_triggers, 03_procedures, 04_views"
	@echo "  make seed      - Populate mock data with Faker (src/seed.py)"
	@echo "  make reports   - Run 05_reports_and_queries.sql"
	@echo "  make demo      - Run 06_demo.sql end-to-end deliverable walkthrough"
	@echo ""
	@echo "Quality"
	@echo "  make lint      - SQLFluff (sql/) + Ruff (src/, tests/)"
	@echo "  make fmt       - Auto-fix SQL and Python style"
	@echo "  make test      - Pytest suite"
	@echo "  make verify    - init-db + seed + test (full green-path check)"
	@echo "  make all       - up + init-db + seed + reports"
	@echo ""
	@echo "Docs"
	@echo "  make diagrams  - Re-render docs/*.puml to PNG (needs Docker only)"
	@echo "  make clean     - Remove caches and log files"

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

env:
	@test -f .env || cp .env.example .env
	@echo ".env is ready."

deps:
	uv sync

# ---------------------------------------------------------------------------
# Containers
# ---------------------------------------------------------------------------

up:
	$(DC) up -d --wait
	@echo ""
	@echo "PostgreSQL -> localhost:$(POSTGRES_PORT)  (db=$(POSTGRES_DB) user=$(POSTGRES_USER))"
	@echo "Adminer    -> http://localhost:$(ADMINER_PORT)"

down:
	$(DC) down

destroy:
	$(DC) down -v

restart: down up

status:
	$(DC) ps

logs:
	$(DC) logs -f postgres

psql:
	$(DC) exec postgres psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

# Each script is applied explicitly rather than in a shell loop so this target
# behaves identically under sh and cmd.exe. Order matters: views depend on
# tables, procedures depend on both.
init-db:
	@echo ">> sql/01_schema.sql"
	$(PSQL) -f /sql/01_schema.sql
	@echo ">> sql/02_triggers.sql"
	$(PSQL) -f /sql/02_triggers.sql
	@echo ">> sql/03_procedures.sql"
	$(PSQL) -f /sql/03_procedures.sql
	@echo ">> sql/04_views.sql"
	$(PSQL) -f /sql/04_views.sql
	@echo "Applied: schema, triggers, procedures, views."

seed:
	$(UV) python -m src.seed

reports:
	$(PSQL) -f /sql/05_reports_and_queries.sql

demo:
	$(PSQL) -f /sql/06_demo.sql

# ---------------------------------------------------------------------------
# Quality
# ---------------------------------------------------------------------------

lint:
	$(UV) sqlfluff lint sql/
	$(UV) ruff check src tests

fmt:
	$(UV) sqlfluff fix sql/
	$(UV) ruff check --fix src tests
	$(UV) ruff format src tests

test:
	$(UV) pytest

verify: init-db seed test

all: up init-db seed reports

# ---------------------------------------------------------------------------
# Docs
# ---------------------------------------------------------------------------

# $(CURDIR) is already an absolute native path, which is what docker -v needs;
# the quotes matter because this repo's path contains an apostrophe.
diagrams:
	docker run --rm -v "$(CURDIR)/docs:/data" plantuml/plantuml \
	    -tpng /data/entity.puml /data/architecture.puml
	@echo "Rendered docs/entity.png and docs/architecture.png"

clean:
	rm -rf .pytest_cache .ruff_cache .sqlfluff_cache __pycache__ \
	       src/__pycache__ tests/__pycache__ logs/*.log
