# TriGenius website

Static privacy-policy site, served at **https://trigenius.narica.net/privacy**.

Stack: [Deno](https://deno.com) as the runtime/task runner, Vite + React,
Tailwind CSS v4, and [shadcn/ui](https://ui.shadcn.com) components. No Node
install required — everything runs through Deno's npm compatibility.

## Develop

```bash
deno task dev      # local dev server (http://localhost:5173/privacy)
deno task build    # production build → dist/
deno task preview  # serve the built dist/ locally
```

## Deploy

```bash
deno task deploy   # build, then force-push dist/ to the gh-pages branch
```

`deploy.sh` builds the site and publishes `dist/` as a single fresh commit on
the `gh-pages` branch of `origin`. It writes:

- `CNAME` → `trigenius.narica.net` (GitHub Pages custom domain)
- `.nojekyll` → serve files as-is
- `404.html` (copy of `index.html`) → SPA fallback so `/privacy` resolves on a
  direct hit or refresh

### One-time GitHub / DNS setup

1. Repo → **Settings → Pages**: set source to the **`gh-pages`** branch.
2. DNS for `narica.net`: add a `CNAME` record
   `trigenius` → `maxdilling.github.io.`
3. Back in **Settings → Pages**, confirm the custom domain `trigenius.narica.net`
   and enable **Enforce HTTPS**.

## Add shadcn/ui components

Components live in `src/components/ui`. To add more with the CLI (needs Node/npx):

```bash
npx shadcn@latest add button
```

or copy the component source from https://ui.shadcn.com and drop it in
`src/components/ui`. The `@/` alias, `cn()` util and Tailwind theme are already
configured (`components.json`).
