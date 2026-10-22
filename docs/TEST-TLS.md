# TEST TLS · 45.78.200.239

Self-signed cert (no hostname / no Let's Encrypt on bare IP).

```bash
# smoke
curl -skI https://45.78.200.239/ | head
curl -sI  http://45.78.200.239/  | head   # HTTP kept

# cert files on VPS
# /etc/nginx/ssl/gang-test.crt
# /etc/nginx/ssl/gang-test.key
```

Browser will warn (untrusted). Prefer attaching a test hostname + certbot later.
HTTP :80 remains for existing bookmarks / agents.
