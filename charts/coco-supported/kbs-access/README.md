# Notes use of external image

This chart currently uses an [image hosted on ghcr.io](ghcr.io/butler54/kbs-access-app:latest) built from the [following repository](https://github.com/butler54/coco-kbs-access).

Using separate repository for build rather than integrated content is discouraged by validated patterns.

The separate repository is because Coco (via the Kata guest components) must be served by an image registry using a TLS connection with a well known CA (as of today).

This chart will be updated as that position changes.