# Sensor Release Gate

**A pipeline that decides whether a runtime security sensor is safe to release.** It installs an eBPF sensor on several Linux environments, runs the same three layers of checks on each (does it start, does it detect attacks, what does it cost in CPU and memory), compares the numbers with a stored baseline, and blocks the release if anything fails or regresses.

This is the day-to-day concern of a validation engineer: not "does it work on my machine", but "does it work on every environment we ship to, and did this build make it worse?"

## What the gate checks

| Layer | Check | Pass condition |
|---|---|---|
| Install | `prerequisites` | Kernel at least 5.4, bpftrace present, root, tracefs available |
| Install | `sensor_start` | `READY` line appears and `/health` returns 200 |
| Functional | `detect_exec` | A shell started by the test is seen as an `execve` event |
| Functional | `detect_open` | A read of `/etc/shadow` is seen as an `openat` event |
| Functional | `detect_connect` | A connection to `203.0.113.10:4444` is seen as a `connect` event |
| Observability | `metrics_endpoint` | `/metrics` reports the events the sensor emitted |
| Performance | `overhead` | Sensor CPU and memory stay under limits while 1,500 processes are spawned |
| Regression | baseline comparison | CPU and memory do not grow more than 25% over the stored baseline |

Policy lives in `gate.yaml`. The release is **blocked** if any environment fails any check, an expected environment reports nothing, or a metric regresses.

## Example gate report

The report has this shape (a failing check in one environment blocks the release):

| Environment | Kernel | prerequisites | sensor_start | detect_exec | detect_open | detect_connect | overhead | metrics_endpoint | CPU % | RSS MB |
|---|---|---|---|---|---|---|---|---|---|---|
| ubuntu-22.04 | 5.15 | ok | ok | ok | ok | ok | ok | ok | measured | measured |
| amazon-linux-2023 | 6.1 | ok | ok | ok | ok | FAIL | ok | ok | measured | measured |

`Sensor release gate: FAIL`, because `detect_connect` failed on amazon-linux-2023.

## What it demonstrates

| Skill | Where it appears |
|---|---|
| Python automation for security testing | `gate/` package: check functions, runner, aggregation, regression logic, CLI |
| eBPF | `sensor/tracer.bt` hooks `execve`, `openat`, `connect`; `sensor/agent.py` runs it and exposes health and metrics |
| Linux and networking | Kernel version handling, tracefs, root privileges, process and socket activity, overhead measurement with `psutil` |
| AWS | `terraform/aws/`: VPC, subnet, security group, one EC2 instance per OS image via `for_each` |
| Azure | `terraform/azure/`: resource group, network, NSG, Ubuntu VM |
| Docker and Kubernetes | `Dockerfile`; `k8s/sensor-daemonset.yaml` with health probe and metrics port |
| Terraform | Multi-environment matrix as code, SSH locked to the operator's IP, IMDSv2, encrypted volumes |
| Grafana | Provisioned dashboard: gate status, CPU and memory per environment, check table |
| CI/CD | GitHub Actions: lint, unit tests, `terraform validate` for both clouds, gate matrix, decision job |

## How it works

```
                 ┌──────────── per environment (ubuntu-22.04, ubuntu-24.04, amazon-linux-2023, azure) ────────────┐
Terraform ─────► │ host ─► sensor.agent (bpftrace + /health + /metrics) ◄── gate run: attacks, load, psutil sampling │
                 └──────────────────────────────────────────────┬─────────────────────────────────────────────────┘
                                                                ▼
                                                    results/<env>.json
                                                                │
                           baseline/baseline.json ─────────────►│
                                                                ▼
                                          gate aggregate ──► PASS / FAIL (exit code)
                                                                │
                                         reports/gate.md, metrics.prom ──► Prometheus ──► Grafana
```

## Project structure

```
├── sensor/               tracer.bt (eBPF) and agent.py (runs it, serves /health and /metrics)
├── gate/                 checks, runner, workload, compare, aggregate, report, cli
├── gate.yaml             release policy: thresholds, tolerance, environment list
├── baseline/             stored baseline metrics per environment
├── terraform/aws/        EC2 matrix across three OS images
├── terraform/azure/      single Ubuntu VM on Azure
├── k8s/                  sensor DaemonSet
├── monitoring/           Prometheus, Grafana provisioning and dashboard
├── scripts/              run_matrix.sh: apply, run, collect, decide, destroy
├── tests/                unit tests and static checks
├── docs/                 architecture, concepts, interview Q and A
└── .github/workflows/    CI
```

## Quick start (this machine)

Requirements: Linux, root access, `bpftrace`, Python 3.10+.

```bash
git clone <this-repo-url> && cd sensor-release-gate
make setup && source .venv/bin/activate
make test                  # unit tests, no eBPF needed

make gate                  # run every check here (uses sudo)
make baseline              # store these numbers as the baseline
make aggregate             # PASS or FAIL decision, report in reports/gate.md
```

`make aggregate` exits with status 1 when the release is blocked, so it can gate a pipeline directly.

## Run the full environment matrix

```bash
CLOUD=aws KEY=$HOME/.ssh/id_ed25519 MY_CIDR=<your-ip>/32 REPO_URL=https://github.com/<owner>/sensor-release-gate.git \
  ./scripts/run_matrix.sh
```

The script applies Terraform, waits for every host to finish installing, runs the gate over SSH on each one, copies the results back, runs the aggregate decision, and always runs `terraform destroy` on exit (including on failure). Use `CLOUD=azure` for the Azure VM. Results are written to `results/` and `reports/`.

## Dashboard

```bash
make monitoring            # Grafana on :3000, Prometheus on :9090
make serve                 # exposes reports/metrics.prom to Prometheus on :9106
```

## Kubernetes

```bash
docker build -t release-gate-sensor .
kind load docker-image release-gate-sensor
kubectl apply -f k8s/sensor-daemonset.yaml
```

The DaemonSet runs the sensor on every node, with a readiness probe on `/health` and the metrics port exposed.

## Design decisions

- **Same checks everywhere.** Each environment runs identical checks, so a difference in result points at the OS or kernel rather than the test.
- **Pure check functions.** `gate/checks.py` takes facts as arguments (kernel string, events, metrics) and returns results, so the logic is fully unit tested without eBPF.
- **Decision separated from measurement.** `run` always records what happened; `aggregate` decides. Environments can be measured independently and combined later.
- **Regression needs two conditions.** A metric must grow past the percentage tolerance and by a small absolute amount, so noise on tiny numbers does not block a release.
- **Missing results block the release.** With `--require`, an environment that never reported counts as a failure, not as a pass.
- **Teardown is guaranteed.** The matrix script destroys infrastructure from an exit trap.
- **Secure-by-default infrastructure.** SSH only from one IP, IMDSv2, encrypted volumes, and Terraform validation that rejects `0.0.0.0/0`.

## Verification status

| Part | How it is verified |
|---|---|
| Check functions, regression logic, aggregation, reports, CLI exit codes, agent metrics format | 21 unit tests in CI |
| YAML, Grafana JSON, DaemonSet, Terraform layout and guardrails | Static tests in CI, plus `terraform validate` for AWS and Azure |
| eBPF sensor, load measurement, matrix run on AWS and Azure, Kubernetes | Run manually; they need a Linux kernel, root and a cloud account |

The `gate` CI job tries the real gate on GitHub-hosted Ubuntu runners but is allowed to fail, because eBPF permissions on hosted runners can vary.

## Known limitations

- Overhead is measured as the CPU and memory of the `bpftrace` process during an `execve` burst; it is a comparison tool between builds and environments, not a production capacity figure.
- Only IPv4 `connect` events are captured.
- Baselines are a single stored sample per environment. A rolling window would be more robust against noisy hosts.
- Hosts clone the repository over HTTPS, so it must be reachable from the instances.

## Roadmap

- GCP Terraform module for a third cloud
- Rolling-window baselines
- Per-kernel matrix on a fixed set of kernel versions
- Push results to Prometheus Pushgateway from CI

## License

MIT
