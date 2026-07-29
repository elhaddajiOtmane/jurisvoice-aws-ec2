# External services and API behavior

## AWS

- Authentication: AWS CLI v2 browser login using profile `codex-admin`.
- Selector: both `Name=ubuntu-server-1` and `Project=codex-ubuntu`.
- Region: `us-east-1`.
- The automation refreshes SSH ingress to the operator's current `/32`.

## Cloudflare

- Authentication: scoped API token from environment variable
  `CLOUDFLARE_API_TOKEN`.
- Token needs Zone DNS read/edit and Zone read for `jurisvoice.com`.
- Verify the token, resolve exactly one zone, and fail on duplicate matching
  records.
- Allowed writes: only `*.apps.jurisvoice.com` and `n8n.jurisvoice.com`.
- Required values: type A, current EC2 IP, `proxied=false`, TTL auto.

## CapRover

- API root: `https://captain.apps.jurisvoice.com/api/v2`.
- Required headers after login: `x-namespace: captain` and
  `x-captain-auth: <short-lived login token>`.
- The provisioner reads the admin password from a root-only server file and
  unsets the temporary API token.

## n8n

- Public URL: `https://n8n.jurisvoice.com`.
- Health endpoint: `/healthz`.
- Owner email: `contact@jurisvoice.com`.
- Owner credential is stored in 1Password, not this project.
