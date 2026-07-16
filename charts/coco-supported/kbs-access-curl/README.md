# kbs-access-curl

Demonstrates KBS secret retrieval using the Confidential Data Hub (CDH) init container pattern. An init container fetches a secret from the KBS via the CDH API and writes it to a shared volume. The main httpd container then serves it.

## How it works

1. Init container `curl` runs inside the confidential VM
2. Fetches secret from CDH: `curl http://127.0.0.1:8006/cdh/resource/default/kbsres1/key3`
3. Writes result to `/var/www/html/secret.txt` (shared emptyDir volume)
4. Main `httpd-24` container serves the file

## Endpoints

| Path | Content |
|------|---------|
| `/` | Default httpd test page (no custom index.html) |
| `/secret.txt` | KBS secret value retrieved by the init container |

## Route

```text
http://kbs-access-curl-kbs-access.apps.<cluster>/secret.txt
```

## Configuration

| Field | Value |
|-------|-------|
| Runtime | `kata-cc` |
| Initdata | `debug-initdata` |
| KBS resource path | `default/kbsres1/key3` |
