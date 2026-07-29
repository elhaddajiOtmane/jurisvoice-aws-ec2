# Script map

- `ensure-cloudflare-dns.ps1`: creates or updates only the two approved
  DNS-only A records. Requires `CLOUDFLARE_API_TOKEN`; supports `-CheckOnly`
  and PowerShell `-WhatIf`.
- `deploy-platform.ps1`: copies the Bash provisioner over SSH, runs `bash -n`,
  executes it with `sudo`, and removes the remote temporary copy.
- `provision-caprover-n8n.sh`: idempotently configures CapRover domain/HTTPS,
  PostgreSQL, n8n, persistent volumes, and root-only secrets.
- `verify-platform.ps1`: read-only DNS, AWS security-group, Swarm, HTTPS, and
  n8n health verification.

Use these through `run.ps1` for the normal full workflow. Run a child script
directly only when isolating a known phase or diagnosing a failure.
