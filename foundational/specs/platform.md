# JurisVoice platform specification

## Managed infrastructure

- AWS profile: `codex-admin`, with browser authentication and MFA.
- Region/AZ: `us-east-1` / `us-east-1a`.
- EC2 identity: tags `Name=ubuntu-server-1` and `Project=codex-ubuntu`.
- Last verified instance: `i-070e7abf714b6ad41`, public IP `100.25.248.197`.
- Compute: Ubuntu 24.04, `c7i-flex.xlarge`, 4 vCPU, 8 GiB RAM.
- Disk: encrypted 80-GiB gp3 root volume; IMDSv2 required.

The instance ID and public IP are historical anchors, not selectors. Always
resolve the instance from both required tags and stop if more than one matches.

## Network contract

- TCP 22: current operator public IPv4 `/32` only.
- TCP 80 and 443: `0.0.0.0/0`.
- TCP 3000: never public.
- No all-protocol public ingress.
- Cloudflare records stay DNS-only unless a reviewed change is approved.

## DNS contract

- `*.apps.jurisvoice.com` A -> current EC2 public IP.
- `n8n.jurisvoice.com` A -> current EC2 public IP.
- Do not change apex, `www`, `app`, Vercel verification, MX, SPF, DKIM, DMARC,
  Resend, or other existing JurisVoice records.

## Application contract

- CapRover: `https://captain.apps.jurisvoice.com`.
- n8n: `https://n8n.jurisvoice.com`.
- Let’s Encrypt notice email: `contact@jurisvoice.com`.
- n8n image: `docker.n8n.io/n8nio/n8n:2.32.6`.
- PostgreSQL image: `postgres:16`.
- Persistent volumes: `captain--n8n-data` and
  `captain--n8n-postgres-data`.

## Acceptance checks

- AWS reports one healthy matching instance with the expected type and AZ.
- SSH works through alias `server`.
- Swarm services `captain-captain`, `captain-certbot`, `captain-nginx`,
  `srv-captain--n8n`, and `srv-captain--n8n-postgres` are each `1/1`.
- Both public HTTP endpoints redirect to HTTPS.
- Both HTTPS endpoints respond successfully.
- `https://n8n.jurisvoice.com/healthz` returns `{"status":"ok"}`.
- External TCP 3000 is closed.
