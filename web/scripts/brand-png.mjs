import puppeteer from 'puppeteer-core'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const brand = join(root, 'public', 'brand')
const fontPath = join(root, 'public', 'fonts', 'fp-latin.woff2')
const chrome =
  process.env.CHROME_PATH ||
  ['/usr/bin/google-chrome-stable', '/usr/bin/google-chrome', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].find((p) => {
    try { return readFileSync(p) || true } catch { return false }
  }) || '/usr/bin/google-chrome'

const browser = await puppeteer.launch({
  executablePath: chrome,
  headless: 'new',
  args: ['--no-sandbox', '--disable-setuid-sandbox', '--proxy-server=direct://', '--proxy-bypass-list=*'],
})
const page = await browser.newPage()
for (const [name, w, h] of [['avatar', 512, 512], ['og', 1200, 630], ['lockup', 704, 160]]) {
  const svg = readFileSync(join(brand, `${name}.svg`), 'utf8')
  await page.setViewport({ width: w, height: h, deviceScaleFactor: 1 })
  await page.setContent(
    `<html><head><style>@font-face{font-family:"FP Latin";src:url("file://${fontPath}") format("woff2")}</style></head><body style="margin:0;background:#080808">${svg.replace('<svg ', `<svg width="${w}" height="${h}" `)}</body></html>`,
  )
  await page.evaluate(() => document.fonts.ready)
  await new Promise((r) => setTimeout(r, 300))
  await page.screenshot({ path: join(brand, `${name}.png`), clip: { x: 0, y: 0, width: w, height: h } })
  console.log('wrote', name, w, h)
}
await browser.close()
console.log('png ok')
