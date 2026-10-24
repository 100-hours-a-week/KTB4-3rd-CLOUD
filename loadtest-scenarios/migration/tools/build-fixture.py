#!/usr/bin/env python3
"""Build the migration/cutover.js inputs from real/seed.js outputs.

The API seeder creates test-only rows on the source environment. This tool only
joins its fixture with the matching token file; it does not create or query DB
data. Keep the generated files under loadtest-scenarios/out (gitignored).
"""
import argparse
import json
import os
import sys
from datetime import datetime, timezone


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--seed-fixture", required=True, help="real/seed.js FIXTURE_OUT JSON")
    p.add_argument("--users", required=True, help="real/tools/make-users.py users.json")
    p.add_argument("--base-url", required=True, help="exact V1 API origin used by seed.js")
    p.add_argument("--fixture-out", required=True)
    p.add_argument("--users-out", required=True)
    a = p.parse_args()

    seed = read_json(a.seed_fixture)
    token_file = read_json(a.users)
    users = token_file.get("users", [])
    ids = {int(u["id"]) for u in users}
    if not users or len(ids) != len(users) or any(not u.get("token") for u in users):
        p.error("users JSON must contain unique user IDs and non-empty tokens")

    # real/seed.js records room members as positions in users.json; cutover.js looks tokens up by user ID.
    def member_id(value):
        v = int(value)
        if v in ids:
            return v
        if 0 <= v < len(users):
            return int(users[v]["id"])
        p.error("room member IDs must exist in the supplied users.json")

    rooms = seed.get("rooms", [])
    companions = seed.get("companions", [])
    posts = seed.get("community_posts", [])
    if not companions or not posts:
        p.error("seed fixture has no companion or community read targets; run real/seed.js first")
    for room in rooms:
        if not room.get("room_id") or not room.get("companion_id") or not room.get("members"):
            p.error("each seeded room must have room_id, companion_id, and members")
        room["members"] = [member_id(m) for m in room["members"]]

    busy = {int(uid) for room in rooms for uid in room["members"]}
    active_ids = sorted(ids)
    joinable = [int(cid) for cid in companions if int(cid) not in {int(r["companion_id"]) for r in rooms}]
    if not joinable:
        p.error("no unfilled companion posts available for join writes")

    fixture = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "base_url": a.base_url.rstrip("/"),
        "source": "real/seed.js API-created test data",
        "users": {"active_ids": active_ids, "free_ids": sorted(ids - busy)},
        "chat_rooms_active": rooms,
        # The seeder creates these as recruiting posts with spare seats.
        "companions_joinable": [{"companion_id": cid, "free_seats": 1, "members": []} for cid in joinable],
        "read_targets": {
            "companion_ids": [int(cid) for cid in companions],
            "community_post_ids": [int(pid) for pid in posts],
            "chat_rooms_with_members": [
                {"room_id": r["room_id"], "member": r["members"][0], "status": "IN_PROGRESS"}
                for r in rooms
            ],
        },
    }
    for path, value in ((a.fixture_out, fixture), (a.users_out, token_file)):
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(value, f, ensure_ascii=False, indent=2)
            f.write("\n")
    print(f"fixture: users={len(active_ids)} rooms={len(rooms)} joinable={len(joinable)} posts={len(posts)}")
    print(f"wrote {a.fixture_out} and {a.users_out}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, TypeError) as e:
        print(f"build-fixture: {e}", file=sys.stderr)
        raise SystemExit(2)
