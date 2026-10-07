#!/usr/bin/env python3
"""부하테스트 전용 사용자 SQL과 JWT를 만든다.

모여타 로그인은 Kakao OAuth뿐이라 부하 발생기가 수천 명의 토큰을 받을 방법이 없다.
백엔드는 HS256 + issuer=moyeota + sub=userId + exp만 검증하므로(JwtConfig, AccessTokenProvider)
테스트 서버의 JWT_SECRET으로 같은 형식의 토큰을 직접 발급한다.

  JWT_SECRET=... python3 tools/make-users.py --count 2600 --start-id 900001 --ttl-hours 12

출력 (기본 ./data, Git 제외 대상):
  data/users.json        [{"id": 900001, "token": "..."}]   ← k6 seed/시나리오 입력
  data/seed-users.sql    users INSERT (MySQL 컨테이너에서 실행)
  data/cleanup.sql       테스트 사용자가 만든 데이터 일괄 삭제
토큰만 다시 발급하려면 --tokens-only.
운영(Prod) DB의 JWT_SECRET으로는 절대 실행하지 않는다.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import time


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def mint(secret: str, issuer: str, user_id: int, ttl_seconds: int, now: int) -> str:
    header = b64url(json.dumps({"alg": "HS256"}, separators=(",", ":")).encode())
    payload = b64url(json.dumps({
        "iss": issuer,
        "sub": str(user_id),
        "iat": now,
        "exp": now + ttl_seconds,
    }, separators=(",", ":")).encode())
    signing_input = f"{header}.{payload}".encode()
    signature = b64url(hmac.new(secret.encode(), signing_input, hashlib.sha256).digest())
    return f"{header}.{payload}.{signature}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=2600)
    parser.add_argument("--start-id", type=int, default=900001)
    parser.add_argument("--ttl-hours", type=float, default=12)
    parser.add_argument("--issuer", default="moyeota")
    parser.add_argument("--out-dir", default=os.path.join(os.path.dirname(__file__), "..", "data"))
    parser.add_argument("--tokens-only", action="store_true")
    args = parser.parse_args()

    secret = os.environ.get("JWT_SECRET")
    if not secret:
        print("JWT_SECRET 환경변수가 필요합니다 (테스트 서버 backend.env 값).", file=sys.stderr)
        return 1
    if len(secret.encode()) < 32:
        print("경고: HS256 키가 32바이트 미만입니다. 서버 설정과 같은지 확인하세요.", file=sys.stderr)

    os.makedirs(args.out_dir, exist_ok=True)
    now = int(time.time())
    ttl = int(args.ttl_hours * 3600)
    end_id = args.start_id + args.count - 1
    users = [{"id": uid, "token": mint(secret, args.issuer, uid, ttl, now)}
             for uid in range(args.start_id, end_id + 1)]

    with open(os.path.join(args.out_dir, "users.json"), "w") as f:
        json.dump({"start_id": args.start_id, "end_id": end_id, "issued_at": now,
                   "expires_at": now + ttl, "users": users}, f)

    if not args.tokens_only:
        rows = []
        for i, uid in enumerate(range(args.start_id, end_id + 1)):
            gender = "MALE" if i % 2 == 0 else "FEMALE"
            rows.append(f"({uid}, 'load{uid}', 'lt_{uid}', '{gender}', NOW(6), NOW(6))")
        with open(os.path.join(args.out_dir, "seed-users.sql"), "w") as f:
            f.write("-- 부하테스트 전용 사용자. id 범위로 식별/삭제한다.\n")
            f.write(f"-- range: {args.start_id}..{end_id}\n")
            for start in range(0, len(rows), 500):
                f.write("INSERT INTO users (id, name, nickname, gender, created_at, updated_at) VALUES\n")
                f.write(",\n".join(rows[start:start + 500]))
                f.write(";\n")

        r = f"BETWEEN {args.start_id} AND {end_id}"
        cleanup = f"""-- 부하테스트 데이터 정리 (users.id {r}). 테스트 서버에서만 실행한다.
CREATE TEMPORARY TABLE lt_companions AS SELECT id FROM companions WHERE creator_id {r} OR host_id {r};
CREATE TEMPORARY TABLE lt_rooms AS SELECT id FROM chat_rooms WHERE companion_id IN (SELECT id FROM lt_companions);
CREATE TEMPORARY TABLE lt_posts AS SELECT id FROM community_posts WHERE author_id {r};
UPDATE companion_participants SET last_read_message_id = NULL
 WHERE user_id {r} OR companion_id IN (SELECT id FROM lt_companions);
UPDATE chat_rooms SET last_message_id = NULL WHERE id IN (SELECT id FROM lt_rooms);
DELETE FROM messages WHERE room_id IN (SELECT id FROM lt_rooms) OR sender_id {r};
DELETE FROM companion_participants WHERE user_id {r} OR companion_id IN (SELECT id FROM lt_companions);
DELETE FROM chat_rooms WHERE id IN (SELECT id FROM lt_rooms);
DELETE FROM companions WHERE id IN (SELECT id FROM lt_companions);
DELETE FROM community_comments WHERE author_id {r} OR post_id IN (SELECT id FROM lt_posts);
DELETE FROM community_posts WHERE id IN (SELECT id FROM lt_posts);
DELETE FROM users WHERE id {r};
"""
        with open(os.path.join(args.out_dir, "cleanup.sql"), "w") as f:
            f.write(cleanup)

    print(f"users {args.start_id}..{end_id} ({args.count}) → {os.path.abspath(args.out_dir)}")
    print(f"token expires in {args.ttl_hours}h")
    return 0


if __name__ == "__main__":
    sys.exit(main())
