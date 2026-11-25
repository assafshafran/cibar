# CIBar

**Your builds in the Mac menu bar.** CIBar watches Azure DevOps pipelines and GitHub repositories. It pulses while something is building and turns green or red the moment a build lands, with a notification that opens the run.

Free and open source (MIT). macOS 15 or later.

## What it watches

| Provider | What shows up | Token |
|---|---|---|
| **Azure Pipelines** | Builds in a project: all pipelines, or the pipeline ids you choose | Personal access token with **Build (Read)** |
| **GitHub Actions** | Workflow runs: all workflows, or one workflow file | Fine-grained token with **Actions (Read)**; optional for public repos |
| **Vercel, Netlify and others** | Deploys reported to GitHub as commit statuses, on the same repo | Same GitHub token |

Any source can be limited to one branch.

## How it looks

- **Menu bar icon:** a three-stage pipeline. It is quiet in the menu bar's own colours when nothing is happening, and blue with a moving pulse while a build runs. When a build finishes it turns green ✓, red ✕ or orange !, and stays that way until you open the menu.
- **Menu:** the latest one to three runs of every source, so everything fits without scrolling. Running builds are always shown. Each row has the commit message, build number, branch, repository and author, with a live timer while it runs, and opens the run when clicked. *Show more* reveals a source's history.
- **Notifications** when a build finishes. Success alerts are optional, and clicking a notification opens the run.
- **Checks** every 30 seconds by default (configurable), every 15 while a build runs, and again when your Mac wakes.

## Install

Build from source with the Xcode command-line tools:

```bash
git clone https://github.com/cibar-dev/cibar
cd cibar
./scripts/build-app.sh --install    # builds dist/CIBar.app, copies it to ~/Applications and opens it
```

The script signs with your Apple Development certificate if you have one (otherwise ad hoc).

## Setup

Click the icon, then the gear:

1. **Add a source.** Paste a URL such as `https://dev.azure.com/<org>/<project>/_build?definitionId=12` or `https://github.com/<owner>/<repo>`, or use **Choose repositories…** to pick from the repos your GitHub token can see.
2. **Save your tokens.** Use an Azure DevOps token with Build (Read). For GitHub, use a token with Actions (Read), or click **Use gh CLI token**.

## Privacy

- Tokens are stored in `~/Library/Application Support/CIBar/tokens.json`, readable only by your user account, the same way the `gh` and `az` CLIs keep theirs.
- CIBar only talks to `dev.azure.com` and `api.github.com`. It has no account, no analytics and no server.
- It only reads. It never queues, cancels or changes anything.

## Diagnostics

```bash
~/Applications/CIBar.app/Contents/MacOS/CIBar --dump    # prints what each source returns, then exits
```

## Contributing

New providers (GitLab, Bitbucket, Jenkins…) are very welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).
