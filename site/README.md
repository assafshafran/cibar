# CIBar website

The landing page for CIBar, served at https://cibar.dev (and www.cibar.dev). It's plain static files with no build step, hosted on Cloudflare Workers static assets. `wrangler.jsonc` holds the config and the two custom domains.

```bash
cd site && npx wrangler deploy
```

`.assetsignore` keeps this README and `wrangler.jsonc` off the live site.

- The Download buttons point to `https://github.com/cibar-dev/cibar/releases/latest`, which returns a 404 until the first release is published.
- The desktop, menu bar and CIBar popover in the hero are drawn in HTML and CSS with made-up example repositories, and the icons are inline SVG.
- The page was designed in a Claude design canvas and converted to static HTML: edit `index.html` directly from now on.
