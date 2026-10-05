# Omnie brand guide

Status: v1, 2026-10-04
Canonical source: `github.com/wckdboy/omnie-edit/BRANDING.md`
Applies to: every Omnie app, tool, and doc — currently [omnie-edit](https://github.com/wckdboy/omnie-edit) and [omnie-agent](https://github.com/wckdboy/omnie-ios), with more to come.

This file is copied verbatim into each Omnie repo. If you change it, update the canonical copy in omnie-edit first, then sync the others — see [Keeping this in sync](#keeping-this-in-sync).

## 1. Principles

1. **Monochrome first.** The interface is black, white, and grays. Color is not decoration — it marks the one thing that matters on screen.
2. **One accent.** A single purple-to-orange gradient is the entire color vocabulary beyond neutrals. It marks primary actions and active/selected state. Nothing else gets tinted.
3. **Minimal but functional.** Quiet chrome, generous space, no ornamental UI. Every element on screen does a job.
4. **Non-intrusive.** No modal interruptions, no marketing chrome inside the product, no motion that isn't explaining a state change. The tool gets out of the way of the work.
5. **Native, not skinned.** Each platform's own controls, type, and motion are the baseline. Brand is expressed through restraint and the accent, not by overriding the platform.

If a design decision would trade legibility, accessibility, or platform convention for brand flourish, keep the platform convention. This guide loses that argument on purpose.

## 2. Color

### 2.1 Neutrals

Two neutral sets exist. Both are legitimate; they serve different intents.

**Warm neutrals — the default.** What people see day-to-day in System/Light/Dark theme. Slightly warm, not clinical.

| Token | Light | Dark |
|---|---|---|
| `background` | `#F6F6F4` | `#101010` |
| `text` | `#161616` | `#E6E6E3` |
| `secondary` | `#6E6E6A` | `#8E8E8A` |
| `hairline` | `#D8D8D4` | `#2A2A2A` |

**True monochrome — the alternate mode.** Pure black/white, for people who want maximum contrast or minimum chroma. This is the set the name "black/monochrome" refers to — ship it as a real, selectable theme, not just a figure of speech.

| Token | Light | Dark |
|---|---|---|
| `background` | `#FFFFFF` | `#000000` |
| `text` | `#000000` | `#FFFFFF` |
| `secondary` | `#6A6A6A` | `#9A9A9A` |
| `hairline` | `#E0E0E0` | `#2A2A2A` |

Reference implementation: `OmnieEdit/Theme/Palette.swift` (`Palette.light` / `.dark` / `.monochromeLight` / `.monochromeDark`).

### 2.2 Accent: the gradient

Purple into orange, diagonal (top-leading → bottom-trailing). This is the brand mark as much as any logo.

```
Purple  #9E2EDB   (0.62, 0.18, 0.86)
Orange  #FA9429   (0.98, 0.58, 0.16)
```

**Use it for exactly one thing per screen: the primary action, or the active/selected item.** A create button, the active tab, a primary CTA. If more than one element on a screen carries the gradient, something is wrong — pick the single most important one.

Don't:
- Tint secondary buttons, icons, or decorative elements with it.
- Use it as a background fill for large areas or text.
- Recolor it. Hue-shifting "for this app" defeats the point of a shared brand mark.

Where the platform needs a flat `Color` (segmented controls, toggles, system tint — anything that can't take a gradient), use a flat accent orange: `#EF7B1B` (light) / `#FA9433` (dark). Reference: `AccentColor` asset catalog color in omnie-edit. These should read as "the orange end of the gradient," not a third color — if your platform's flat accent drifts far from `#FA94xx`, pull it back in line.

### 2.3 Syntax / semantic colors

Editors, logs, and diff views need more colors than the brand provides (keyword/string/comment/number, addition/deletion, etc.). Those are **app-level, not brand-level** — pick what's legible against the warm or monochrome neutrals above, keep them desaturated enough to stay quiet, and don't invent a third brand color to cover them. Reference: the syntax fields in `Palette.swift`.

## 3. Typography

| Role | Family | Notes |
|---|---|---|
| Display / headers | **Unbounded** | Geometric, wide, a little strange — reserved for headers, the wordmark, and marketing surfaces. OFL-licensed, available on Google Fonts. Use 600–900 weight for headers; lighter weights read weak at display size. |
| Body (native apps) | **System font** (SF Pro / `-apple-system`) | Do not bundle a custom body font in a native app. Dynamic Type, accessibility sizing, and localization fall out of this for free; a custom body font fights all three. |
| Body (web / docs / marketing) | **Inter** | Clean, neutral grotesk, pairs with Unbounded without competing with it. OFL-licensed. Only used where there's no OS to defer to. |
| Code | **System monospace** (SF Mono / `-apple-system` monospaced, or the platform's default `monospace`) | Matches the "one mono for code" rule from the start — don't bundle a code font either unless a specific language/ligature need justifies it. |

Headers are the one place custom type shows up at all. Everything else defers to the platform.

## 4. Material and motion

- **Liquid Glass, used sparingly, functional layer only.** Apple's own guidance applies directly: glass belongs on controls and navigation (toolbars, floating actions, tab chips), never in the content layer, and never on more than the one or two most important controls on a screen. See `RunestoneCodeEditor.swift`'s theme bridge and `EditorView.swift`'s tab strip for the reference pattern — gradient fill behind clear glass for the primary action, plain glass for everything else that needs the material at all.
- **No motion that isn't explaining state.** Transitions should clarify what just changed (a tab opening, a panel appearing), not perform. No bouncing, no attention-seeking idle animation.
- **No modals for things that aren't decisions.** Use inline state, toasts, or disclosure instead of interrupting with a sheet unless the user actually has to choose something before continuing.

## 5. Voice

Short, direct, specific. Say what happened or what will happen — not what the product is proud of.

- "Enter a line number in the current file." — not "Jump instantly to any line!"
- "Files remain in the locations you choose." — not "Seamless, secure file management."

No exclamation points. No "seamless," "powerful," "effortless," or other adjectives that describe nothing. If a sentence would work equally well in a man page, that's the right register.

## 6. Logo / wordmark

- The wordmark is set in Unbounded, bold-to-black weight, and is **monochrome only** (`text` color, light or dark set as appropriate). The gradient does not go on the wordmark itself — it's reserved for interactive UI, not the mark.
- A small accent glyph (e.g. a dot, a single geometric shape) may carry the gradient as a one-time flourish next to the wordmark, but the wordmark's letters stay neutral.
- No drop shadows, no bevels, no outline-plus-fill combinations. Flat color on a flat or glass background.

(No logo asset exists yet as of this writing — this section is the constraint any future logo design has to satisfy.)

### 6.1 App icon

- Background: **pure white, `#FFFFFF`**. Not the warm off-white used elsewhere in the UI — the icon background is the one place the brand uses true white, so icons sit consistently on the Home Screen regardless of which app they're next to.
- Mark: pure black, `#000000`, flat, centered, no gradient.
- Every Omnie app icon uses this same background. If a platform wants a dark/tinted variant (iOS dark/tinted icon appearances), keep the mark pure black or white as appropriate and the base variant's background at pure white — don't introduce a third background color per variant.

## 7. Known gaps

- omnie-edit's `AccentColor` asset (`#EF7B1B` / `#FA9433`) and the `BrandGradient` orange endpoint (`#FA9429`) are close but not identical — they drifted independently. Worth reconciling to one exact value next time either is touched.
- No logo/wordmark asset exists yet (see §6).
- omnie-agent has not yet adopted this palette/typography in its own UI — this guide describes the target, not (yet) omnie-agent's current state.

## Keeping this in sync

This file is duplicated, not symlinked or submoduled, across Omnie repos — simplest thing that works for two repos. When you update it:

1. Edit the copy in `omnie-edit` (canonical).
2. Copy the updated file verbatim into every other Omnie repo's root as `BRANDING.md`.
3. New Omnie project: copy this file in at repo root before writing any UI.

If this grows into more than copy-paste (e.g. shared design tokens as code), that's a sign it's time for a dedicated shared package — not a reason to let the copies drift in the meantime.
