# SmartSpend

**Intelligent Budget Monitoring and Location-Intelligent Spending Tracking** — an Android expense-tracking app that warns you *before* you overspend, not after.

> Final Year Project (BMCS3403/3413) — Faculty of Computing and Information Technology, TAR UMT
> Author: Koo Wee Xuan (24WMR07992) · Supervisor: Mr Veren Ten Shai Cheong · Partner: Yen Han Soon

---

## The problem

- 47% of young Malaysians (18–25) and 38% of those 35–55 struggle with debt.
- 73% of Malaysians underestimate their monthly spending by 30–40%.
- Existing budgeting apps (Seedly, Money Lover, Money Tracker, Wallet) are all **reactive** — they show what you already spent. None warn you *while* you're standing in the shop about to overspend, and none use location to time that warning.

## The solution — three engines working together

| Engine | What it does |
|---|---|
| **Location System** | Uses GPS to detect when you've been at a known shopping venue (mall, restaurant, hypermarket) for 15–20 min. Learns routine locations (home/work) and stays silent there. |
| **AI Budget Engine** | Tracks spending per category in real time, calculates a daily "burn rate," and projects whether you'll blow the budget before month-end. |
| **Smart Alert Engine** | Combines the two above + Gemini AI to send a *specific* notification at the moment of decision (e.g. "Shopping budget: RM80 left, you usually spend RM180 here — think twice"). Has a 2–3 hour cooldown per venue to avoid spam. |

**Example flow:** user enters Mid Valley → stays 20 min → app checks shopping budget → budget is low → Gemini generates a short contextual warning → notification includes a "Record Spending" button that opens a pre-filled Quick Record form (under 3 taps).

## Module ownership (this is a 2-person project)

This repo/report covers:
- ✅ **AI-driven Intelligent Budget Monitoring Module**
- ✅ **Location-Intelligent Spending Tracking Module**

Built and documented separately by project partner Yen Han Soon:
- 🔲 OCR-based Receipt Digitisation Module
- 🔲 Voice-Assisted Expense Categorisation Module

(Receipt scanning and voice input appear in the UI mockups but their logic belongs to the partner's modules.)

## Target users

| Group | Age | Pain point |
|---|---|---|
| Students / young adults | 18–25 | Run out of money mid-month, impulsive social spending |
| Young professionals | 22–40 | Paycheck-to-paycheck, no time for complex apps |
| Middle-aged professionals | 40–60 | Lifestyle inflation, find most budgeting apps too complex |

## Tech stack

- **Framework:** Flutter (Dart) — Android only for this project (no iOS/web/desktop)
- **Backend:** Supabase (Auth, Realtime Database, Row Level Security, Cloud Messaging)
- **Location:** `geolocator` package + Google Maps API (geofencing, 100m radius matching)
- **AI:** Google Gemini API (personalized advice, budget warnings — not a custom-trained model)
- **Local storage:** Hive / SharedPreferences (offline support)
- **Key packages:** `supabase_flutter`, `google_maps_flutter`, `geolocator`, `flutter_local_notifications`, `http`

## Architecture

Four-layer layered architecture (chosen over microservices — team of 2, no need for that complexity):

```
Presentation Layer   → Flutter UI (Dashboard, Add Expense, AI Advisor, Forecast, Profile)
Business Logic Layer → Financial Service, Location Service, Recommendation Service,
                        Forecast Service, Dashboard Service
Security Layer        → Supabase Auth (email + OTP verification),
                        Row Level Security, location permission control
Data Access Layer     → DAOs (Financial, Location, User) → Supabase
```

## The 3 core algorithms

1. **Location Detection & Dwell Time Filtering** — polls GPS every 30s, matches against a venue database (100m radius), filters out routine locations and people just passing through (<15 min dwell).
2. **Burn Rate Calculation & Budget Forecast** — `daily burn rate = spent ÷ days elapsed`, projects month-end total, flags Safe (<80%) / Caution (80–100%) / Critical (>100%).
3. **Smart Alert Trigger** — combines #1 + #2, builds a Gemini prompt when budget is Caution/Critical, applies a 2-hour per-venue cooldown, sends the notification.

## Key non-functional requirements

- App starts in <3s · expense recording in ≤3 taps · AI advice loads in <3s
- Works offline for basic features, syncs when reconnected
- Raw GPS coordinates are **never stored** — only the matched venue name + dwell duration
- Bilingual: English + Bahasa Malaysia

## Project status / timeline

| Milestone | Target date |
|---|---|
| Proposal approved | 25/12/2025 |
| Requirements & analysis | 05/02/2026 |
| System design | 13/03/2026 |
| Core development | 05/04/2026 |
| Testing & QA | 08/08/2026 |
| Final system testing | 13/08/2026 |

Currently on branch `weexuan/budget-module` — implementing the Budget Monitoring + Location Tracking modules described above.

## Getting started (dev setup)

```bash
flutter pub get
flutter run            # launches on connected Android device/emulator
```

Requires a `.env` (see `.env.example`) with Supabase and Gemini API keys — never commit `.env`.

---

*This README is a working summary generated from `proposal.pdf` and `RSW2S3G2_KooWeeXuan_Project_1_Report.pdf`. If anything here is wrong or out of date as the implementation evolves, let me know and I'll fix it.*
