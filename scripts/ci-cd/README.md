# ci-cd/

## check-jenkins-health.sh

Health check for a Jenkins controller. One-shot: it checks, logs, and exits
with a status code — no daemon to keep alive.

**Checks:** reachability and response time, authenticated API access,
quiet-down mode, executor capacity, agent/node online state, per-node free
disk and temp space, agent round-trip latency, build queue depth, stuck and
long-waiting queue items, and the Metrics plugin healthchecks when a key is
configured.

**Exit codes:** `0` healthy, `1` warnings, `2` critical, `3` config error —
so it drops straight into any alerting system that reads exit status.

### Setup

```bash
cp .env.example .env      # at the repo root
chmod 600 .env            # credentials — keep them to yourself
```

Fill in `JENKINS_URL`, `JENKINS_USER`, and `JENKINS_API_TOKEN` (generate the
token in Jenkins under *your user > Security > API Token* — use a token, not
your password). `.env` is gitignored.

### Run

```bash
./scripts/ci-cd/check-jenkins-health.sh              # findings only
./scripts/ci-cd/check-jenkins-health.sh --verbose    # every check, including OK
./scripts/ci-cd/check-jenkins-health.sh --quiet      # silent unless something is wrong
./scripts/ci-cd/check-jenkins-health.sh --no-log     # stdout only, don't touch the log
```

Every run appends all results to
`scripts/ci-cd/logs/jenkins-health-YYYY-MM-DD.log`, healthy runs included, so
there's a history to look back through.

### Thresholds

Defaults live in the script header and are all overridable from `.env`:
`QUEUE_WARN` (10), `QUEUE_CRIT` (25), `QUEUE_AGE_WARN_MIN` (30),
`RESPONSE_WARN_MS` (3000), `DISK_WARN_GB` (5).

An agent that is **offline unexpectedly** is CRITICAL; one marked
*temporarily offline* (someone took it down deliberately) is only a warning.

## Scheduling it every 5 minutes (macOS)

`launchd/com.devopsautomate.jenkinshealth.plist` runs the check every 300
seconds with `--quiet`. Set up `.env` first, or every run will exit 3.

```bash
cp launchd/com.devopsautomate.jenkinshealth.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.devopsautomate.jenkinshealth.plist
```

Manage it:

```bash
launchctl list | grep jenkinshealth                                    # is it loaded
launchctl kickstart -p gui/$(id -u)/com.devopsautomate.jenkinshealth   # run now
launchctl bootout gui/$(id -u)/com.devopsautomate.jenkinshealth        # stop
```

Because of `--quiet`, `logs/launchd.log` only collects actual problems and
startup errors — it stays empty while Jenkins is healthy. Paths in the plist
are absolute and machine-specific; update them if you move the repo.

Note: launchd agents only run while you're logged in. For genuine
round-the-clock monitoring, run this from a server (plain cron) or point your
existing monitoring system at the script's exit code.
