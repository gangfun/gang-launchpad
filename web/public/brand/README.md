# Gang brand pack

Pixel GANG mark (6×7 grid letters). Soft-launch assets for site + X.

| File | Use |
|---|---|
| `avatar.png` / `avatar.svg` | **X / social avatar**, site favicon apple-touch, Topbar/Footer/Sidebar mark (512×512, yellow `#FCD535` plate) |
| `lockup.png` / `lockup.svg` | Horizontal wordmark lockup (704×160) |
| `mark.svg` | Bare pixel GANG wordmark (no plate), UI inline / favicon source sibling |
| `og.png` / `og.svg` | Open Graph / link preview (1200×630) |

Root `/favicon.svg` is the single-letter G plate used by `index.html`.

Regenerate PNGs from SVG:

```bash
node web/scripts/brand-png.mjs
```
