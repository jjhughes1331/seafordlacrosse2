# seafordlacrosse2

Website for seafordlax.com (Seaford Lacrosse). Static single-page HTML site.

## Structure
- `index.html` — the entire site (markup, styles, script all in one file)
- `manifest.json`, `sw.js` — PWA support (installable / offline)
- `icon-*.png`, `apple-touch-icon.png` — app icons
- `seaford-*.jpg/png` — team logos/photos used on the page
- `CNAME` — custom domain config for GitHub Pages (seafordlax.com)
- `.nojekyll` — tells GitHub Pages not to run Jekyll processing

## Hosting
Deployed via **GitHub Pages** from this repo's `main` branch. Any push to `main`
auto-deploys to seafordlax.com within a minute or two. No build step, no
separate hosting account.

## Workflow
Edit `index.html` (and assets) directly in this repo, then:

```bash
git add -A
git commit -m "describe the change"
git push
```

That's it — the live site updates automatically.
