# Inventory & Order Management System

[![CI](https://github.com/fmukama/customer-analytics-pipeline-sql/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/fmukama/customer-analytics-pipeline-sql/actions/workflows/ci.yml)


An inventory and order management database for an e-commerce company, built on **PostgreSQL 16**.
When an order is placed the system automatically deducts stock, applies bulk discounts, calculates
the order total, records the stock movement in an audit log, and re-grades the customer's spending
tier — all inside the database.

Brief: [Inventory-Order-Mgt.md](Inventory-Order-Mgt.md)

---

## What's needed first.

Docker [Docker Desktop](https://www.docker.com/products/docker-desktop/). Everything runs inside
Docker.

---

## Getting started

> **Using Git Bash instead of PowerShell?** Run this one line first, then continue normally:
> ```bash
> export MSYS_NO_PATHCONV=1
> ```
> Git Bash otherwise rewrites the `/sql/...` paths below and the commands fail.

### Step 1 — Create the settings file

<table>
<tr><td><b>PowerShell</b></td><td>

```powershell
Copy-Item .env.example .env
```

</td></tr>
<tr><td><b>Git Bash</b></td><td>

```bash
cp .env.example .env
```

</td></tr>
</table>

### Step 2 — Start the database

```
docker compose up -d --wait
```

First run downloads the images (about a minute). Wait for it to finish — the `--wait` flag holds
until the database is genuinely ready.

**You should see:** `Container ecom_postgres  Healthy`

### Step 3 — Check it is running

```
docker compose ps
```

**You should see:** two containers, `ecom_postgres` and `ecom_adminer`, both marked `healthy`.

### Step 4 — Build the database

commands **one at a time, in this order**. Each one prints what it created.

```
docker compose exec -T postgres psql -U postgres -d ecom_inventory -v ON_ERROR_STOP=1 -f /sql/01_schema.sql
```
```
docker compose exec -T postgres psql -U postgres -d ecom_inventory -v ON_ERROR_STOP=1 -f /sql/02_triggers.sql
```
```
docker compose exec -T postgres psql -U postgres -d ecom_inventory -v ON_ERROR_STOP=1 -f /sql/03_procedures.sql
```
```
docker compose exec -T postgres psql -U postgres -d ecom_inventory -v ON_ERROR_STOP=1 -f /sql/04_views.sql
```

### Step 5 — Watch the whole system work

```
docker compose exec -T postgres psql -U postgres -d ecom_inventory -v ON_ERROR_STOP=1 -f /sql/06_demo.sql
```

This is the guided demonstration. It creates its own sample customers and products, then walks
through every requirement in the brief, printing a narrated before/after at each stage:

1. Stock level before an order
2. An order containing **three different products**, one large enough to earn a bulk discount
3. The discount, the line subtotals and the automatically calculated order total
4. The stock levels after the order, and the matching audit-log entries
5. The low-stock alert now flagging the depleted product
6. Automatic replenishment, and the alert clearing
7. A customer being promoted Bronze → Silver → Gold by their spending
8. An order being cancelled — stock returned, spending and tier corrected

### Step 6 — Run the reports

```
docker compose exec -T postgres psql -U postgres -d ecom_inventory -v ON_ERROR_STOP=1 -f /sql/05_reports_and_queries.sql
```

**You should see:** order summaries per customer, the low-stock reorder report, customer spending by
tier, bulk-discount effectiveness, the full inventory audit trail, top-selling products, and the
performance measurements.

### Step 7 — Look around in the browser (optional)

Open **<http://localhost:8080>** and sign in:

| Field | Value |
|---|---|
| System | `PostgreSQL` |
| Server | `postgres` |
| Username | `postgres` |
| Password | `postgres` |
| Database | `ecom_inventory` |

You can click through the five tables and the two views without writing any SQL.

### Step 8 — Shut down when finished

```
docker compose down
```

**To also erase the stored data, use `docker compose down -v` instead.**

---


**Want to check a view directly? Try:**

```
docker compose exec -T postgres psql -U postgres -d ecom_inventory -c "SELECT * FROM v_order_summary LIMIT 10;"
```
```
docker compose exec -T postgres psql -U postgres -d ecom_inventory -c "SELECT * FROM v_low_stock_alerts;"
```

---

## Shortcuts using MAKEFILE

Must Have [GNU Make](https://www.gnu.org/software/make/) and
[uv](https://docs.astral.sh/uv/) installed, run these from **Git Bash**:

```bash
make help       # list every command
make env        # Step 1
make up         # Step 2
make init-db    # Step 4 (all four scripts)
make demo       # Step 5
make reports    # Step 6
make down       # Step 8

make deps       # install Python tooling (writes uv.lock)
make seed       # add ~50 customers / 20 products / 100 orders of Faker data
make lint       # SQLFluff + Ruff
make test       # pytest suite
make verify     # init-db + seed + test
make psql       # interactive database shell
make diagrams   # re-render docs/*.puml to PNG (needs Docker only)
```

`make seed` is the only step that needs Python, and it is optional — it just adds bulk data so the
performance measurements in Step 6 have a realistic table size to work against.

---

## Testing, fake data & verifying the whole pipeline

### Running the test suite

Requires the developer tooling above (`make`, `uv`) — pytest is Python, so this is not part of the

```bash
make deps   # uv sync - installs pytest, psycopg2-binary, python-dotenv, faker
make up     # containers must be running
make test   # or: uv run pytest
```

**19 tests across four files:**

| File | Proves |
|---|---|
| `tests/test_schema.py` | Every CHECK / UNIQUE / FOREIGN KEY constraint actually rejects bad data |
| `tests/test_triggers.py` | Bulk discounts and tier promotion fire automatically |
| `tests/test_procedures.py` | `sp_place_order` is atomic — rolls back cleanly on insufficient stock, aggregates duplicate line items in one payload; `sp_replenish_stock` and `sp_cancel_order` behave correctly |
| `tests/test_concurrency.py` | **ACID isolation** — two simultaneous orders for the same product are serialized by a row lock: exactly one succeeds, the other is rejected, and stock is never double-deducted or driven negative |

Each test runs inside its own transaction that is rolled back afterward (`tests/conftest.py`), so
tests never interfere with each other or leave data behind. `test_concurrency.py` is the one
exception — proving *real* concurrent behavior needs two connections that actually commit, so it
commits its own rows on a second connection and deletes them again before its assertions run.

**Heads up:** the test session bootstrap re-applies `sql/01_schema.sql`, which starts with
`DROP TABLE ... CASCADE`. Running `make test` after `make demo` or `make seed` wipes that data. If
you want to keep looking at seeded/demo data in Adminer afterward, run `make test` first and
`make demo`/`make seed` last.

### Generating realistic fake data

```bash
make seed
```

Uses [Faker](https://faker.readthedocs.io/) with a fixed random seed (`SEED_RANDOM_STATE` in
`.env`) so the same command produces the same data every time. Volume is configurable in `.env`:

| Variable | Default | Controls |
|---|---|---|
| `SEED_CUSTOMERS_COUNT` | 50 | Customers created |
| `SEED_PRODUCTS_COUNT` | 20 | Products created |
| `SEED_ORDERS_COUNT` | 100 | Orders attempted via `sp_place_order` |

Every order is placed through the real stored procedure, not a raw `INSERT`, so triggers, discounts
and inventory logging all fire exactly as they would for a genuine customer. Requesting 100 orders
against only 20 products routinely exhausts stock mid-run — when that happens the seeder catches
`INSUFFICIENT_STOCK`, calls `sp_replenish_stock()`, and continues; the final log line reports how
many orders actually placed (typically 60-70), which is expected and not an error. Finishes with
`ANALYZE` so the Step 6 performance measurements reflect real statistics rather than an empty table.

### Verifying the whole pipeline end to end

To confirm every piece still works after a change, run in order:

```bash
make destroy && make up      # fresh containers, empty database
make init-db                  # schema + triggers + procedures + views
make lint                     # SQLFluff + Ruff
make test                     # 19 tests: schema, triggers, procedures, concurrency
make seed                     # fake data
make demo                     # end-to-end walkthrough (resets its own prior run first)
make reports                  # insight queries + EXPLAIN plans
```
---
