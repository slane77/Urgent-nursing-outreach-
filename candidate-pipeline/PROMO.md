# Promo walkthrough — `promo.html`

A self-playing, full-screen animated walkthrough of the candidate pipeline.
It's a **concept walkthrough** (the system is a build-in-progress) — honest, but
polished enough to show internally or to stakeholders.

It is **responsive**: landscape on a laptop (16:9), and full-screen **portrait
on a phone** (9:16 — ideal for WhatsApp / socials).

## On your phone (easiest — gives a vertical video)

1. Open `promo.html` in the phone browser (e.g. the GitHub Pages URL once this
   branch is live, or AirDrop/email the file to yourself and open it).
2. Turn the screen recorder on:
   - **iPhone:** swipe into Control Centre → tap the ⏺ Record button
     (add it via Settings → Control Centre if it isn't there). Mute
     notifications first.
   - **Android:** swipe down Quick Settings → **Screen record**.
3. Let it play one full loop (~40s), then stop. That's your video.
   - Tap once to reveal controls: ❚❚ pause, ↻ restart.

## On a laptop

1. Open `promo.html` full-screen (`F11`). It auto-plays and loops.
   `Space` = pause/play · `→` = skip scene.
2. Record: **Mac** QuickTime/`⌘⇧5` · **Windows** Game Bar `Win+G` · or Loom/OBS.
3. Capture one clean loop, then add the voiceover below (or music).

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
