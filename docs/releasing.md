# Cutting a Pomvox release

A release is four things that must all agree, published in a fixed order:

1. A **git tag** and a GitHub release carrying `Pomvox.dmg` and `Pomvox.zip`.
2. Those files **signed and notarized by Apple**, so they open on a stranger's
   Mac without a scary dialog.
3. An **appcast entry** (`appcast.xml` on `main`) so existing users get the
   update in-app through Sparkle.
4. A **Homebrew cask bump** in `pomvox/homebrew-pomvox`.

The order matters and the scripts enforce it: nobody may ever see an appcast
entry whose download 404s, so the GitHub release goes out **first** and the
appcast commit **last**.

Budget 45–60 minutes, most of it waiting on notarization and CI.

## Before you can do this at all

Releasing needs three credentials. All three are the project owner's identity,
and none of them are needed to contribute code.

| What | Where it lives | What it does |
| --- | --- | --- |
| **Developer ID Application certificate** + private key | login Keychain | Signs the app so Gatekeeper trusts it |
| **Notary credentials** — a `notarytool` keychain profile named `pomvox-notary` | login Keychain | Uploads the build to Apple for scanning |
| **Sparkle EdDSA private key** | login Keychain | Signs the update so existing apps accept it |

Set them up once:

```sh
# 1. Certificate: Xcode ▸ Settings ▸ Accounts ▸ your Apple ID ▸
#    Manage Certificates ▸ "+" ▸ "Developer ID Application"

# 2. Notary profile. Create an app-specific password at appleid.apple.com
#    (Sign-In & Security ▸ App-Specific Passwords), then:
xcrun notarytool store-credentials "pomvox-notary" \
  --apple-id "you@example.com" --team-id "CT84AT52RS" \
  --password "abcd-efgh-ijkl-mnop"

# 3. The Sparkle key already exists for this project. Its public half is
#    SUPublicEDKey in Pomvox/project.yml. Do not generate a new one — see below.
```

You also need **admin rights on `pomvox/pomvox`**, because `main` is protected
by a ruleset requiring two approving reviews. On a small team that means
merging with `--admin`, which only admins can do.

### Can a second person do releases?

Short answer: **they can run every step, but only with the owner's signing
identity.** Signing as a *different* Apple developer is not a neutral change —
it breaks two things for every existing user:

- macOS treats a differently-signed app as a different app, so everyone's
  Microphone and Input Monitoring grants reset and dictation silently stops
  working until they re-grant.
- Sparkle checks signing continuity between the running app and the update, so
  an in-place update signed by a new identity can be refused outright.

So the realistic options are:

**A. Share the owner's credentials.** Export the Developer ID certificate and
private key as a `.p12`, share the app-specific password, export the Sparkle
key. Works today. It also hands over the ability to sign anything as the owner,
so it is a trust decision, not a technical one. Note the scripts' own warning:
*never rotate the Developer ID certificate and the EdDSA key in the same
release* — recovering from a bad rotation is far worse than the rotation.

**B. Add them to the Apple Developer team.** Only possible if the membership is
an **Organization** account, not an Individual one. Check at
[developer.apple.com/account](https://developer.apple.com/account) → Membership.
If it says Individual, you cannot add anyone; upgrading to Organization needs a
D-U-N-S number and takes days to weeks. Even on an Organization account, this
buys less than it sounds: **Developer ID certificates are controlled by the
Account Holder**, so the second person still signs with the team's existing
certificate. What they do get is their own App Store Connect login and their own
notary key, which removes the shared app-specific password.

**C. Move signing into CI (recommended).** Put the certificate `.p12`, its
password, the notary credentials and the Sparkle key into GitHub Actions
secrets, and cut releases by pushing a tag. Nobody holds the credentials
locally, the release stops depending on one laptop being awake, and adding or
removing a releaser becomes a GitHub permission change. This is more setup work
once and less risk every time after.

Until one of those is done: **a second contributor can do everything up to the
tag, and the owner runs the signing steps.** That split is a perfectly normal
way to work, and it is where this project is today.

## The steps

### 1. Bump the version

In `Pomvox/project.yml`, bump **both**:

```yaml
MARKETING_VERSION: "0.2.9"        # what users see
CURRENT_PROJECT_VERSION: "20"     # the build number Sparkle compares
```

Sparkle decides "is this newer?" from the build number, so forgetting it means
the update is published and nobody is offered it. Nothing else in the repo pins
the version.

Write the `CHANGELOG.md` entry and its link reference at the bottom.

### 2. PR it and merge

```sh
gh pr create
gh pr checks <N> --watch          # CI takes ~5 minutes
gh pr merge <N> --squash --admin --delete-branch
```

**`--admin` is required.** Without it you get *"base branch policy prohibits the
merge"* — the ruleset wants two approvals and there is one of you.

### 3. Build, sign, notarize

From a clean `main`:

```sh
scripts/notarize-release.sh
```

Four to fifteen minutes: builds Release, signs with Developer ID and the
hardened runtime, uploads to Apple, waits for the verdict, staples the ticket to
both the `.app` and a drag-to-Applications `.dmg`. Output is `dist/Pomvox.dmg`
and `dist/Pomvox.zip`.

Run it in a terminal you will leave alone. Do not run it under anything that
might kill it partway through notarization.

If Apple rejects it, the script prints the submission id; read the reasons with:

```sh
xcrun notarytool log <submission-id> --keychain-profile pomvox-notary
```

### 4. Publish

```sh
scripts/publish-release.sh v0.2.9
```

This signs the zip with the Sparkle key, splices and validates the appcast
entry, creates the GitHub release with both assets, waits until the download
actually serves HTTP 200, re-verifies the signature, then commits the appcast.

**Its last step always fails.** Pushing `appcast.xml` straight to `main` is
rejected by the branch ruleset (`GH013`). This is expected and harmless —
everything before it already succeeded, so the release is public and the users'
downloads work. The appcast commit is sitting on your local `main`. Move it to a
branch and PR it:

```sh
git branch release/appcast-v0.2.9
git reset --hard origin/main
gh pr create --head release/appcast-v0.2.9
gh pr merge <N> --squash --admin --delete-branch
```

Until that PR merges, existing users are not offered the update.

### 5. Bump the Homebrew cask

```sh
cd ~/dev/homebrew-pomvox
git checkout main                 # ← do this FIRST, every time
```

**The tap clone is routinely left on the previous release's `bump/` branch.** A
bump committed there never reaches anyone, and nothing errors to tell you. Check
before you edit.

Then update `version "0.2.9,20"` (the comma form — `brew audit` fails on
livecheck without it) and the `sha256` from
`shasum -a 256 dist/Pomvox.dmg`, and push to `main`.

### 6. Verify it actually worked

```sh
curl -sL <release-dmg-url> | shasum -a 256      # must match the cask
brew audit --cask --online pomvox               # by NAME, not by path
brew livecheck --cask pomvox                    # must report the same version,build
```

`brew audit` and `livecheck` only pass **after** the appcast PR merges, because
livecheck reads `main`.

Then the real test: on a Mac running the previous version, check that Pomvox
offers the update and that installing it keeps working. `scripts/verify-update.sh`
helps.

`brew info` will show a very old Caskroom version for existing users. That is
expected — they update in-app through Sparkle, so Homebrew's record lags.

## The three that fail every single time

Worth reading twice, because each one fails quietly:

1. **`gh pr merge` without `--admin`** — refused by the ruleset.
2. **`publish-release.sh`'s last step** — appcast push rejected; move it to a
   branch and PR it. The release is already live at this point.
3. **The Homebrew tap on a stale branch** — `git checkout main` before editing,
   or your bump goes nowhere and says nothing.

## Things not to do

- Do not generate a new Sparkle EdDSA key. Its public half is compiled into
  every shipped app; a new key means existing users can never update again.
- Do not rotate the Developer ID certificate and the Sparkle key in the same
  release.
- Do not publish the appcast before the release assets exist. The script's order
  exists to prevent exactly this; do not work around it.
- Do not build a release from a folder synced by iCloud Drive. Code signing
  rejects the extended attributes iCloud adds.
