# JurisVoice AWS, CapRover, and n8n runbook

This project safely recreates and verifies the isolated JurisVoice hosting
platform. Codex should begin with `AGENTS.md`; durable design, rules, recovery
notes, and external-service behavior live under `foundational/`.

## Completed deployment

Last verified on 2026-07-29:

- AWS EC2 `i-070e7abf714b6ad41`, Ubuntu 24.04, `c7i-flex.xlarge`,
  4 vCPU/8 GiB, encrypted 80-GiB gp3, public IP `100.25.248.197`.
- CapRover 1.14.2 at `https://captain.apps.jurisvoice.com`.
- n8n 2.32.6 with PostgreSQL 16 at `https://n8n.jurisvoice.com`.
- Let’s Encrypt notices use `contact@jurisvoice.com`.
- Cloudflare has DNS-only A records for `*.apps.jurisvoice.com` and
  `n8n.jurisvoice.com`.
- The existing JurisVoice/Vercel/email DNS and client `/dashboard` were not
  changed.

Treat IDs, IPs, DNS, and health as a historical snapshot. Verify live before
reporting the current state.

## Normal use

Open PowerShell:

```powershell
cd C:\laragon\www\aws-ec2
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run.ps1
```

The default run safely reconciles the EC2 instance, ingress, SSH alias, and
state file. If AWS authentication expired, finish the official browser
sign-in/MFA flow.

To perform the complete sequence after connecting AWS and Cloudflare:

```powershell
$env:CLOUDFLARE_API_TOKEN = Read-Host 'Cloudflare scoped API token'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run.ps1 `
  -EnsureCloudflareDns -ProvisionPlatform -VerifyPlatform
Remove-Item Env:\CLOUDFLARE_API_TOKEN
```

The token must be scoped to Zone read plus DNS read/edit for
`jurisvoice.com`. The script will modify only the two isolated A records and
will stop on duplicates or ambiguity. Rotate any token previously posted in
chat before using it.

Useful commands:

```powershell
.\status.ps1
.\scripts\verify-platform.ps1
ssh server
.\connect.ps1
```

Run EC2 reconciliation without the live SSH test:

```powershell
.\run.ps1 -SkipSshTest
```

Pin/redeploy only the configured n8n image:

```powershell
.\scripts\deploy-platform.ps1 -PinN8nOnly
```

## What `run.ps1` guarantees

1. Authenticates through AWS CLI browser login and MFA.
2. Selects the instance using both required tags and stops on duplicates.
3. Creates the managed server only if none exists.
4. Enforces instance size, encrypted storage, IMDSv2, and health.
5. Restricts SSH to the current public IPv4 `/32`.
6. Opens only HTTP/HTTPS publicly and removes legacy all-protocol ingress.
7. Updates the managed `ssh server` block and `state/current.json`.
8. Optionally reconciles DNS, provisions CapRover/n8n, and verifies the stack.

It never terminates an instance, deletes a volume/key pair, or exposes
CapRover port 3000.

## Credentials and recovery

No cloud key, token, password, or private key belongs in this directory.

- SSH private key: `C:\Users\adam\.ssh\aws-ubuntu-server-1`.
- n8n owner login: 1Password Personal vault item `JurisVoice n8n`.
- Root-only server secrets are listed, without values, in
  `foundational/rules/operations.md`.
- Prior failure signatures and exact safe recovery steps are in
  `foundational/rules/recovery.md`.

Retrieve a server credential only in an interactive SSH session, use it, and
clear the terminal if needed. Do not paste it into source, logs, state, memory,
or a future chat.

## Validation for changes

PowerShell syntax:

```powershell
$bad = $false
Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object {
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile(
    $_.FullName, [ref]$tokens, [ref]$errors
  )
  if ($errors.Count) { $bad = $true; $errors }
}
if ($bad) { throw 'PowerShell syntax validation failed.' }
```

The deployment wrapper validates the Bash provisioner with `bash -n` before
executing it. End every infrastructure change with
`.\scripts\verify-platform.ps1`.
