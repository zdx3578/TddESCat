"""Execute compute/v1 requests over a private line-delimited channel."""

import json
import sys

from . import solver_adapter

PROTOCOL = "compute/v1"


def dispatch(operation, payload):
    if operation == "capabilities":
        return {"backend": "cvc5", "algebra": "typed_scalar_ast", "numeric": "exact"}
    if operation == "solve":
        return solver_adapter.solve(payload)
    if operation == "synthesize_guard":
        return solver_adapter.synthesize_guard(payload)
    raise NotImplementedError(f"Unsupported operation {operation}")


def handle(request):
    identity = {
        "protocol": PROTOCOL,
        "request_id": request.get("request_id"),
        "snapshot": request.get("snapshot"),
    }
    try:
        if (
            set(request)
            - {"protocol", "request_id", "snapshot", "operation", "payload"}
            or request.get("protocol") != PROTOCOL
            or type(request.get("request_id")) is not int
            or request["request_id"] < 0
            or not isinstance(request.get("snapshot"), str)
            or not request["snapshot"]
        ):
            raise ValueError("Invalid request envelope")
        value = dispatch(request["operation"], request.get("payload", {}))
        return {
            **identity,
            "execution": "completed",
            "answer": "unknown" if value.get("status") == "unknown" else "value",
            "coverage": "complete",
            "value": value,
            "detail": None,
        }
    except (
        ValueError,
        KeyError,
        TypeError,
        RuntimeError,
        NotImplementedError,
    ) as error:
        status = (
            "unsupported" if isinstance(error, NotImplementedError) else "invalid_input"
        )
        return {
            **identity,
            "execution": status,
            "answer": "unknown",
            "coverage": "unavailable",
            "value": None,
            "detail": str(error),
        }


def main():
    for line in sys.stdin:
        try:
            request = json.loads(line)
            if type(request) is not dict:
                raise ValueError("Expected a JSON object")
        except ValueError:
            request = {}
        print(
            json.dumps(handle(request), ensure_ascii=False, allow_nan=False), flush=True
        )


if __name__ == "__main__":
    main()
