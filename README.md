# Acorn Scan — prescription label → medication schedule

Photograph a prescription label and get a structured daily medication schedule,
without typing. Built as a focused prototype for Part A of the Acorn Labs
challenge: *the fastest realistic path from prescription to schedule*, plus an
assessment of what integration routes are technically and legally possible in
Singapore.

## 1. What it does

1. Tap **Scan a label** and pick a prescription label photo.
2. A vision model transcribes it; a review screen shows one card per medication
   — name, strength, dose, how often, with/without food — each with the **exact
   text from the label** it came from. Anything unclear is flagged in amber.
3. You fix anything wrong and tap **Confirm**.
4. **Today's schedule** appears, grouped by time (08:00, 20:00 …), with a
   separate **As needed** section for PRN medicines. Scan another label and it
   adds to the same schedule — five photos, five confirms, instead of typing in
   five medications by hand.

## 2. How to run

```bash
# 1. Backend (holds the API key, calls Gemini)
npm install
cp .env.example .env         # then put your GEMINI_API_KEY in .env
npm run server               # starts on http://localhost:8787

# 2. App (in a second terminal)
cd app
flutter pub get
flutter run -d chrome        # fastest loop; also runs on an iOS simulator
```

Quick backend check without the app:

```bash
curl -s -F "file=@samples/label1.jpg" http://localhost:8787/scan
```

## 3. Approach

```
 FLUTTER APP                 NODE SERVER (server/index.ts)        GEMINI
 ───────────                 ─────────────────────────────        ──────
 pick / take photo
 POST /scan (image)  ──────► send image + transcription rules ──► reads label,
                             + strict JSON schema                 returns JSON
                             validate()  ◄──────────────────────
                             buildSchedule()  ← plain code
 review + confirm    ◄────── JSON { medications: [...] }
 today's schedule (in memory)
```

The one design idea behind everything:

> **The model transcribes. The code decides. The person confirms.**

- The model is only ever asked *"what does the label say?"* — never *"what
  should the patient do?"*. It returns `null` for anything not printed, at
  `temperature: 0`, against a strict JSON schema.
- Turning "twice daily" into `08:00` and `20:00` is done by a small, readable
  function (`buildSchedule`), not by the model, so it is identical every time
  and can be explained line by line.
- Nothing reaches the schedule until a human has seen it. In a reminder app a
  misread frequency becomes *the app actively prompting the wrong dose*, so the
  confirm step is a safety feature, not UI polish.

**Why a vision model, not classic OCR.** OCR turns pixels into flat text, and
you then write brittle rules to find the drug, dose and frequency — rules that
break because every pharmacy's layout differs. It also loses position, and on
Singapore labels position *is* meaning: `1-0-1` means morning–afternoon–night.
A vision model reads the whole image intact and returns structured fields
directly. Honest trade-offs: it needs internet, costs a tiny amount per call,
and sends data to a cloud provider — which is exactly why there is a review
step and why we send a paid/enterprise tier for real patient data (see §5).

**Why a server.** An API key must never ship inside a mobile app — anyone can
unpack the app and read it. A tiny Node server holds the key and does the
Gemini call. In production this becomes **Firebase AI Logic** or a **Cloud
Function**, which fits Acorn's stack exactly.

**Why Flutter on web for this prototype.** Flutter is Acorn's own stack (one
codebase for iOS + Android). Running on Chrome is the fastest build loop and
avoids iOS toolchain setup; the same code runs on an iOS simulator.

## 4. Safety decisions

Every one of these is a deliberate choice, not an accident of scope:

- **Never guess.** A field that is not printed comes back `null`, not invented.
- **A quantity is not a duration.** "× 60 tablets" at 2/day *looks* like 30
  days, but the doctor may want it continued — a supply count is not an
  instruction to stop. `duration_days` is set only when the label states a
  length ("for 5 days").
- **PRN medicines are never given scheduled times.** Scheduling an "as needed"
  painkiller would tell someone to take it when they don't need it. They go in
  an **As needed** list instead.
- **The source text is shown on every card**, so the user checks against the
  label, not against the app's confident guess.
- **Low confidence and missing essentials are flagged** (amber border + a plain
  reason) rather than silently scheduled.
- **No patient identifiers are extracted** — not name, NRIC or address. The app
  does not need them to build a schedule, and not asking is data minimisation
  under the PDPA.
- **Nothing is saved without an explicit confirm.**

## 5. Singapore integration routes

The brief asks for a view on what is technically and legally possible, not just
a demo. Direct access to national health records is not open to startups, so a
credible analysis of what access would require is itself the deliverable.

**Route 1 — Photo of the label + vision model (what this prototype does).**
Works today on any printed label, no partner needed. The patient photographs
their own label and chooses to upload it, so consent is direct. Acorn still
carries PDPA obligations — consent, purpose limitation, security, retention
limits, mandatory data-breach notification, and the **transfer limitation
obligation**: sending images to an AI provider overseas requires comparable
protection via contract/provider terms. Free AI tiers may train on inputs, so
real patient data needs a paid/enterprise tier. Main risk is misreads, mitigated
by the confirm screen; handwriting remains weak.

**Route 2 — Patient-mediated export from HealthHub.** HealthHub is MOH's
patient app/portal (operated by Synapxe, Singpass login) where patients can see
their own medication, lab and appointment records. There is **no open API for
third-party consumer apps** to pull that data. But a patient can screenshot or
download their own medication list and feed it into the *same scanner* — legally
clean (their data, their action), zero partnership, and the cheapest "never type
anything" path. A strong onboarding hint to add.

**Route 3 — Partnership with clinics / pharmacies.** Polyclinic clusters and
retail pharmacies print standard labels. A partner could share structured
dispensing data with consent, or print a **QR code** encoding the prescription
so scanning becomes exact with no AI at all. Requires a commercial agreement,
a data-sharing agreement, a PDPA consent flow and a partner security review —
months, not weeks, but the real "type nothing" solution.

**Route 4 — National Electronic Health Record (NEHR).** MOH-owned,
Synapxe-managed; access is restricted to authorised healthcare professionals
for direct patient care and is **not open to consumer apps**. Realistic access
would require being or partnering with a provider licensed under the
**Healthcare Services Act (HCSA)**, MOH/Synapxe approval, and meeting their
security and integration standards. The **Health Information Act** (passed after
its Bill was introduced in November 2025) now mandates licensed providers to
contribute data to NEHR in phases and tightens how NEHR data is accessed and
shared — so the rules here are getting stricter, not looser. A later-stage
partnership, not an engineering task.

**Route 5 — Apple HealthKit / Android Health Connect clinical records.** Apple's
Health Records (FHIR clinical data) is limited to the US, UK and Canada —
**not available in Singapore** — and Health Connect's medical-records feature
has no confirmed Singapore clinical-records availability. Both are still useful
later for *logging taken doses*, just not as a prescription source here.

**Regulatory framing.** HSA regulates software as a medical device. An app that
*transcribes and reminds* sits at the low-risk end; one that *recommends,
adjusts or checks* doses moves toward regulated territory (HSA classifies by
how much the software influences a clinical decision). Keeping the model to
transcription and the human as the final check is deliberately on the
conservative side of that line.

**Recommendation.** Ship Route 1 now (works for everyone, today), add Route 2 as
an onboarding hint ("have HealthHub? screenshot your medication list"), pursue
Route 3 (pharmacy QR / data feed) as the real type-nothing solution, and treat
NEHR as a later-stage partnership once a clinical relationship exists.

## 6. What I could not do, and why

- **No Firebase / no persistence.** The schedule lives in memory and resets on
  restart. Firebase setup was not worth the time against a four-hour window; the
  server is deliberately shaped so it drops into Firebase AI Logic + Firestore
  later.
- **Accuracy is not benchmarked.** The pipeline is proven working on real
  sample documents, but field-level precision across many labels, and
  handwriting accuracy, are not measured.
- **Real camera on the iOS simulator** is not wired up (the simulator has no
  camera); the gallery picker stands in, and the same code uses the camera on a
  physical phone.
- **Part B (the engagement/streak/nudge core) was out of scope** by choice, to
  do Part A properly.

## 7. What I would build next

- Replace the Node server with **Firebase AI Logic** or a **Cloud Function**,
  and store confirmed medications in **Firestore** — matching Acorn's stack.
- **On-device OCR first, vision model only on low confidence** — faster, more
  private, cheaper, with the model as a fallback.
- An **accuracy benchmark** over N labels with field-level precision, so claims
  are measured, not asserted.
- **HealthHub screenshot import** as a one-tap onboarding route (Route 2).
- A **pharmacy QR pilot** for exact, AI-free capture (Route 3).
- Feed the confirmed schedule into Acorn's **dose logging and reminder system**
  (the handoff into Part B).

## 8. Prior work

I previously built a related prototype, **MediGraph**, which turns a caregiver's
folder of medical documents into a navigable medical history. The
transcribe-then-confirm split and several of the safety rules here
(quantity ≠ duration, never guess, show the source quote) come from that work.
This repository was written fresh during the challenge.
