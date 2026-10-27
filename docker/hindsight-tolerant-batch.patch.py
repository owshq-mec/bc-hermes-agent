#!/usr/bin/env python3
"""Build-time patch: make Hindsight's consolidation response parsing tolerant
of a bare JSON list.

WHY
---
Consolidation asks the LLM for a strict object
    {"creates": [...], "updates": [...], "deletes": [...]}
Several models -- including glm-5.2, which OmniRoute's `auto/best-free` combo
selects -- instead echo the input observations back as a bare LIST. Pydantic
then rejects the whole batch:

    ValidationError: 1 validation error for _ConstrainedConsolidationBatchResponse
      Input should be a valid dictionary ... input_type=list

`ValidationError` is classified FAIL_FAST (consolidator.py ~3621), so there is
no retry rescue -- by design, since consolidation pins temperature 0.0 and a
re-send is byte-identical. The batch is bisected and ultimately abandoned, after
burning a full generation per attempt (measured: 47-150 s each).

This patch adds a `model_validator(mode="before")` to the BASE response model.
`_ConstrainedConsolidationBatchResponse` subclasses it, so one hook covers both.

SAFETY DECISIONS (deliberately conservative)
--------------------------------------------
1. An entry with no usable `text` is DROPPED, not coerced. Parroted input rows
   look like {"id": "...", "created_at": "..."} -- there is no defensible action
   to build from them. Dropping yields a clean no-op batch instead of a hard
   failure, which stops the error, the bisection and the wasted tokens. It does
   NOT invent writes.
2. `observation_id` is honoured ONLY when the model used that exact key. A bare
   `id` is NOT mapped onto it. In a parroted row `id` is a *fact* id, and
   treating it as an *observation* id would rewrite the wrong record. Such an
   entry becomes a create instead, which is non-destructive (and if it cites no
   batch fact, the existing pipeline discards it anyway).

FAILS LOUDLY
------------
This edits vendor code and is pinned to one image version. Every anchor is
asserted; if upstream changes shape the build ABORTS rather than silently
producing an unpatched image. On a Hindsight image bump, re-check this file.
"""

from __future__ import annotations

import pathlib
import sys

TARGET = pathlib.Path(
    "/app/api/hindsight_api/engine/consolidation/consolidator.py"
)

IMPORT_ANCHOR = (
    "from pydantic import AliasChoices, BaseModel, ConfigDict, Field, "
    "ValidationError, field_validator"
)
IMPORT_PATCHED = IMPORT_ANCHOR + ", model_validator"

CLASS_ANCHOR = """class _ConsolidationBatchResponse(BaseModel):
    creates: list[_CreateAction] = []
    updates: list[_UpdateAction] = []
    deletes: list[_DeleteAction] = []
"""

VALIDATOR = '''class _ConsolidationBatchResponse(BaseModel):
    creates: list[_CreateAction] = []
    updates: list[_UpdateAction] = []
    deletes: list[_DeleteAction] = []

    # --- hermes-course local patch: tolerate a bare list ---------------------
    # Some models (glm-5.2 among them) return a bare JSON array instead of the
    # required object, which fails the whole batch with a FAIL_FAST
    # ValidationError. Salvage genuine actions and drop un-actionable rows so
    # the batch degrades to a no-op instead of an error. See
    # docker/hindsight-tolerant-batch.patch.py for the full rationale.
    @model_validator(mode="before")
    @classmethod
    def _hermes_course_coerce_bare_list(cls, data):  # noqa: ANN001, ANN206
        if not isinstance(data, list):
            return data
        creates: list[dict] = []
        updates: list[dict] = []
        for item in data:
            if not isinstance(item, dict):
                continue
            text = item.get("text") or item.get("new_text") or item.get("content")
            if not isinstance(text, str) or not text.strip():
                # Parroted input row (e.g. {"id": ..., "created_at": ...}).
                # No defensible action exists; drop it.
                continue
            entry = dict(item)
            entry["text"] = text
            src = entry.get("source_fact_ids")
            if isinstance(src, str):
                src = [src]
            entry["source_fact_ids"] = src if isinstance(src, list) else []
            # Only an explicit observation_id may target an existing record.
            # A bare "id" is a FACT id in parroted output; mapping it here
            # would rewrite the wrong observation.
            if isinstance(entry.get("observation_id"), str) and entry["observation_id"].strip():
                updates.append(entry)
            else:
                entry.pop("observation_id", None)
                creates.append(entry)
        return {"creates": creates, "updates": updates, "deletes": []}
    # --- end hermes-course local patch ---------------------------------------
'''


def die(msg: str) -> None:
    sys.stderr.write(
        "\n*** hindsight-tolerant-batch patch ABORTED ***\n"
        f"{msg}\n"
        "The vendor code shape changed, so this patch was NOT applied.\n"
        "Re-derive the anchors from the new image before rebuilding:\n"
        "  docker run --rm --entrypoint sh ghcr.io/vectorize-io/hindsight:latest \\\n"
        "    -c 'grep -n \"class _ConsolidationBatchResponse\" -A6 "
        f"{TARGET}'\n\n"
    )
    raise SystemExit(1)


def main() -> None:
    if not TARGET.exists():
        die(f"{TARGET} does not exist.")

    src = TARGET.read_text(encoding="utf-8")

    if "_hermes_course_coerce_bare_list" in src:
        print("patch: already applied, nothing to do")
        return

    if src.count(IMPORT_ANCHOR) != 1:
        die(
            f"expected exactly 1 occurrence of the pydantic import anchor, "
            f"found {src.count(IMPORT_ANCHOR)}:\n  {IMPORT_ANCHOR}"
        )
    if src.count(CLASS_ANCHOR) != 1:
        die(
            "expected exactly 1 occurrence of the _ConsolidationBatchResponse "
            f"class body anchor, found {src.count(CLASS_ANCHOR)}."
        )

    src = src.replace(IMPORT_ANCHOR, IMPORT_PATCHED, 1)
    src = src.replace(CLASS_ANCHOR, VALIDATOR, 1)
    TARGET.write_text(src, encoding="utf-8")

    # Drop stale bytecode so the patched source is what actually loads.
    for pyc in TARGET.parent.glob("__pycache__/consolidator.*.pyc"):
        pyc.unlink()
        print(f"patch: removed stale bytecode {pyc.name}")

    # Prove the result imports and behaves, so a syntax slip fails the BUILD.
    import ast

    ast.parse(src)
    print("patch: applied and syntax-checked OK")


if __name__ == "__main__":
    main()
