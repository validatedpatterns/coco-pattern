# kbs-access-sealed

Demonstrates KBS secret access using a Kubernetes Secret mounted as a volume. The secret is sealed (encrypted) and only decryptable inside the confidential VM via attestation. The httpd container serves the decrypted secret content directly.

## How it works

1. `kbs-sealed-secret` Secret is mounted at `/var/www/html`
2. Each key in the Secret becomes a file in the webroot
3. The `httpd-24` container serves these files

## Endpoints

| Path | Content |
|------|---------|
| `/` | Default httpd test page (Secret files don't include `index.html`) |
| `/secret-key` | Decrypted secret value from `kbs-sealed-secret` |

## Route

```text
https://kbs-access-sealed-kbs-access.apps.<cluster>/secret-key
```

Note: This route uses TLS edge termination with redirect.

## Configuration

| Field | Value |
|-------|-------|
| Runtime | `kata-cc` |
| Initdata | `initdata` (production policy) |
| Secret | `kbs-sealed-secret` (key: `secret-key`) |
