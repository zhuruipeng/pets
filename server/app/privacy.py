"""Remove only structured attribution, preserving shared care facts."""
import json

DELETED_ACTOR = "deleted-user"


def anonymize_attribution(payload: dict) -> dict:
    result = {**payload, "created_by": DELETED_ACTOR}
    if "actor_name" in result:
        result["actor_name"] = "Deleted account"
    details = result.get("payload")
    was_string = isinstance(details, str)
    if was_string:
        try:
            details = json.loads(details)
        except (TypeError, ValueError):
            return result
    if isinstance(details, dict) and "actor_name" in details:
        details = {**details, "actor_name": "Deleted account"}
        result["payload"] = json.dumps(details, ensure_ascii=False) if was_string else details
    return result
