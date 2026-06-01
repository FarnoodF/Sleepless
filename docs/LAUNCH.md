# Launch drafts (human-only channels)

These channels need **your** accounts and human judgement, so they are NOT posted
automatically. Each draft is ready to paste. Read each community's current rules before
posting (they change), lead with the demo, be honest about rough edges, and never beg for
upvotes. Repo: https://github.com/Aboudjem/Sleepless

The automatable awesome-list PRs were opened separately (see the final report for URLs).

---

## 1. Show HN

- **When:** Tue–Thu, roughly 7–10am Pacific (so you can sit in the thread). Ranking is
  multi-factor; timing is not a magic lever.
- **Qualifies:** you built it, anyone can build/run/inspect it (open source). Good fit.
- **Title (no caps, no superlatives, no exclamation):**

  `Show HN: Sleepless – keep a Mac awake with the lid closed`

- **Text:**

  > I kept reaching for `sudo pmset -a disablesleep 1` to keep my MacBook running with the
  > lid shut (overnight builds, long downloads, an agent run, sharing a hotspot from my bag)
  > and kept forgetting to turn it back off, which drains the battery and traps heat.
  >
  > Sleepless is a tiny AppKit menu-bar app that does exactly that one thing: flips
  > `disablesleep` from a native switch, on battery, with no external display, and adds a
  > battery-floor auto-off (default 15%) so a forgotten "on" state can't cook the battery. A
  > reboot also resets it.
  >
  > It is the least-privilege version I could build: one Apple binary (`/usr/bin/pmset`),
  > two pinned arguments, made passwordless by a tightly scoped `/etc/sudoers.d` drop-in
  > (root:wheel, 0440), no helper daemon, no kext. It is ad-hoc signed, not notarized, so the
  > intended trust path is build-from-source. Threat model and exact sudoers line are in
  > SECURITY.md.
  >
  > Honest limits: `disablesleep` is undocumented (Apple could change it), and I have only
  > verified it on macOS 26 / Apple Silicon. Feedback and reports from other hardware welcome.
  >
  > https://github.com/Aboudjem/Sleepless

- **Do:** answer fast, agree-then-address criticism, keep the source front and center.
- **Don't:** ask for upvotes, plant booster comments.

---

## 2. r/macapps (~222k members)

- **Before posting:** read the sidebar + `reddit.com/r/macapps/wiki`, check for a required
  post flair (e.g. a developer/promo flair) and any karma/age gate, and look for a pinned
  promo/megathread. Be an active member first.
- **Title:** `Sleepless – open-source menu-bar app to keep your Mac awake with the lid closed (on battery, no external display)`
- **Body:**

  > Open source (MIT). A small menu-bar app that keeps a MacBook awake with the lid closed,
  > on battery, with no external display, via `pmset disablesleep`, plus a battery-floor
  > auto-off so it is safe to forget. Native AppKit + SF Symbols, no daemon, no kext.
  >
  > caffeinate-based apps (KeepingYouAwake, etc.) can't do lid-closed by design; Amphetamine
  > can but is finicky on Apple Silicon. This is the purpose-built, auditable version.
  >
  > Install: `brew install --cask aboudjem/tap/sleepless`, or build from source.
  > Ad-hoc signed (not notarized) so build-from-source is the trust path. Verified on
  > macOS 26 / Apple Silicon. Demo + security model in the README.
  >
  > https://github.com/Aboudjem/Sleepless

- Post as a detailed self-post with the open-source link (not a bare link). Reply to feedback.

---

## 3. r/apple

- **Rules (verify against the live sidebar):** developer self-promo is allowed **only on
  Sundays** ("Self-promotion Sunday"), as a **self-post** (no bare links). You must have
  **≥5 unrelated posts/comments in r/apple in the past month**, and self-promo must be
  **≤10%** of your activity. Abuse = instant ban. Build that history organically first.
- **Title:** `[Self-promotion Sunday] Sleepless – keep your Mac awake with the lid closed, on battery (open source)`
- **Body:** reuse the r/macapps body above, plus one line on the security model (passwordless
  sudoers limited to two exact `pmset disablesleep` commands; reboot + battery-floor reset).

---

## 4. Product Hunt

- **When:** schedule for **12:01am Pacific**; for a dev tool, a weekend (esp. Sunday) is a
  known lower-competition slot. Prime ~300–400 warm people beforehand; PH amplifies momentum,
  it does not create it. "Launched" is not "Featured" (PH curates the homepage).
- **Name:** Sleepless
- **Tagline (≤60 chars):** `Keep your Mac awake with the lid closed`
- **Assets:** gallery images **1270×760**, thumbnail **240×240** (reuse the violet brand +
  crescent; `assets/social-preview.png` is a good base), a short demo (use `assets/demo.gif`).
- **Topics:** Mac, Developer Tools, Productivity, Open Source.
- **First maker comment:**

  > Hi PH. I built Sleepless because I kept dropping to `sudo pmset disablesleep 1` to keep my
  > MacBook running with the lid shut (overnight builds, hotspot in my bag) and kept forgetting
  > to turn it off. It is a tiny, open-source menu-bar switch that does just that, on battery,
  > with no external display, plus a battery-floor auto-off so it is safe to forget. Native,
  > no daemon, no kext; ad-hoc signed so build-from-source is the trust path. Verified on
  > macOS 26 / Apple Silicon. What would make it more useful for your setup?

- **Don't** ask for upvotes; ask for feedback. Spread promotion across the day.

---

## 5. AlternativeTo

- **How:** sign in → "Suggest new application" → Platforms: **Mac**; License: **Open
  Source / Free**; fill description + tags; then use "suggest alternatives".
- **List as an alternative to:** Amphetamine, KeepingYouAwake, Caffeine, Theine, Lungo.
- **Description:**

  > Open-source macOS menu-bar app that keeps a Mac awake with the lid closed, on battery,
  > with no external display, via `pmset disablesleep`, with a battery-floor auto-off. Native
  > AppKit, MIT licensed.

- **Tags:** menu-bar, keep-awake, caffeine, pmset, clamshell, battery, open-source, macos.
- Optionally claim the listing later: email support@alternativeto.net from the project domain.

---

## 6. MacUpdate

- **Submit:** https://www.macupdate.com/content/submit (guidelines:
  https://www.macupdate.com/help/submit-app).
- **Category:** Utilities (or Developer Tools).
- **Description:** the AlternativeTo description above.
- **Release notes (1.0.0):** Initial release. Keep a Mac awake with the lid closed, on
  battery, no external display; battery-floor auto-off; native menu-bar app.
- **Requirements:** macOS 26 (Tahoe), Apple Silicon.
- Lower priority; mainly an SEO/listing presence.

---

### Reminder
Do not post any of these from an automated process. They require your own accounts and
ongoing presence in each community. Lead with the demo, be candid about the undocumented
mechanism and the ad-hoc signing, and respond quickly.
