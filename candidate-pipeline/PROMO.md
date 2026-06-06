# Promo walkthrough — `promo.html`

A self-playing, full-screen animated walkthrough of the candidate pipeline.
It's a **concept walkthrough** (the system is a build-in-progress) — honest, but
polished enough to show internally or to stakeholders.

## How to turn it into a video

1. Open `promo.html` full-screen (press `F11` / green full-screen button).
   It auto-plays, loops, and scales to any screen.
   - `Space` = pause/play · `→` = skip scene · `↻ Restart` button.
2. Screen-record it:
   - **Mac:** QuickTime → File → New Screen Recording (or `⌘⇧5`).
   - **Windows:** Game Bar `Win+G` → record.
   - **Either:** Loom / OBS.
3. Record one clean loop (~40s), then add the voiceover below (or music).

It needs no internet and no deploy — it's fully self-contained.

## Voiceover script (~40s, timed to the 7 scenes)

1. **Title** — "This is the Day Webster candidate pipeline — one system to prospect, qualify and register talent."
2. **The problem** — "The people you need are already in your business — buried in years of spreadsheets and inbound CVs that never got qualified."
3. **Capture** — "Now there are two ways in: a registration form for new candidates, and a smart importer that reads any old spreadsheet, maps the columns itself, and removes the duplicates."
4. **Qualify** — "An AI agent takes it from there — engaging each candidate, capturing consent, and qualifying them on discipline, availability and registration."
5. **Human gate** — "But judgement stays human. Compliance acceptance, fitness-to-practise, work-ready sign-off — the agent flags these for a person, every time."
6. **Cockpit** — "Your team works it all from one cockpit: a live funnel, a full candidate view, and a review queue — moving qualified candidates to ready with a human's sign-off."
7. **Close** — "One pipeline, across every discipline — nursing, doctors, AHP, complex care, children's services, care homes and John Williams insurance. A bench that builds itself."

## Tweak it

Everything is plain HTML/CSS/JS in one file — change the headlines, the
disciplines, the demo names, the counts (`1,240 imported`, funnel numbers), or
scene timings (`data-dur` in milliseconds on each `<section>`).
