#!/usr/bin/env python3
"""
Texas Gate Dispatch — Dispatch HQ 1099 Recruiting & Lead-Sweep Agent Swarm
==========================================================================
Implements the 4-Agent Recruiting & Pipeline Swarm for Dispatch HQ:
  1. JobBoardSyndicator   — Generates platform-tailored 1099 job ads & DMs
  2. OutboundHeadhunter   — Scores rep profiles (0-100) & generates DM/SMS hooks
  3. AuditionScreener     — Lists/ranks `rep_candidates` & generates onboarding packets
  4. FacilityLeadSweeper  — Scores DFW self-storage leads for Gate Pain & seeds Radar

Usage:
  python3 agents/recruiting_swarm.py status
  python3 agents/recruiting_swarm.py generate-ads [--url https://...]
  python3 agents/recruiting_swarm.py score-rep --name "Marcus Vance" --hrs 25 --tags b2b_cold_calling,property_management,texas_local --notes "6 yrs commercial roofing cold caller"
  python3 agents/recruiting_swarm.py seed-reps [--push]
  python3 agents/recruiting_swarm.py sweep-leads [--push]
"""

from __future__ import annotations
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

ROOT_DIR = Path(__file__).resolve().parent.parent
INDEX_HTML = ROOT_DIR / "index.html"
DEFAULT_AUDITION_URL = "https://thereal-lab.github.io/dispatch-hq/audition.html"
DEFAULT_HQ_URL = "https://thereal-lab.github.io/dispatch-hq/index.html"
DEFAULT_DOCS_URL = "https://thereal-lab.github.io/dispatch-hq/docs.html?doc=d5"


def extract_supabase_config() -> Dict[str, str]:
    """Read Supabase URL and publishable key directly from index.html or env."""
    url = os.environ.get("SUPABASE_URL", "")
    key = os.environ.get("SUPABASE_KEY", "")
    if url and key:
        return {"url": url, "key": key}
    if INDEX_HTML.exists():
        content = INDEX_HTML.read_text(encoding="utf-8", errors="ignore")
        url_match = re.search(r"https://[a-z0-9]+\.supabase\.co", content)
        key_match = re.search(r"sb_publishable_[A-Za-z0-9_\-]+", content) or re.search(
            r"eyJ[A-Za-z0-9_\-\.]{60,}", content
        )
        if url_match:
            url = url_match.group(0)
        if key_match:
            key = key_match.group(0)
    return {"url": url, "key": key}


def supabase_rest(
    table: str,
    method: str = "GET",
    payload: Optional[Any] = None,
    query: str = "",
) -> Any:
    """Lightweight zero-dependency Supabase PostgREST client."""
    cfg = extract_supabase_config()
    if not cfg["url"] or not cfg["key"]:
        raise RuntimeError("Could not locate Supabase URL/key in index.html or environment.")
    endpoint = f"{cfg['url']}/rest/v1/{table}"
    if query:
        endpoint = f"{endpoint}?{query}"
    headers = {
        "apikey": cfg["key"],
        "Authorization": f"Bearer {cfg['key']}",
        "Content-Type": "application/json",
        "Prefer": "return=representation",
    }
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(endpoint, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as resp:
        body = resp.read().decode("utf-8")
        return json.loads(body) if body else None


# ============================================================================
# AGENT 1: JOB BOARD SYNDICATOR
# ============================================================================
class JobBoardSyndicator:
    """Generates high-converting 1099 commission ad copy for 5 target channels."""

    @staticmethod
    def generate_all(audition_url: str = DEFAULT_AUDITION_URL) -> Dict[str, Dict[str, str]]:
        return {
            "craigslist_dfw": {
                "channel": "Craigslist DFW (sales / biz dev & gigs -> talent)",
                "title": "B2B Outbound Opener (DFW Self-Storage) — $0 Cost to Prospect ($40/Site + 20% 12-Mo Residuals)",
                "body": (
                    "We operate Texas Gate Dispatch — a commercial gate & access-control dispatch desk serving 600+ DFW self-storage facilities.\n\n"
                    "WHY THIS CALL CONVERTS:\n"
                    "You are NOT selling a retainer or monthly software subscription. Self-storage managers pay $0 to add us as their backup Vendor-on-File for when their primary gate company is backed up 4+ days.\n\n"
                    "1099 COMPENSATION STRUCTURE:\n"
                    "• $50 Fast-Start Bonus on your first 10 verified Vendor-on-File (VOF) enrollments (free for the facility to sign).\n"
                    "• $40 First-Dispatch Bounty the moment any facility you enrolled places their first paid service call.\n"
                    "• 20% Trailing Residual Commission on every dispatch fee that facility generates for 12 full months.\n"
                    "• Multi-Property Portfolio Multiplier: Enroll 1 regional manager who oversees 8 DFW storage yards and you earn the $40 bounty + 20% residual across ALL 8 ROOFS.\n\n"
                    "WHAT WE PROVIDE:\n"
                    "• Browser-based Calling Console pre-loaded with 600+ scored DFW self-storage leads (including Google Review 'Recent Gate Pain' snippets).\n"
                    "• 1-Click SMS & Email Terms sender + live objection playbook.\n\n"
                    "NO RESUMES OR ZOOM INTERVIEWS.\n"
                    f"Listen to the pitch & record a 30-second storage manager voice audition here:\n{audition_url}"
                ),
            },
            "commissioncrowd_rephunter": {
                "channel": "CommissionCrowd & RepHunter (B2B Independent Sales Reps)",
                "title": "Commercial Gate & Access Control Dispatch — Multi-Property Self-Storage Residuals (Texas)",
                "body": (
                    "Seeking independent 1099 B2B sales reps calling on Self-Storage Operators, Commercial Property Managers, and Industrial Yards in Dallas-Fort Worth.\n\n"
                    "THE HOOK:\n"
                    "Facilities pay $0 upfront to list Texas Gate Dispatch as their primary or backup Vendor-on-File. We charge a flat $89 standard / $149 emergency dispatch coordination fee only when they request a technician.\n\n"
                    "PORTFOLIO RESIDUALS:\n"
                    "• $40 per facility on first paid dispatch + 20% trailing commission for 12 months.\n"
                    "• Full Multi-Site Attribution: One regional manager with 12 DFW properties = 12x bounties ($480) + 12 months of trailing volume across the entire portfolio.\n\n"
                    f"Interactive Commission Calculator & 60-Second Voice Audition:\n{audition_url}"
                ),
            },
            "reddit": {
                "channel": "Reddit (r/forhire, r/sales, r/DFWJobs, r/telemarketing)",
                "title": "[Hiring] (Remote / Texas) B2B Cold Callers for DFW Commercial Gate Dispatch — Zero-Cost Offer ($50 Fast-Start + $40/Site + 20% 12-Mo Residuals)",
                "body": (
                    "We have 600+ scored DFW self-storage facility leads loaded in our browser dialer — many flagged with recent gate/keypad failures from public reviews.\n\n"
                    "The Call: Reach the on-site storage manager or regional supervisor between 9am–4pm CT, read a 30-second opener, and text/email our 1-page Vendor-on-File agreement ($0 cost until they need an emergency gate tech).\n\n"
                    "Pay (1099 Uncapped):\n"
                    "- $50 Fast-Start milestone on your first 10 verified VOF enrollments\n"
                    "- $40 bounty per facility on first paid dispatch\n"
                    "- 20% trailing residual on every dispatch from your book for 12 months (including multi-property operators)\n"
                    "- Realistic 20 hr/wk active book: $2,100–$3,800/mo by Month 3\n\n"
                    f"Skip the resume — complete our 60-second browser voice audition here:\n{audition_url}"
                ),
            },
            "upwork_indeed": {
                "channel": "Upwork (Milestone Contract) / Indeed (1099 Commission Opener)",
                "title": "B2B Cold Caller / Appointment & Vendor-on-File Opener (Commercial Property & Self-Storage)",
                "body": (
                    "Looking for a sharp, zero-fluff B2B phone opener to call Dallas-Fort Worth self-storage facility managers during Texas business hours.\n\n"
                    "Deliverables & Milestones:\n"
                    "1. Milestone 1 ($50 Fast-Start): Complete 10 verified Vendor-on-File (VOF) enrollments using our pre-scored DFW lead queue ($0 cost to the facility).\n"
                    "2. Ongoing Bounties & Residuals: $40 per activated facility + 20% trailing commission on all dispatch fees for 12 months.\n\n"
                    f"To apply, record the 30-second storage manager opener at:\n{audition_url}"
                ),
            },
        }


# ============================================================================
# AGENT 2: OUTBOUND HEADHUNTER & CANDIDATE SCORER
# ============================================================================
class OutboundHeadhunter:
    """Scores 1099 rep candidates (0-100) and generates direct headhunting DMs/SMS."""

    HIGH_VALUE_TAGS = {
        "b2b_cold_calling": 15,
        "commission_only": 12,
        "property_management": 14,
        "texas_local": 10,
        "high_volume_dialer": 10,
        "commercial_trades": 12,
    }

    @classmethod
    def score_candidate(
        cls,
        name: str,
        availability_hrs: int,
        experience_tags: List[str],
        notes: str = "",
        has_voice_sample: bool = False,
    ) -> Dict[str, Any]:
        score = 40  # Base score
        breakdown: Dict[str, int] = {"base": 40}

        if availability_hrs >= 25:
            score += 15
            breakdown["availability_25plus"] = 15
        elif availability_hrs >= 15:
            score += 10
            breakdown["availability_15plus"] = 10
        else:
            score += 4
            breakdown["availability_parttime"] = 4

        for tag in experience_tags:
            t_clean = tag.strip().lower()
            if t_clean in cls.HIGH_VALUE_TAGS:
                pts = cls.HIGH_VALUE_TAGS[t_clean]
                score += pts
                breakdown[f"tag_{t_clean}"] = pts

        if re.search(r"storage|property|roofing|hvac|gate|commercial|b2b|dials|outbound", notes, re.I):
            score += 10
            breakdown["domain_keywords"] = 10

        if has_voice_sample:
            score += 12
            breakdown["voice_sample_recorded"] = 12

        final_score = min(99, score)
        first_name = name.split()[0] if name else "there"
        dm_pitch = (
            f"Hey {first_name} — saw your B2B outbound background. We run Texas Gate Dispatch (600+ DFW self-storage facilities) "
            f"and are adding 2 commission openers. Storage managers pay $0 to list us as their backup gate vendor, and you earn a "
            f"$50 fast-start on your first 10 enrollments + $40/site bounty + 20% 12-mo residuals across multi-site portfolios. "
            f"Skip the interview and try our 60-sec voice audition here: {DEFAULT_AUDITION_URL}"
        )
        return {
            "name": name,
            "score": final_score,
            "tier": "A-Player (Immediate Invite)" if final_score >= 82 else ("B-Player (Review Audio)" if final_score >= 68 else "Nurture"),
            "breakdown": breakdown,
            "headhunter_dm": dm_pitch,
        }


# ============================================================================
# AGENT 3: AUDITION SCREENER & SEEDER
# ============================================================================
SAMPLE_REP_CANDIDATES: List[Dict[str, Any]] = [
    {
        "name": "Marcus Vance",
        "phone": "214-555-0148",
        "email": "marcus.vance.sales@example.com",
        "city": "Arlington, TX",
        "source": "commissioncrowd",
        "availability_hrs": 25,
        "experience_tags": ["b2b_cold_calling", "property_management", "commission_only", "texas_local"],
        "notes": "6 yrs B2B commercial roofing & parking lot striping cold calling across DFW. Already calls property & storage managers daily. Loves the $0-cost Vendor-on-File opener.",
        "score": 94,
        "status": "audition_submitted",
    },
    {
        "name": "Elena Rostova",
        "phone": "972-555-0183",
        "email": "elena.outbound@example.com",
        "city": "Plano, TX",
        "source": "craigslist_dfw",
        "availability_hrs": 30,
        "experience_tags": ["b2b_cold_calling", "high_volume_dialer", "commission_only"],
        "notes": "Former commercial HVAC dispatch setter (120+ dials/day). Looking for uncapped residual book where regional managers control 5–10 locations.",
        "score": 89,
        "status": "audition_submitted",
    },
    {
        "name": "Devon Brooks",
        "phone": "817-555-0129",
        "email": "devon.b.dfw@example.com",
        "city": "Fort Worth, TX",
        "source": "reddit",
        "availability_hrs": 15,
        "experience_tags": ["b2b_cold_calling", "texas_local"],
        "notes": "Sourced via r/DFWJobs. Inside sales rep with weekday mornings free (9am-1pm CT) to dial Tarrant County storage yards.",
        "score": 78,
        "status": "new",
    },
]


# ============================================================================
# AGENT 4: FACILITY LEAD SWEEPER (GATE PAIN SCORER)
# ============================================================================
class FacilityLeadSweeper:
    """Scores self-storage facilities for Gate Pain so 1099 reps always have warm prospects."""

    PAIN_PATTERNS = [
        (r"gate\s+(has\s+been\s+|is\s+|was\s+)?(broken|stuck|open|down|not\s+working)", 35, "recent_gate_broken"),
        (r"keypad\s+(broken|dead|not\s+working|out)", 30, "keypad_failure"),
        (r"locked\s+(in|out)|trapped\s+inside", 35, "tenant_locked_in_out"),
        (r"chain\s+(off|broken)|arm\s+broken|hit\s+the\s+gate", 28, "mechanical_damage"),
        (r"security\s+gate\s+open\s+for\s+(days|weeks|months)", 38, "chronic_gate_down"),
    ]

    @classmethod
    def score_facility(cls, name: str, city: str, review_snippet: str, is_independent: bool = True) -> Dict[str, Any]:
        score = 45
        breakdown: Dict[str, int] = {"base_storage": 45}
        pain_recent = False
        pain_signal = False

        for pattern, pts, label in cls.PAIN_PATTERNS:
            if re.search(pattern, review_snippet, re.I):
                score += pts
                breakdown[label] = pts
                pain_recent = True
                pain_signal = True
                break

        if is_independent:
            score += 15
            breakdown["small_operator"] = 15

        return {
            "name": name,
            "city": city,
            "score": min(99, score),
            "pain_recent": pain_recent,
            "pain_signal": pain_signal,
            "score_breakdown": breakdown,
            "pain_evidence": [{"snippet": review_snippet, "detected_at": datetime.now(timezone.utc).strftime("%Y-%m-%d")}]
            if review_snippet
            else [],
            "status": "new",
        }

    @classmethod
    def sample_dfw_sweep(cls) -> List[Dict[str, Any]]:
        raw = [
            (
                "Lone Star Boat & RV Storage — Denton Hwy",
                "Haltom City",
                "817-555-0194",
                "Front sliding gate has been stuck open for two weeks and the keypad screen is completely blank.",
                True,
            ),
            (
                "Trinity Valley Self Storage",
                "Carrollton",
                "972-555-0162",
                "Great manager on site, but the exit gate chain came off the sprocket again over the weekend.",
                True,
            ),
            (
                "Pioneer Parkway Climate & Drive-Up Storage",
                "Grand Prairie",
                "214-555-0177",
                "Got locked inside after 7pm because the photo-eye sensor on the main gate wouldn't trigger.",
                True,
            ),
        ]
        results = []
        for name, city, phone, snippet, indep in raw:
            item = cls.score_facility(name, city, snippet, indep)
            item["phone"] = phone
            results.append(item)
        return results


# ============================================================================
# CLI ENTRYPOINT
# ============================================================================
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Texas Gate Dispatch — 1099 Recruiting Swarm & Lead-Sweep CLI"
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status", help="Verify Supabase connection and print swarm readiness")

    p_ads = sub.add_parser("generate-ads", help="Generate ready-to-post 1099 commission job ads")
    p_ads.add_argument("--url", default=DEFAULT_AUDITION_URL, help="Live audition.html URL")
    p_ads.add_argument("--json", action="store_true", help="Output as JSON")

    p_score = sub.add_parser("score-rep", help="Score a 1099 sales rep candidate (0-100) and generate DM")
    p_score.add_argument("--name", required=True)
    p_score.add_argument("--hrs", type=int, default=20)
    p_score.add_argument("--tags", default="b2b_cold_calling,commission_only")
    p_score.add_argument("--notes", default="")
    p_score.add_argument("--voice", action="store_true")

    p_seed = sub.add_parser("seed-reps", help="Preview or push sample 1099 rep candidates to Supabase")
    p_seed.add_argument("--push", action="store_true", help="Insert into Supabase public.rep_candidates")

    p_sweep = sub.add_parser("sweep-leads", help="Run DFW Gate-Pain facility lead scorer")
    p_sweep.add_argument("--push", action="store_true", help="Insert into Supabase public.lead_candidates")

    args = parser.parse_args()

    if args.cmd == "status":
        cfg = extract_supabase_config()
        print("=== DISPATCH HQ · RECRUITING SWARM STATUS ===")
        print(f"Workspace Root : {ROOT_DIR}")
        print(f"Supabase URL   : {cfg['url'] or 'MISSING'}")
        print(f"Publishable Key: {(cfg['key'][:22] + '...') if cfg['key'] else 'MISSING'}")
        print(f"Audition Portal: {DEFAULT_AUDITION_URL}")
        print(f"Rep Console    : {DEFAULT_HQ_URL}")
        print(f"Rep Agreement  : {DEFAULT_DOCS_URL}")
        return 0

    if args.cmd == "generate-ads":
        ads = JobBoardSyndicator.generate_all(args.url)
        if args.json:
            print(json.dumps(ads, indent=2))
            return 0
        for key, item in ads.items():
            print("=" * 76)
            print(f"CHANNEL: {item['channel']} [{key}]")
            print(f"TITLE  : {item['title']}")
            print("-" * 76)
            print(item["body"])
            print()
        return 0

    if args.cmd == "score-rep":
        tags = [t.strip() for t in args.tags.split(",") if t.strip()]
        res = OutboundHeadhunter.score_candidate(
            name=args.name,
            availability_hrs=args.hrs,
            experience_tags=tags,
            notes=args.notes,
            has_voice_sample=args.voice,
        )
        print(json.dumps(res, indent=2))
        return 0

    if args.cmd == "seed-reps":
        print(f"Prepared {len(SAMPLE_REP_CANDIDATES)} scored 1099 Sales Rep candidates:")
        print(json.dumps(SAMPLE_REP_CANDIDATES, indent=2))
        if args.push:
            try:
                inserted = supabase_rest("rep_candidates", method="POST", payload=SAMPLE_REP_CANDIDATES)
                print(f"\n[OK] Inserted {len(inserted or [])} candidates into public.rep_candidates.")
            except urllib.error.HTTPError as exc:
                err_body = exc.read().decode("utf-8", errors="ignore")
                print(
                    f"\n[NOTE] Supabase returned HTTP {exc.code}: {err_body}\n"
                    "Make sure you have run supabase/migrations/20261020_rep_sales_force_and_recruiting.sql in the Supabase SQL Editor."
                )
        return 0

    if args.cmd == "sweep-leads":
        leads = FacilityLeadSweeper.sample_dfw_sweep()
        print(f"Scored {len(leads)} DFW Self-Storage facilities with Recent Gate Pain:")
        print(json.dumps(leads, indent=2))
        if args.push:
            try:
                inserted = supabase_rest("lead_candidates", method="POST", payload=leads)
                print(f"\n[OK] Inserted {len(inserted or [])} leads into public.lead_candidates.")
            except urllib.error.HTTPError as exc:
                err_body = exc.read().decode("utf-8", errors="ignore")
                print(f"\n[NOTE] Supabase returned HTTP {exc.code}: {err_body}")
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
