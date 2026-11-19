.PHONY: setup lint test gate aggregate baseline monitoring serve clean

setup:
	python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt

lint:
	ruff check .

test:
	pytest -v

# Run the gate on THIS machine (needs root, bpftrace, Linux)
gate:
	mkdir -p results
	sudo $$(which python3) -m gate.cli run --env local --out results/local.json

# Decide pass/fail from collected results
aggregate:
	python3 -m gate.cli aggregate --results results/*.json --baseline baseline/baseline.json --out reports

# Store current results as the new baseline
baseline:
	python3 -m gate.cli baseline --results results/*.json --out baseline/baseline.json

monitoring:
	docker compose -f monitoring/docker-compose.yml up -d

serve:
	python3 -m gate.cli serve --metrics reports/metrics.prom --port 9106

clean:
	rm -rf results reports/*.md reports/*.json reports/*.prom
