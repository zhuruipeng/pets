# Expense compatibility implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Preserve expense amounts across schema 7/8 synchronization and schema 7 ZIP restoration.

**Architecture:** Keep SQLite amounts as integer cents. Convert expense snapshots at synchronization boundaries to the legacy `amount` wire field, which schema 7 clients can read, and normalize either field when receiving. Keep the original LWW timestamp; migration is a representation change, so equal/older writes should converge through the authorized canonical snapshot rather than receive an artificial newer timestamp. Restore only known schema 7/8 backup shapes, converting schema 7 expenses before checking current columns.

**Tech Stack:** Dart, Flutter, SQLite, Python, SQLAlchemy, disposable local PostgreSQL.

## Global constraints

- Change expense synchronization, backup compatibility, tests, build validation, and verification documentation only; no other business modules.
- Do not modify an already shipped migration or bump the app version.
- Do not deploy or publish until the release gate passes; never use production data for testing.
- Keep malformed monetary input explicit: errors must roll back queue/cursor and restore changes.
- Finish and verify synchronization before starting the backup task.

### Task 1: Expense synchronization

**Files:** `app/lib/data/expense_payload.dart`, `app/lib/data/sync/sync_engine.dart`, `app/test/expense_sync_test.dart`, `server/app/expense_payload.py`, `server/app/sync.py`, `server/tests/test_review_regressions.py`.

**Interfaces:** `expensePayloadForLocal(Map<String,dynamic>)` produces the cents-only local shape; `expensePayloadForSync(Map<String,dynamic>)` produces the legacy-only wire shape. Server equivalents `expense_payload_for_storage(dict)` and `expense_payload_for_wire(dict)` normalize without changing timestamps or unrelated fields.

- [x] Add engine regressions using actual SQLite, actual v8 migration statements, a controllable SyncApi, and canonical stale responses. Assert amounts 12.35 -> 1235, 0.07 -> 7, refunds, zero, deletion, no unknown local columns, original timestamps, and preservation of edits made during upload.
- [x] Add server Session regressions that push both money shapes through `sync_push`, pull into schema 7-compatible dictionaries, receive canonical stale winners, reject malformed amounts, and never mutate historical snapshots while rendering.
- [x] Run `flutter test test/expense_sync_test.dart` and `uv run --python 3.12 --with-requirements requirements.txt pytest tests/test_review_regressions.py -q`; record the expected monetary compatibility failures before implementing.
- [x] Implement the two narrowly scoped adapters. Apply client adapters in `_snapshot` and `_applyOne`, server adapters only to expenses during push validation and pull/canonical response rendering. Leave LWW unchanged.
- [x] Rerun both suites, inspect the diff, then commit and push the synchronization fix; verify `git ls-remote origin refs/heads/main`.

### Task 2: Schema 7 backup restore

**Files:** `app/lib/services/backup_service.dart`, `app/test/backup_test.dart`.

**Interfaces:** Reuse the local expense adapter from Task 1 after verifying the manifest's known schema. Keep file verification, UUID remapping, related rows, and transaction rollback in their existing paths.

- [x] Correct the current-schema fixture to `amount_cents: 1000` and add schema 7 ZIP fixtures with old `amount`, linked expenses, avatar/document contents, refunds, zero, invalid amounts, and future/unknown schema rejection.
- [x] Run `flutter test test/backup_test.dart`; record schema 7 rejection before changing restore.
- [x] Accept only integer schema values 7 and 8; convert schema 7 expense rows to cents before checking destination columns, validating the legacy field rather than guessing a schema from it. Keep malformed/current-schema rows rejected.
- [x] Rerun backup tests, inspect the diff, then commit and push the backup fix; verify the remote SHA.

### Task 3: Release gate

- [x] Run full Flutter tests and static analysis on this Mac; the documented administrator-terminal constraint applies to Windows.
- [x] Initialize a fresh local PostgreSQL cluster bound to loopback on a dedicated port, create a disposable database, set only `PET_TEST_POSTGRES_URL`, run `pytest tests/test_sync_concurrency.py -q`, and shut down the cluster. Three regressions must pass without skips.
- [x] Use the user-selected connected test phone to check upgrade, manual sync, account switching, and ZIP restoration if device access/signing/test accounts allow. Record exact unavailable dependencies and any unverified steps; do not claim a release gate passed from simulator-only evidence.
- [x] Record fresh results and pending physical-device checks in the repository, commit/push, verify remote SHA and working tree. Publish no new package.

**2026-10-12 evidence:** See `docs/2026-10-12-费用兼容性验收.md`. Flutter 403, server 340, standalone PostgreSQL concurrency 3 passed; analysis clean. Version 0.1.9+19 installed over the same Sideloadly identity; schema 7 -> 8 preserved money/rows/files. Physical schema 7 ZIP restoration preserves four expenses, their medical record, and PNG/PDF bytes. Manual sync against the disposable local API uploaded all six queued rows; the phone queue is now empty and all four server amounts match. Actual API pull uses the legacy amount field and matches local cents. Physical account B isolation and return to A remain pending; no deployment or public package release.

**Final gate evidence:** B isolation and A return/reopen verified on the actual phone. Four business tables and two attachment byte hashes match before switching; expense pending writes are zero. One pre-existing startup placeholder user row is documented separately. Concurrent upstream e379c31 was retained; full Flutter rerun passes 404, analysis clean, and the default-API IPA was rebuilt and verified. Expense release gate passed; deployment/public package release can now follow the user's earlier authorization.
