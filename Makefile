PY ?= python3
SEED ?= 20261022

.PHONY: all starter full repro validate docs test clean

all: docs starter full repro test

starter:
	$(PY) -m rebalance_sim generate --scale starter --seed $(SEED) --out data/starter

full:
	$(PY) -m rebalance_sim generate --scale full --seed $(SEED) --out data/full

repro:
	$(PY) -m rebalance_sim repro --scale starter --seed $(SEED) --out data/starter
	$(PY) -m rebalance_sim repro --scale full --seed $(SEED) --out data/full

validate:
	$(PY) -m rebalance_sim validate --data data/full

docs:
	$(PY) -m rebalance_sim docs

test:
	$(PY) -m unittest discover -s tests -v

clean:
	rm -rf data
