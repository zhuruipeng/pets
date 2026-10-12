"""Expense-only compatibility between integer-cent storage and schema 7 wire."""

from decimal import Decimal, ROUND_HALF_UP
import math

_MAX_SAFE_CENTS = 9007199254740991


def _legacy_cents(value):
    if type(value) not in (int, float):
        raise ValueError("Invalid expense amount")
    try:
        scaled = float(value) * 100
    except OverflowError as exc:
        raise ValueError("Expense amount exceeds numeric range") from exc
    if not math.isfinite(scaled) or abs(scaled) > _MAX_SAFE_CENTS:
        raise ValueError("Invalid expense amount")
    # Match SQLite ROUND and Dart round: half cents round away from zero.
    return int(Decimal.from_float(scaled).to_integral_value(rounding=ROUND_HALF_UP))


def expense_payload_for_storage(source: dict) -> dict:
    result = dict(source)
    if "amount" not in result and "amount_cents" not in result:
        return result  # Thin tombstones do not invent a monetary value.
    if "amount_cents" in result:
        cents = result["amount_cents"]
        if type(cents) is not int or abs(cents) > _MAX_SAFE_CENTS:
            raise ValueError("Invalid expense cents")
        if "amount" in result and _legacy_cents(result["amount"]) != cents:
            raise ValueError("Conflicting expense amounts")
    else:
        cents = _legacy_cents(result["amount"])
    if _legacy_cents(cents / 100) != cents:
        raise ValueError("Expense amount cannot round-trip exactly")
    result.pop("amount", None)
    result["amount_cents"] = cents
    return result


def expense_payload_for_wire(source: dict) -> dict:
    result = expense_payload_for_storage(source)
    if "amount_cents" in result:
        result["amount"] = result.pop("amount_cents") / 100
    return result
