# BuildBar

A small macOS menu bar app that watches **Azure DevOps pipelines** and **GitHub Actions** workflows.

- The menu bar icon spins (blue) while any watched build is running. When a build finishes, the icon turns into a green ✓ or red ✕ until you open the menu. You also get a notification, and clicking it opens the run.
- Click the icon to see the latest runs for each source: status, run number, commit message, repo, branch, author, age and duration. Durations count live while a build is running. Click a row to open it in the browser.
- It polls every 15 s–5 min (your choice), at least every 15 s while something is running, and refreshes on wake and whenever you open the menu.

## Build and install

Requires macOS 15+ and Xcode command-line tools.

```bash
./scripts/build-app.sh --install   # builds dist/BuildBar.app, copies it to ~/Applications and launches it
```

## Setup

Click the icon, then the gear:

1. **Add sources:** paste a URL, e.g. `https://dev.azure.com/<org>/<project>/_build?definitionId=105` or `https://github.com/<owner>/<repo>` (or `.../actions/workflows/ci.yml`). You can limit a source to pipeline ids, a workflow or a branch.
2. **Azure DevOps token:** a Personal Access Token with **Build (Read)**.
3. **GitHub token:** optional for public repos. Use a fine-grained token with **Actions: Read**, or click *Use gh CLI token*.

Tokens are stored in `~/Library/Application Support/BuildBar/tokens.json`, readable only by you (like the `gh` and `az` CLIs). Everything else is in `defaults read local.buildbar.app`.

## Diagnostics

```bash
~/Applications/BuildBar.app/Contents/MacOS/BuildBar --dump   # prints what each source returns, then exits
```

The build script signs with your Apple Development certificate when one is installed, otherwise ad-hoc.
