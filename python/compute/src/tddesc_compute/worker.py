"""Execute compute/v1 requests over a private line-delimited channel."""

import json
from importlib.metadata import PackageNotFoundError, version
import sys

from . import solver_adapter

PROTOCOL = "compute/v1"


def capabilities():
    supported = {
        "backend": "cvc5",
        "version": version("cvc5"),
        "algebra": "typed_scalar_ast",
        "numeric": "exact",
        "operations": ["capabilities", "solve", "synthesize_guard"],
    }
    try:
        supported["cirkit"] = {
            "version": version("libcirkit"),
            "runtime": version("torch"),
            "domain": "finite_categorical_partial_observations",
            "numeric": "normalized_float",
            "artifact": "categorical-product-mixture-v1",
        }
    except PackageNotFoundError:
        pass
    else:
        supported["operations"].extend(("train_circuit", "query_circuit"))
    try:
        supported["aalpy"] = {
            "version": version("aalpy"),
            "domain": "confirmed_mealy_prefixes",
            "unseen_edges": "unknown",
        }
    except PackageNotFoundError:
        pass
    else:
        supported["operations"].append("learn_history")
    return supported


def dispatch(operation, payload):
    if operation == "capabilities":
        return capabilities()
    if operation == "solve":
        return solver_adapter.solve(payload)
    if operation == "synthesize_guard":
        return solver_adapter.synthesize_guard(payload)
    if operation in ("train_circuit", "query_circuit"):
        from . import circuit_adapter

        return (
            circuit_adapter.train(payload)
            if operation == "train_circuit"
            else circuit_adapter.query_model(payload)
        )
    if operation == "learn_history":
        try:
            from . import history_adapter
        except ModuleNotFoundError as error:
            if error.name != "aalpy":
                raise
            raise NotImplementedError("History extra is unavailable") from error
        return history_adapter.learn_history(payload)
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
