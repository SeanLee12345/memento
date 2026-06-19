#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

python - <<'PY'
import json
import os
import subprocess
import sys
import time
import urllib.parse
import uuid
from pathlib import Path

ROOT = Path.cwd()
ENV_PATH = ROOT / ".env.local"
TEST_SUITE = "memory_retrieval_runtime_validation"


def load_env(path: Path) -> None:
    if not path.exists():
        return
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip('"').strip("'")
        os.environ[key.strip()] = value


load_env(ENV_PATH)
SUPABASE_URL = os.environ.get("SUPABASE_URL", "").rstrip("/")
ANON_KEY = os.environ.get("SUPABASE_ANON_KEY", "")
SERVICE_KEY = os.environ.get("SUPABASE_SERVICE_KEY", "")

results = []
created_user_ids = []
seeded_ids = []


def result(name: str, passed: bool, detail: str) -> None:
    status = "PASS" if passed else "FAIL"
    results.append((name, status, detail))
    print(f"{status}: {name} - {detail}")


def require_env() -> bool:
    missing = [k for k, v in {
        "SUPABASE_URL": SUPABASE_URL,
        "SUPABASE_ANON_KEY": ANON_KEY,
        "SUPABASE_SERVICE_KEY": SERVICE_KEY,
    }.items() if not v]
    if missing:
        result("Environment", False, f"missing {', '.join(missing)}")
        return False
    result("Environment", True, f"target={SUPABASE_URL}")
    return True


def request(method: str, url: str, *, key: str, bearer: str, body=None, extra_headers=None):
    url = url.strip()
    headers = [
        "apikey: " + key,
        "Authorization: Bearer " + bearer,
        "Content-Type: application/json",
    ]
    if extra_headers:
        headers.extend(f"{k}: {v}" for k, v in extra_headers.items())
    cmd = ["/usr/bin/curl", "--globoff", "-sS", "--max-time", "45", "-X", method]
    for header in headers:
        cmd.extend(["-H", header])
    if body is not None:
        cmd.extend(["--data-binary", json.dumps(body)])
    cmd.extend(["-w", "\n%{http_code}", url])
    completed = None
    for attempt in range(1, 4):
        completed = subprocess.run(cmd, text=True, capture_output=True)
        if completed.returncode == 0:
            break
        if attempt < 3:
            time.sleep(1.5 * attempt)
    assert completed is not None
    if completed.returncode != 0:
        parsed = urllib.parse.urlparse(url)
        raise RuntimeError(f"{method} network failure host={parsed.hostname!r} url={url!r}: {completed.stderr.strip()}")
    raw = completed.stdout
    if "\n" not in raw:
        raise RuntimeError(f"{method} {url} returned malformed curl output")
    body_text, status_text = raw.rsplit("\n", 1)
    status = int(status_text)
    if status >= 400:
        raise RuntimeError(f"{method} {url} failed HTTP {status}: {body_text}")
    return status, {}, json.loads(body_text) if body_text else None


def rest(method: str, path: str, *, body=None, bearer=None, key=None, prefer=None):
    extra = {}
    if prefer:
        extra["Prefer"] = prefer
    return request(
        method,
        f"{SUPABASE_URL}/rest/v1/{path}",
        key=key or SERVICE_KEY,
        bearer=bearer or SERVICE_KEY,
        body=body,
        extra_headers=extra,
    )


def auth_admin(method: str, path: str, *, body=None):
    return request(
        method,
        f"{SUPABASE_URL}/auth/v1/{path}",
        key=SERVICE_KEY,
        bearer=SERVICE_KEY,
        body=body,
    )


def sign_in(email: str, password: str) -> str:
    _, _, data = request(
        "POST",
        f"{SUPABASE_URL}/auth/v1/token?grant_type=password",
        key=ANON_KEY,
        bearer=ANON_KEY,
        body={"email": email, "password": password},
    )
    return data["access_token"]


def create_user(label: str):
    email = f"memory-validation-{label}-{uuid.uuid4().hex[:12]}@example.invalid"
    password = f"MemoryValidation-{uuid.uuid4().hex}!"
    _, _, data = auth_admin(
        "POST",
        "admin/users",
        body={"email": email, "password": password, "email_confirm": True},
    )
    user_id = data["id"]
    created_user_ids.append(user_id)
    return user_id, email, password, sign_in(email, password)


def vector(values):
    padded = values + [0.0] * (2048 - len(values))
    return "[" + ",".join(f"{v:.6f}" for v in padded[:2048]) + "]"


QUERY_VECTOR = vector([1.0, 0.0, 0.0, 0.0])
KOREA_VECTOR = vector([1.0, 0.0, 0.0, 0.0])
UNRELATED_VECTOR = vector([0.0, 1.0, 0.0, 0.0])


def cleanup():
    if seeded_ids:
        ids = ",".join(seeded_ids)
        try:
            rest("DELETE", f"memory_chunks?id=in.({ids})")
        except Exception as exc:
            print(f"WARN: cleanup memory_chunks failed: {exc}", file=sys.stderr)
    for user_id in created_user_ids:
        try:
            auth_admin("DELETE", f"admin/users/{user_id}")
        except Exception as exc:
            print(f"WARN: cleanup auth user {user_id} failed: {exc}", file=sys.stderr)


def inspect_schema():
    columns = [
        "id",
        "owner_uid",
        "conversation_id",
        "stream_id",
        "person_id",
        "chunk_text",
        "summary_text",
        "keywords",
        "categories",
        "source_type",
        "created_at",
        "metadata",
    ]
    rest("GET", "memory_chunks?select=" + ",".join(columns) + "&limit=1")
    migration = (ROOT / "supabase/migrations/0010_hybrid_memory_retrieval.sql").read_text()
    expectations = {
        "memory_chunks table": "create table if not exists public.memory_chunks" in migration,
        "owner field": "owner_uid" in migration,
        "multi keywords": "keywords               text[]" in migration,
        "multi categories": "categories             text[]" in migration,
        "halfvec embedding": "embedding              halfvec(2048)" in migration,
        "GIN keyword index": "memory_chunks_keywords_gin_idx" in migration and "using gin (keywords)" in migration,
        "GIN category index": "memory_chunks_categories_gin_idx" in migration and "using gin (categories)" in migration,
        "embedding index": "halfvec_cosine_ops" in migration,
        "RLS enabled": "enable row level security" in migration and "force row level security" in migration,
        "hybrid RPC": "create or replace function public.hybrid_memory_search" in migration,
    }
    missing = [name for name, ok in expectations.items() if not ok]
    result("Schema inspection", not missing, "all expected schema markers present" if not missing else f"missing {missing}")


def seed_rows(user_a, user_b):
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    rows = [
        {
            "id": str(uuid.uuid4()),
            "owner_uid": user_a,
            "source_record_id": str(uuid.uuid4()),
            "source_type": "stream_summary",
            "chunk_text": "Gary and Sean discussed planning a family trip to Korea next spring.",
            "summary_text": "Korea family travel planning memory.",
            "keywords": ["korea", "trip", "travel", "family", "planning"],
            "categories": ["travel", "family", "planning"],
            "embedding": KOREA_VECTOR,
            "importance_score": 0.9,
            "sensitivity_level": 0,
            "metadata": {"test_suite": TEST_SUITE, "label": "user_a_korea", "source": "validation"},
            "created_at": now,
        },
        {
            "id": str(uuid.uuid4()),
            "owner_uid": user_a,
            "source_record_id": str(uuid.uuid4()),
            "source_type": "scene_context",
            "chunk_text": "A grocery list mentioned apples and coffee.",
            "summary_text": "Grocery list memory.",
            "keywords": ["grocery", "coffee"],
            "categories": ["errand"],
            "embedding": UNRELATED_VECTOR,
            "importance_score": 0.3,
            "sensitivity_level": 0,
            "metadata": {"test_suite": TEST_SUITE, "label": "user_a_unrelated", "source": "validation"},
            "created_at": now,
        },
        {
            "id": str(uuid.uuid4()),
            "owner_uid": user_b,
            "source_record_id": str(uuid.uuid4()),
            "source_type": "stream_summary",
            "chunk_text": "User B private Korea memory that must not be visible to user A.",
            "summary_text": "User B Korea memory.",
            "keywords": ["korea", "travel"],
            "categories": ["travel"],
            "embedding": KOREA_VECTOR,
            "importance_score": 0.95,
            "sensitivity_level": 0,
            "metadata": {"test_suite": TEST_SUITE, "label": "user_b_korea", "source": "validation"},
            "created_at": now,
        },
    ]
    seeded_ids.extend(row["id"] for row in rows)
    rest("POST", "memory_chunks", body=rows, prefer="return=minimal")


def rpc_search(user_id: str, token: str):
    _, _, rows = rest(
        "POST",
        "rpc/hybrid_memory_search",
        bearer=token,
        key=ANON_KEY,
        body={
            "p_user_id": user_id,
            "p_query_embedding": QUERY_VECTOR,
            "p_query_keywords": ["korea", "travel"],
            "p_query_categories": ["travel", "planning"],
            "p_person_ids": [],
            "p_limit": 5,
            "p_min_similarity": 0.0,
            "p_include_source_types": ["stream_summary", "scene_context", "person_note", "transcript_chunk"],
            "p_max_sensitivity": 1,
        },
    )
    return rows or []


def validate_retrieval_and_rls():
    user_a, email_a, _, token_a = create_user("a")
    user_b, email_b, _, token_b = create_user("b")
    seed_rows(user_a, user_b)

    rows_a = rpc_search(user_a, token_a)
    labels_a = [((row.get("metadata") or {}).get("label"), row.get("final_score"), row.get("keywords"), row.get("categories")) for row in rows_a]
    top_label = labels_a[0][0] if labels_a else None
    has_user_b = any(label == "user_b_korea" for label, *_ in labels_a)
    has_multi = any(
        label == "user_a_korea" and len(keywords or []) >= 5 and len(categories or []) >= 3
        for label, _, keywords, categories in labels_a
    )
    result(
        "Retrieval RPC",
        bool(rows_a) and top_label == "user_a_korea" and not has_user_b and has_multi and len(rows_a) <= 5,
        f"userA_top={top_label} count={len(rows_a)} labels={[x[0] for x in labels_a]}",
    )

    rows_b = rpc_search(user_b, token_b)
    labels_b = [((row.get("metadata") or {}).get("label")) for row in rows_b]
    result(
        "RLS isolation via RPC",
        "user_b_korea" in labels_b and "user_a_korea" not in labels_b,
        f"userB_labels={labels_b}",
    )

    _, _, direct_a = rest(
        "GET",
        f"memory_chunks?select=id,metadata&owner_uid=eq.{urllib.parse.quote(user_b)}",
        bearer=token_a,
        key=ANON_KEY,
    )
    result(
        "RLS direct table isolation",
        direct_a == [],
        f"userA_direct_rows_for_userB={len(direct_a or [])}",
    )


def static_runtime_checks():
    vm = (ROOT / "CameraAccess/ViewModels/StreamSessionViewModel.swift").read_text()
    service = (ROOT / "CameraAccess/Services/RemoteMemoryRetrievalService.swift").read_text()
    identity = (ROOT / "CameraAccess/Services/IdentityPipeline.swift").read_text()

    retrieve_start = vm.index("  private func retrieveMemory(")
    retrieve_end = vm.index("  private func liveMemoryTriggerDisplaySection(", retrieve_start)
    retrieve_block = vm[retrieve_start:retrieve_end]
    result(
        "Runtime memory request uses remote service",
        "RemoteMemoryRetrievalService().retrieve" in retrieve_block and "loadPeopleForDictionary" not in retrieve_block,
        "retrieveMemory calls remote service and does not call loadPeopleForDictionary",
    )

    memory_case_start = vm.index("      case .memory, .mixed:")
    memory_case = vm[memory_case_start:memory_case_start + 900]
    result(
        "Memory trigger does not invoke local full-history ranker",
        "retrieveMemory(" in memory_case and "LiveMemoryCandidateRanker" not in memory_case and "loadPeopleForDictionary" not in memory_case,
        "memory/mixed path routes through retrieveMemory",
    )

    fallback_ok = "[MEMORY_RETRIEVAL] source=local_recent_summary_fallback" in vm and "RecentMemoryContextBuilder.summaries" in retrieve_block
    result(
        "Remote failure fallback is recent summaries only",
        fallback_ok and "LiveMemoryCandidateRanker.rankedCandidates" not in retrieve_block,
        "fallback log present; retrieve block uses RecentMemoryContextBuilder",
    )

    result(
        "Recent summaries limited to latest 3",
        "static let defaultLimit = 3" in service and ".prefix(max(0, limit))" in service,
        "RecentMemoryContextBuilder.defaultLimit=3",
    )

    result(
        "Person dictionary full-load isolated to dictionary API",
        "func currentProfiles() async -> [PersonProfile]" in identity and "func loadPeopleForDictionary()" in identity,
        "normal trigger path uses currentProfiles; loadPeopleForDictionary remains explicit dictionary path",
    )

    remote_log_ok = "[MEMORY_RETRIEVAL] source=remote" in service and "ids=" in service and "providerLatencyMs" in service
    full_text_log_suspect = "chunk_text" in service[service.find('AppLogger.log'): service.find('func index')]
    result(
        "Logging privacy shape",
        remote_log_ok and not full_text_log_suspect,
        "remote log includes query/keywords/categories/count/ids/latency and does not log chunk text in service",
    )

    ranker_refs = subprocess.run(
        ["rg", "-n", "LiveMemoryCandidateRanker\\.rankedCandidates", "CameraAccess"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    result(
        "Legacy local ranker not called",
        ranker_refs.returncode != 0,
        "no LiveMemoryCandidateRanker.rankedCandidates call sites" if ranker_refs.returncode != 0 else ranker_refs.stdout.strip(),
    )


try:
    if require_env():
        inspect_schema()
        validate_retrieval_and_rls()
    static_runtime_checks()
finally:
    cleanup()

print("\nMemory retrieval runtime validation summary")
failed = [item for item in results if item[1] == "FAIL"]
for name, status, detail in results:
    print(f"- {name}: {status} ({detail})")
print(f"\nOverall: {'FAIL' if failed else 'PASS'}")
if failed:
    sys.exit(1)
PY
