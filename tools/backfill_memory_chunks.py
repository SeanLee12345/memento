#!/usr/bin/env python3
"""Backfill Supabase transcript and scene-context rows into memory_chunks.

Usage:
  python tools/backfill_memory_chunks.py --dry-run
  python tools/backfill_memory_chunks.py

Secrets are read from the environment or the ignored .env.local file. The
service-role key is used only by this laptop command and is never shipped in iOS.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
EMBEDDING_MODEL = os.environ.get("NVIDIA_EMBEDDING_MODEL", "nvidia/llama-nemotron-embed-1b-v2")
MEMORY_NAMESPACE = uuid.UUID("4d22d1a0-2208-4fc5-92ab-d75d0ec65e30")
STOP_WORDS = {
    "about", "after", "again", "also", "and", "are", "did", "does", "for",
    "from", "have", "how", "last", "that", "the", "this", "time", "was",
    "were", "what", "when", "where", "who", "why", "with", "you", "your",
}


@dataclass
class Candidate:
    id: str
    owner_uid: str
    source_record_id: str
    source_type: str
    conversation_id: str | None
    stream_id: str | None
    person_id: str | None
    chunk_text: str
    summary_text: str | None
    start_time: str | None
    end_time: str | None
    created_at: str
    metadata: dict[str, Any]


def load_dotenv() -> None:
    path = ROOT / ".env.local"
    if not path.exists():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"{name} is required")
    return value


def request_json(
    url: str,
    *,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    body: Any | None = None,
    timeout: int = 60,
) -> Any:
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode("utf-8")
    merged = {"Accept": "application/json", **(headers or {})}
    if data is not None:
        merged["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=merged)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            payload = response.read()
            return json.loads(payload) if payload else None
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")[:500]
        raise RuntimeError(f"HTTP {error.code} for {url}: {detail}") from error


def service_headers(service_key: str) -> dict[str, str]:
    return {"apikey": service_key, "Authorization": f"Bearer {service_key}"}


def fetch_all(base_url: str, service_key: str, table: str, query: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    page_size = 1000
    for offset in range(0, 100_000, page_size):
        url = f"{base_url}/rest/v1/{table}?{query}&limit={page_size}&offset={offset}"
        page = request_json(url, headers=service_headers(service_key)) or []
        rows.extend(page)
        if len(page) < page_size:
            return rows
    raise RuntimeError(f"Pagination guard exceeded for {table}")


def useful_text(text: str) -> bool:
    normalized = re.sub(r"[^\w\s]", " ", text.lower(), flags=re.UNICODE)
    normalized = " ".join(normalized.split())
    if len(normalized) < 12:
        return False
    return normalized not in {"no speech detected", "listening", "thank you", "uh um", "um uh"}


def split_text(text: str, max_chars: int = 1200) -> list[str]:
    text = " ".join(text.split())
    if len(text) <= max_chars:
        return [text]
    sentences = re.split(r"(?<=[.!?])\s+", text)
    chunks: list[str] = []
    current = ""
    for sentence in sentences:
        if current and len(current) + len(sentence) + 1 > max_chars:
            chunks.append(current)
            current = sentence
        else:
            current = f"{current} {sentence}".strip()
    if current:
        chunks.append(current)
    return chunks


def resolved_owner(
    row: dict[str, Any],
    owner_by_session: dict[str, str],
    owner_by_run: dict[str, str],
    legacy_owner: str | None,
) -> str | None:
    return (
        row.get("owner_uid")
        or owner_by_session.get(str(row.get("conversation_session_id") or ""))
        or owner_by_run.get(str(row.get("app_run_id") or ""))
        or legacy_owner
    )


def transcript_candidates(
    rows: Iterable[dict[str, Any]],
    owner_by_session: dict[str, str],
    owner_by_run: dict[str, str],
    legacy_owner: str | None,
) -> list[Candidate]:
    output: list[Candidate] = []
    for row in rows:
        owner_uid = resolved_owner(row, owner_by_session, owner_by_run, legacy_owner)
        if not row.get("is_final") or not owner_uid:
            continue
        for index, text in enumerate(split_text(str(row.get("text") or ""))):
            if not useful_text(text):
                continue
            source_id = str(row["id"])
            output.append(Candidate(
                id=str(uuid.uuid5(MEMORY_NAMESPACE, f"transcript_chunk:{source_id}:{index}")),
                owner_uid=str(owner_uid),
                source_record_id=source_id if index == 0 else str(uuid.uuid5(MEMORY_NAMESPACE, f"source:{source_id}:{index}")),
                source_type="transcript_chunk",
                conversation_id=row.get("conversation_session_id"),
                stream_id=row.get("conversation_session_id"),
                person_id=row.get("person_id"),
                chunk_text=text,
                summary_text=None,
                start_time=row.get("started_at"),
                end_time=row.get("ended_at"),
                created_at=row.get("created_at") or row.get("transcript_updated_at"),
                metadata={"source": row.get("source") or "unknown", "segment_index": index},
            ))
    return output


def scene_candidates(
    rows: Iterable[dict[str, Any]],
    owner_by_session: dict[str, str],
    owner_by_run: dict[str, str],
    legacy_owner: str | None,
) -> list[Candidate]:
    output: list[Candidate] = []
    seen: set[tuple[str, str]] = set()
    for row in rows:
        owner_uid = resolved_owner(row, owner_by_session, owner_by_run, legacy_owner)
        if not owner_uid:
            continue
        if float(row.get("confidence") or 0) < 0.55:
            continue
        text = "\n".join(filter(None, [
            row.get("summary"),
            f"Where: {row.get('where_text')}" if row.get("where_text") else None,
            f"What: {row.get('what')}" if row.get("what") else None,
            f"Why: {row.get('why')}" if row.get("why") else None,
        ]))
        if not useful_text(text):
            continue
        dedupe_key = (
            str(row.get("conversation_session_id") or row.get("app_run_id") or "none"),
            " ".join(str(row.get("summary") or "").lower().split()),
        )
        if dedupe_key in seen:
            continue
        seen.add(dedupe_key)
        source_id = str(row["id"])
        output.append(Candidate(
            id=str(uuid.uuid5(MEMORY_NAMESPACE, f"scene_context:{source_id}")),
            owner_uid=str(owner_uid),
            source_record_id=source_id,
            source_type="scene_context",
            conversation_id=row.get("conversation_session_id"),
            stream_id=row.get("conversation_session_id"),
            person_id=row.get("person_id"),
            chunk_text=text,
            summary_text=row.get("summary"),
            start_time=row.get("started_at"),
            end_time=row.get("ended_at"),
            created_at=row.get("created_at") or row.get("started_at"),
            metadata={"model": row.get("model_name") or "unknown"},
        ))
    return output


def local_classification(text: str) -> dict[str, Any]:
    terms = re.findall(r"[\w'-]{3,}", text.lower(), flags=re.UNICODE)
    keywords = list(dict.fromkeys(term for term in terms if term not in STOP_WORDS))[:12]
    category_terms = {
        "travel": {"trip", "travel", "flight", "hotel", "vacation", "korea", "japan"},
        "work": {"work", "job", "meeting", "project", "resume", "internship"},
        "family": {"family", "mother", "father", "parent", "sister", "brother"},
        "health": {"health", "doctor", "medical", "medicine", "hospital"},
        "planning": {"plan", "planning", "schedule", "book", "booking", "reminder"},
    }
    categories = [name for name, values in category_terms.items() if values.intersection(keywords)]
    sensitivity = 2 if "health" in categories else 1 if "family" in categories else 0
    return {"keywords": keywords, "categories": categories, "importanceScore": 0.5, "sensitivityLevel": sensitivity}


def classify_batch(candidates: list[Candidate], dashscope_key: str | None) -> list[dict[str, Any]]:
    fallbacks = [local_classification(item.chunk_text) for item in candidates]
    if not dashscope_key:
        return fallbacks
    prompt_items = [{"index": index, "text": item.chunk_text[:1800]} for index, item in enumerate(candidates)]
    body = {
        "model": os.environ.get("DASHSCOPE_TEXT_MODEL", "qwen3.5-flash"),
        "messages": [
            {"role": "system", "content": "Classify private-memory excerpts. Return strict JSON only; do not infer facts."},
            {"role": "user", "content": (
                "Return {\"items\":[{\"index\":0,\"keywords\":[],\"categories\":[],"
                "\"importanceScore\":0.5,\"sensitivityLevel\":0}]}. "
                "Lowercase terms; max 12 keywords and 8 categories. sensitivityLevel: 0 routine, 1 personal, 2 highly sensitive.\n"
                + json.dumps(prompt_items, ensure_ascii=False)
            )},
        ],
        "temperature": 0,
        "max_tokens": 1600,
        "enable_thinking": False,
    }
    try:
        response = request_json(
            os.environ.get("DASHSCOPE_BASE_URL", "https://dashscope-us.aliyuncs.com/compatible-mode/v1").rstrip("/") + "/chat/completions",
            method="POST",
            headers={"Authorization": f"Bearer {dashscope_key}"},
            body=body,
        )
        content = response["choices"][0]["message"]["content"]
        parsed = json.loads(content[content.index("{"):content.rindex("}") + 1])
        by_index = {int(item["index"]): item for item in parsed.get("items", [])}
        return [by_index.get(index, fallback) for index, fallback in enumerate(fallbacks)]
    except Exception as error:  # noqa: BLE001
        print(f"classification fallback: {error}", file=sys.stderr)
        return fallbacks


def embed_batch(texts: list[str], nvidia_key: str) -> list[list[float]]:
    response = request_json(
        os.environ.get("NVIDIA_EMBEDDING_URL", "https://integrate.api.nvidia.com/v1/embeddings"),
        method="POST",
        headers={"Authorization": f"Bearer {nvidia_key}"},
        body={
            "model": EMBEDDING_MODEL,
            "input": texts,
            "input_type": "passage",
            "encoding_format": "float",
            "truncate": "END",
        },
    )
    vectors = [item["embedding"] for item in sorted(response["data"], key=lambda item: item["index"])]
    if any(len(vector) != 2048 for vector in vectors):
        raise RuntimeError("NVIDIA returned an unexpected embedding dimension")
    return vectors


def batches(items: list[Candidate], size: int) -> Iterable[list[Candidate]]:
    for index in range(0, len(items), size):
        yield items[index:index + size]


def main() -> None:
    load_dotenv()
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--limit", type=int, default=0, help="Limit candidates for a test run")
    parser.add_argument("--legacy-owner", help="Assign otherwise-unowned legacy rows to this auth user without modifying source rows")
    parser.add_argument("--skip-qwen", action="store_true", help="Use deterministic local metadata extraction for a faster bulk pass")
    args = parser.parse_args()

    base_url = required_env("SUPABASE_URL").rstrip("/")
    service_key = required_env("SUPABASE_SERVICE_KEY")
    nvidia_key = required_env("NVIDIA_API_KEY")
    dashscope_key = None if args.skip_qwen else (os.environ.get("DASHSCOPE_API_KEY", "").strip() or None)

    transcript_rows = fetch_all(
        base_url,
        service_key,
        "transcript_chunks",
        urllib.parse.urlencode({
            "select": "id,owner_uid,app_run_id,conversation_session_id,person_id,text,is_final,started_at,ended_at,transcript_updated_at,source,created_at",
            "is_final": "eq.true",
            "order": "created_at.asc",
        }),
    )
    scene_rows = fetch_all(
        base_url,
        service_key,
        "scene_context_records",
        urllib.parse.urlencode({
            "select": "id,owner_uid,app_run_id,conversation_session_id,person_id,summary,where_text,what,why,started_at,ended_at,created_at,model_name,confidence",
            "order": "created_at.asc",
        }),
    )
    session_rows = fetch_all(
        base_url,
        service_key,
        "conversation_sessions",
        urllib.parse.urlencode({"select": "id,owner_uid", "order": "created_at.asc"}),
    )
    app_run_rows = fetch_all(
        base_url,
        service_key,
        "app_runs",
        urllib.parse.urlencode({"select": "id,owner_uid", "order": "created_at.asc"}),
    )
    owner_by_session = {
        str(row["id"]): str(row["owner_uid"])
        for row in session_rows if row.get("owner_uid")
    }
    owner_by_run = {
        str(row["id"]): str(row["owner_uid"])
        for row in app_run_rows if row.get("owner_uid")
    }
    candidates = transcript_candidates(transcript_rows, owner_by_session, owner_by_run, args.legacy_owner)
    candidates += scene_candidates(scene_rows, owner_by_session, owner_by_run, args.legacy_owner)
    if args.limit > 0:
        candidates = candidates[:args.limit]
    print(f"candidates={len(candidates)} transcripts={len(transcript_rows)} scene_contexts={len(scene_rows)} dry_run={args.dry_run}", flush=True)
    if args.dry_run or not candidates:
        return

    completed = 0
    for batch in batches(candidates, 32):
        classifications = classify_batch(batch, dashscope_key)
        vectors = embed_batch([
            "\n".join(filter(None, [item.summary_text, item.chunk_text]))[:7000]
            for item in batch
        ], nvidia_key)
        rows = []
        for item, classification, vector in zip(batch, classifications, vectors):
            rows.append({
                **item.__dict__,
                "keywords": [str(value).lower().strip() for value in classification.get("keywords", []) if str(value).strip()][:12],
                "categories": [str(value).lower().strip() for value in classification.get("categories", []) if str(value).strip()][:8],
                "embedding": json.dumps(vector, separators=(",", ":")),
                "embedding_model": EMBEDDING_MODEL,
                "importance_score": max(0, min(float(classification.get("importanceScore", 0.5)), 1)),
                "sensitivity_level": max(0, min(int(classification.get("sensitivityLevel", 0)), 2)),
                "updated_at": item.created_at,
            })
        url = base_url + "/rest/v1/memory_chunks?on_conflict=owner_uid,source_type,source_record_id"
        request_json(
            url,
            method="POST",
            headers={
                **service_headers(service_key),
                "Prefer": "resolution=merge-duplicates,return=minimal",
            },
            body=rows,
        )
        completed += len(batch)
        print(f"backfilled={completed}/{len(candidates)}", flush=True)
        time.sleep(0.1)


if __name__ == "__main__":
    main()
