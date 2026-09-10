# scripts/

Day-to-day DevOps scripts, organized by area. Drop new scripts into the
matching folder (or add a new one if nothing fits).

| Folder | For |
|---|---|
| `aws/` | AWS CLI / SDK helpers (EC2, S3, IAM, etc.) |
| `kubernetes/` | kubectl/helm helpers, cluster maintenance |
| `docker/` | Image builds, cleanup, registry tasks |
| `ci-cd/` | Pipeline helpers, release/deploy scripts |
| `monitoring/` | Health checks, alerting, log digging |
| `backup/` | Backup/restore/snapshot scripts |
| `utils/` | Anything general-purpose that doesn't fit above |

## Conventions

- **Naming:** `verb-noun.sh` (e.g. `restart-service.sh`, `cleanup-old-images.sh`).
- **Shebang:** start every script with `#!/usr/bin/env bash` and `set -euo pipefail`.
- **Make it executable:** `chmod +x scripts/<area>/<name>.sh`.
- **Header comment:** briefly state what the script does, required env vars/args, and any prerequisites.
- **Secrets:** never hardcode credentials — read from env vars or a secrets manager. Keep any `.env` files out of git (see root `.gitignore`).
- **Idempotency:** prefer scripts that are safe to re-run.

## Running

```bash
./scripts/<area>/<script-name>.sh [args...]
```
