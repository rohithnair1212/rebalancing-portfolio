# Portfolio Rebalancing Simulation - synthetic dataset, engine and validation harness

> **Educational simulation. Not financial advice.** All data is synthetic: no real tickers, names, prices or personal data.

Compares holdings with each portfolio's target allocation and produces **policy-constrained rebalancing proposals**, with
traceable lifecycle events, a labelled ground truth, an independent validator, and measurable outputs.
Pure Python standard library (3.9+), no installs needed.

## Quick start

```bash
cd rebalance_sim
python -m rebalance_sim generate --scale starter --seed 20261022 --out data/starter   # 100 portfolios, ~1 s
python -m rebalance_sim generate --scale full    --seed 20261022 --out data/full      # 1,000 portfolios, ~3 s
python -m rebalance_sim repro    --scale full    --out data/full                      # regenerate twice, compare checksums
python -m rebalance_sim validate --data data/full                                     # re-run validation on exported files
python -m rebalance_sim docs                                                          # write docs/data_dictionary.md
python -m unittest discover -s tests -v                                               # 9 tests
```

Scale is parameterised, and starter and full use the same generator: `--portfolios --instruments --holdings --days`.
Example: `--instruments 5000` builds a 5,000-instrument universe (1.25 M price rows, ~40 s, ~450 MB).

**Interpretation of "5,000 instruments/holdings":** the full dataset has **5,000 holding rows** across 1,000 portfolios drawn from a
**300-instrument universe** priced on all 250 days. If you read it as a 5,000-instrument universe, use `--instruments 5000`
(validated: 109/109 checks pass).

## What you get (`data/<scale>/`)

| Folder | Contents |
|---|---|
| `csv/`, `json/` | 14 tables (10 core + 4 supporting), identical content in both formats |
| `sql/` | `schema.sql` (DDL with PK/FK/CHECK) and `seed.sql` (loaded into SQLite with FK enforcement, then dumped) |
| `ground_truth/` | `ground_truth.csv/json` - **kept apart from inputs**, never joined into any table |
| `docs/` | `data_dictionary.md/.csv`, `generator_command.txt` |
| `validation/` | `validation_summary.json/.md`, `findings.csv`, `evaluation_metrics.json` |
| `manifest/` | `source_manifest.json` (seed, parameters, provenance, per-file rows + sha256), `checksums.sha256` |
| `reproducibility_report.json` | three runs with the same seed compared file by file |

## Data model

Core entities (as required): InvestorProfile, Portfolio, Instrument, Holding, MarketPrice, TargetAllocation, Trade, FeeSchedule,
Constraint, RebalanceProposal. Supporting: **PortfolioConstraint** (bridge for Portfolio N:M Constraint), **ProposalEvent**
(append-only state history), **DriftSnapshot** (the drift calculation made visible), **PostTradeAllocation** (simulated result).

```
InvestorProfile 1─N Portfolio 1─N Holding N─1 Instrument 1─N MarketPrice
                        │  └─N TargetAllocation (versioned, effective-dated)
                        │  └─N DriftSnapshot
                        ├─N:M─ Constraint   (via PortfolioConstraint)
                        └─N RebalanceProposal 1─N Trade N─1 Instrument
                                   │                   └─N─1 FeeSchedule (optional)
                                   ├─N ProposalEvent       (history, never overwritten)
                                   └─4 PostTradeAllocation
```

Full field-level dictionary (type, required, allowed values, unit, uniqueness, validation rule), cardinalities and lifecycles:
[`docs/data_dictionary.md`](docs/data_dictionary.md).

**IDs** (zero-padded, immutable, identical across files): `INV-000001`, `PORT-INV-000001-01`, `INS-000001`,
`HOLD-PORT-INV-000001-01-INS-000042`, `RB-2026-000001`. Also `TRD-RB-2026-000001-01`, `EVT-000001`, `FEE-000001`, `CON-000001`.

## How the data is generated (parents first, children derived)

1. **Master data**: investors (age-conditioned risk profile, derived risk score, KYC status) -> portfolios (10% of investors own two)
   -> instruments (4 asset classes, 3 liquidity tiers, ADV, lot size, ~3% excluded) -> 250 trading days of prices
   (correlated geometric random walk per asset class) -> versioned target allocations (10% of portfolios have a superseded v1).
2. **Holdings** are sized from the target model plus a drift draw (55% low, 30% medium, 15% high drift), then valued with the
   last observed price. Weights, market values and staleness are *derived*, not drawn.
3. **Policy tables**: tiered `FeeSchedule` (2 versions, 3 notional tiers x 4 classes), `Constraint` rows and the bridge.
4. **Engine** computes drift, plans trades under the policy, prices fees, simulates the post-trade allocation, and runs the lifecycle.
5. **Anomalies are injected last**, on already-valid rows, and every one is written to `ground_truth/`.

Fixed seed `20261022`; every stage uses its own `random.Random(f"{seed}:{stage}")`, so adding a stage cannot shift another.

### Policy rules (all outcomes come from these, none are random)

| Rule | Behaviour |
|---|---|
| Valuation | Last OBSERVED close on/before 2026-10-16 (carry-forward). Older than **3 trading days** => stale, must be flagged |
| Drift | `current weight - target weight` per asset class; breach if `abs(drift) > tolerance band` (4-6 pts equity/bonds by profile, 3 real assets, 2 cash) |
| Trigger | Breach + ACTIVE portfolio => rebalance inside each class, pro rata to existing position values |
| Exception path | Breach + FROZEN portfolio (investor KYC expired) => **BLOCKED** proposal, zero trades |
| Exclusions | Excluded instruments (firm-wide, plus client ESG lists via the bridge) may be **sold, never bought** |
| Min trade | USD 250 equity / 500 bonds and real assets; smaller candidate trades are suppressed and counted |
| Liquidity | Trade <= 10% / 5% / 2% of ADV for HIGH / MEDIUM / LOW tier; capped trades are flagged |
| Trade limits | Lot-size multiples; SELL <= holding; one-way turnover <= 25% |
| Cash | Residual: `cash_after = cash + sells - buys - fees`, kept >= the profile minimum (1-5%) |
| Fees | `max(min_fee, flat + notional x bps / 10000)` from the tier containing the notional |

### Lifecycle rules

`DRAFT -> PENDING_OPS_REVIEW -> [PENDING_COMPLIANCE_REVIEW] -> APPROVED | REJECTED -> CUSTOMER_ACCEPTED | EXPIRED -> EXECUTED_SIMULATED`;
`DRAFT -> BLOCKED`.

* Ops rejects if there are no executable trades or drift falls by < 25%. Otherwise it escalates when any of: stale price used,
  liquidity cap applied, buys+sells > USD 250k, turnover > 20%, no eligible instrument to buy.
* Compliance rejects when stale-price trades exceed 25% of notional; otherwise approves.
* Escalated proposals on portfolios above USD 1M remain `PENDING_COMPLIANCE_REVIEW` (committee backlog).
* Customer accepts when fees <= 0.25% of portfolio value and turnover <= 15%; otherwise the proposal expires. Customers with
  KYC `PENDING` cannot accept, so the proposal stays `APPROVED`.
* Actors: SYSTEM, OPS_ANALYST (`USR-OPS-nnn`), RISK_COMPLIANCE (`USR-CMP-nnn`), CUSTOMER (investor id); the system administrator
  (`USR-ADM-001`) publishes `FeeSchedule` and `Constraint` rows (`created_by`).

## Labelled edge cases and ground truth

The five required anomalies are injected into valid baseline rows. Each touches only the rows it labels.

| `issue_type` | What is injected | Full-run count |
|---|---|---|
| `TARGET_WEIGHTS_NOT_100` | One class target of an ACTIVE, breaching portfolio shifted by +/-3 pts | 20 portfolios |
| `TRADE_EXCEEDS_HOLDING` | A SELL quantity raised 10-60% above the holding | 15 trades |
| `EXCLUDED_INSTRUMENT_RECOMMENDED` | A BUY swapped to a firm-excluded instrument | 15 trades |
| `FEE_OMITTED` | `estimated_fee` and `fee_schedule_id` left null for every trade of a proposal | 75 trades / 20 proposals |
| `STALE_PRICE_UNFLAGGED` | Trade priced 5-9 trading days back with `stale_price_flag = false` | 15 trades |

`ground_truth.csv` has three label categories: `INJECTED_ANOMALY` (with `expected_decision`), `EXPECTED_DECISION` (one per portfolio:
`REBALANCE` / `NO_ACTION` / `BLOCK_FROZEN` / `BLOCK_INVALID_TARGET`, from the documented rules) and `EXPECTED_EXCEPTION` (frozen
portfolios, stale instruments, missing prices, liquidity-capped trades, correctly flagged stale trades). **No input table carries
a label column**; a test asserts this.

## Validation (Step 8) - `validation/validation_summary.md`

109 structural/reconciliation checks, all PASS on both scales: primary keys, natural-key duplicates, ID formats and composition,
foreign keys (every join), required fields, enums, date ordering and effective ranges, price/holding reconciliation (price used = last
observed, market value = qty x price, weights sum to 100%), drift recomputation, trade and proposal arithmetic, **post-trade
allocation recomputed independently from holdings x prices**, fee tiers, lifecycle chains and transitions, trade-status mapping.

The validator reads only the exported CSVs, never in-memory objects or the ground truth. A test corrupts a file and confirms the
validator fails the right checks.

## Evaluation (full run, seed 20261022)

| Area | Result |
|---|---|
| Anomaly detector (rule-based, no ground truth input) vs ground truth | **140 TP, 0 FP, 0 FN** across the 5 issue types |
| Other findings on clean proposals | **0** (turnover/liquidity/min-cash findings appear only on proposals carrying an injected defect) |
| Decision agreement with expected decisions | 98.0%; the 20 mismatches are exactly the invalid-target portfolios that were rebalanced instead of blocked |
| Breaching portfolios | 301 / 1,000 (30.1%) |
| Proposals by status | EXECUTED_SIMULATED 219, REJECTED 34, APPROVED 25, BLOCKED 14, EXPIRED 5, PENDING_COMPLIANCE_REVIEW 4 |
| Mean max drift, before -> after (all rebalanced) | 7.06 -> 4.00 pts; clean proposals reduce drift by 78.6% on average |
| Turnover | median 5.1%, p95 17.1% |
| Mean fee | 21.2 bps of notional; total USD 11.6k |
| Exceptions exercised | 29 stale-flagged trades, 67 liquidity-capped trades, 69 suppressed sub-minimum trades, 14 frozen/blocked, 9 "no eligible buy" cases |

All figures are in `validation/evaluation_metrics.json`.

## Reproducibility (Step 10)

`python -m rebalance_sim repro` generates the dataset three times (the output plus two regenerations in a temp dir) and compares
the sha256 of **all 41 files**; the report is `reproducibility_report.json` (`"identical": true`). Outputs contain no timestamps or
machine paths, and the manifest records a path-independent generator command.

## Provenance and lawful use

No external data was used (`external_data_used: false`). Asset-class buckets, tiered commissions and ADV liquidity caps only inspired
the schema. The dataset has no personal data (no names or contact details) and no real securities. See `manifest/source_manifest.json`.

## Assumptions and limitations

* Single currency (USD); weekday calendar with no exchange holidays; carry-forward valuation for missing prices.
* Cash is the residual and is never traded; BUYs only top up positions already held (except the injected excluded-instrument case).
* Frozen-portfolio proposals are created only when drift breaches, so they document the block.
* Customer, ops and compliance behaviour is rule-driven to keep outcomes explainable, not a model of real people.
* "Weights fail to sum to 100%" is injected on **target** weights; holding weights are derived and always reconcile.

## Layout

```
rebalance_sim/
  params.py      scale presets and parameters      generator.py  master data, prices, targets, holdings, policy
  schema.py      entities -> DDL + data dictionary engine.py     valuation, drift, trade planning, fees, lifecycle
  anomalies.py   labelled edge-case injection      pipeline.py   orchestration + ground truth
  exporter.py    CSV/JSON/SQL/manifest             validate.py   independent checks and findings
  evaluate.py    detector + outcome metrics        cli.py        generate | validate | repro | docs
tests/test_pipeline.py    docs/data_dictionary.md    data/{starter,full}/
```
