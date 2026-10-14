# Shipping updates

Media Helper checks the project's **public** GitHub **Releases** for a newer version (at launch and every
6 hours, and from the **Media Helper ▸ Check for Updates…** menu item). When it finds one, the window shows
**"Version X is available — Install"**. Nothing installs by itself, and never while a download or
conversion is running.

Every update is signed on your Mac. The app contains only the *public* half of the signing key, so a
tampered or substituted download is refused. The previous version is kept as a backup and put back
automatically if the swap fails. The repository is public, so the app talks to GitHub without any token.

Release assets for version `X.Y`: tag `vX.Y`, files `MediaHelper-X.Y.zip` and `MediaHelper-X.Y.zip.sig`.

## One-time setup

### 1. Put the code on GitHub (public repository)

```bash
brew install gh
gh auth login
gh repo create media-helper --public --source . --remote origin --push
```

(Or create an empty public repository on github.com and `git remote add origin …` / `git push -u origin main`.)
The repository must contain no passwords, keys or personal details; commits use the neutral author `Levi <levi@local>`.

### 2. Create the signing key and tell the app where to look

```bash
scripts/setup-updates.sh <your-github-name>/media-helper
git commit -am "Point updates at the repository" && git push
```

This compiles the signing tool to `~/.mediahelper-release/release-tool`, creates the key in this Mac's
Keychain (service **"Media Helper update signing key"**, separate from any other app's key), and writes the
*public* key and the repository name into `project.yml` (`MediaHelperUpdatePublicKey`, `MediaHelperUpdateRepo`
in the app's Info.plist).

### 3. Back up the signing key  ← important

```bash
~/.mediahelper-release/release-tool export     # prints the private key; keep it in a password manager
```

The key lives only in this Mac's Keychain. **If it is lost, installed copies can never be updated again**
(they'd need a fresh install carrying a new key). Never commit it or paste it anywhere public.

### 4. Install the build with the key once

Build (`./build.sh`) after step 2 and install that copy on each church Mac as described in `SETUP.md`. Every later
version arrives through the app.

## Publishing an update (every time)

1. Make and test your changes; commit them (`git status` must be clean).
2. Run:

   ```bash
   scripts/release.sh 1.1 "One or two sentences on what changed"
   ```

   It sets the version, builds a universal app, zips and signs it, commits the version bump, tags `v1.1`,
   pushes, and creates the GitHub release with the zip and signature attached. Add `--dry-run` to build and
   sign without touching git or publishing.
3. Installed copies offer the update within 6 hours, or immediately after **Check for Updates…**. Click **Install**;
   the app quits, swaps itself, and reopens.

Version numbers must go up (1.1, 1.2, 1.2.1 …). Drafts and pre-releases are ignored, so you can stage a release on
GitHub and publish it when ready.

## Testing the update path without publishing anything

`tests/qa-update.sh <tools dir> <work dir>` builds a 1.0 app and a 1.1 release with a **throwaway** key, serves
them from a local folder, and checks: the update is offered; a bad signature, a signature from another key, and a
version mismatch are all refused; and an install swaps the app, keeps a backup and relaunches. It uses a temporary
Keychain entry that it deletes afterwards and never touches `/Applications`, GitHub or the real key. The QA flags it
relies on are `-updateFeed <releases.json or folder>`, `-updateKey <base64 public key>` and `-currentVersion <v>`.

## If something goes wrong

* **"Didn't pass its security check"**: the download was damaged or wasn't signed with your key. Nothing was
  installed. Re-run the release script.
* **"Move it to the Applications folder"**: it was opened from a disk image or a download. Drag it into Applications and reopen.
* **"Wait until the current downloads and conversions have finished"**: install when nothing is running.
* **The new version misbehaves**: the previous version is kept at
  `~/Library/Application Support/Media Helper/Updates/Previous/Media Helper.app`. Quit Media Helper and
  drag that copy over the one in Applications, or publish a fixed version.
