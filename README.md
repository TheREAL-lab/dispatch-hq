# Dispatch HQ

Internal operations dashboard for a repair-dispatch coordination service
serving independent self-storage operators in North DFW.

**What it does**
- Prospect call list with tap-to-call and outreach logging
- Work-order tracking for gate, keypad, camera, and access-control dispatches
- Objective technician scorecards (on-time rate, first-try fix rate)
- Pipeline metrics and validation tracking

**How it works**
Single-file web app (`index.html`) — no build step, no framework.
Connects directly to a Supabase backend secured with row-level security.
All data access requires authentication.

**Status:** Active — supporting live dispatch operations.

© 2026. All rights reserved. Not licensed for reuse.
