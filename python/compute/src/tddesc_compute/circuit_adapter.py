"""Train and query an explicitly normalized CirKit mixture of categorical products."""

from collections import defaultdict
import hashlib
import json
import math

import torch
from cirkit.pipeline import PipelineContext
from cirkit.symbolic.circuit import Circuit
from cirkit.symbolic.initializers import NormalInitializer
from cirkit.symbolic.layers import CategoricalLayer, HadamardLayer, SumLayer
from cirkit.symbolic.parameters import Parameter, SoftmaxParameter, TensorParameter
from cirkit.utils.scope import Scope

STRUCTURE = "categorical-product-mixture-v1"


def normalized(shape):
    return Parameter.from_unary(
        SoftmaxParameter(shape),
        TensorParameter(*shape, initializer=NormalInitializer()),
    )


class Mixture:
    def __init__(self, dimensions, units):
        self.dimensions = tuple(dimensions)
        self.units = units
        self.context = PipelineContext(backend="torch")
        inputs = [
            CategoricalLayer(Scope([index]), units, num_categories=size)
            for index, size in enumerate(dimensions)
        ]
        layers = list(inputs)
        edges = {}
        predecessor = inputs[0]
        if len(inputs) > 1:
            predecessor = HadamardLayer(units, arity=len(inputs))
            edges[predecessor] = inputs
            layers.append(predecessor)
        output = SumLayer(units, 1, weight=normalized((1, units)))
        layers.append(output)
        edges[output] = [predecessor]
        self.compiled = self.context.compile(Circuit(layers, edges, [output]))
        self.views = {(): self.compiled}

    def mass(self, rows):
        if not rows:
            return torch.empty(0, dtype=torch.float64)
        groups = defaultdict(list)
        for index, row in enumerate(rows):
            groups[tuple(col for col, value in enumerate(row) if value is None)].append(
                index
            )
        result = [None] * len(rows)
        for missing, indexes in groups.items():
            circuit = self.views.get(missing)
            if circuit is None:
                circuit = self.context.integrate(self.compiled, scope=Scope(missing))
                self.views[missing] = circuit
            if len(missing) == len(self.dimensions):
                values = circuit().reshape(1).expand(len(indexes))
            else:
                inputs = torch.tensor(
                    [
                        [0 if value is None else value for value in rows[index]]
                        for index in indexes
                    ],
                    dtype=torch.long,
                )
                values = circuit(inputs).reshape(-1)
            for index, value in zip(indexes, values, strict=True):
                result[index] = value
        return torch.stack(result)

    def artifact(self):
        parameters = {
            name: value.detach().tolist()
            for name, value in self.compiled.state_dict().items()
        }
        return {
            "structure": STRUCTURE,
            "dimensions": list(self.dimensions),
            "units": self.units,
            "parameters": parameters,
        }

    @classmethod
    def restore(cls, artifact):
        validate_shape(artifact["dimensions"], artifact["units"])
        if artifact["structure"] != STRUCTURE:
            raise ValueError("Unknown circuit structure")
        model = cls(artifact["dimensions"], artifact["units"])
        expected = model.compiled.state_dict()
        data = artifact["parameters"]
        if set(data) != set(expected):
            raise ValueError("Circuit parameter layout mismatch")
        state = {
            name: torch.as_tensor(data[name], dtype=tensor.dtype)
            for name, tensor in expected.items()
        }
        if not all(
            torch.all(torch.isfinite(tensor)).item() for tensor in state.values()
        ):
            raise ValueError("Non-finite circuit parameter")
        model.compiled.load_state_dict(state, strict=True)
        return model


def validate_shape(dimensions, units):
    if not dimensions or not all(
        type(size) is int and size >= 2 for size in dimensions
    ):
        raise ValueError("Categorical dimensions must have at least two values")
    if type(units) is not int or units <= 0:
        raise ValueError("Invalid mixture width")


def checked_row(row, dimensions):
    if len(row) != len(dimensions):
        raise ValueError("Wrong categorical feature width")
    for value, size in zip(row, dimensions, strict=True):
        if value is not None and (type(value) is not int or not 0 <= value < size):
            raise ValueError("Illegal observed category")
    return tuple(row)


def encode_training(samples, dimensions):
    seen = {}
    for sample in samples:
        ref = sample["event"]
        row = checked_row(sample["values"], dimensions)
        if not isinstance(ref, str) or not ref:
            raise ValueError("Circuit sample lacks a confirmed event identity")
        if ref in seen and seen[ref] != row:
            raise ValueError("Conflicting sample encodings for one event")
        seen[ref] = row
    return seen


def numeric_state(value):
    if isinstance(value, torch.Tensor):
        return {"tensor": value.detach().tolist(), "dtype": str(value.dtype)}
    if isinstance(value, dict):
        return {str(key): numeric_state(val) for key, val in value.items()}
    if isinstance(value, (tuple, list)):
        return [numeric_state(item) for item in value]
    return value


def restore_optimizer(optimizer, snapshot):
    def unpack(value):
        if isinstance(value, dict) and set(value) == {"tensor", "dtype"}:
            dtypes = {
                "torch.float32": torch.float32,
                "torch.float64": torch.float64,
                "torch.int64": torch.int64,
                "torch.int32": torch.int32,
            }
            return torch.tensor(value["tensor"], dtype=dtypes[value["dtype"]])
        if isinstance(value, dict):
            return {key: unpack(item) for key, item in value.items()}
        if isinstance(value, list):
            return [unpack(item) for item in value]
        return value

    state = unpack(snapshot)
    state["state"] = {int(key): value for key, value in state["state"].items()}
    optimizer.load_state_dict(state)


def stable_bytes(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), allow_nan=False
    ).encode()


def train(payload):
    dimensions, units = payload["dimensions"], payload["units"]
    validate_shape(dimensions, units)
    seen = encode_training(payload["samples"], dimensions)
    rows = [row for row in seen.values() if any(value is not None for value in row)]
    if not rows:
        return {"status": "unknown", "reason": "no_observed_samples"}
    steps = payload["steps"]
    if type(steps) is not int or steps <= 0:
        raise ValueError("Training requires a positive number of Adam steps")
    torch.manual_seed(payload.get("seed", 0))
    torch.set_num_threads(1)
    prior = payload.get("resume")
    training = hashlib.sha256(stable_bytes(list(seen.items()))).hexdigest()
    if prior is None:
        model = Mixture(dimensions, units)
    else:
        if prior["training_sha256"] != training:
            raise ValueError("A changed encoding requires a complete new fit")
        model = Mixture.restore(prior["artifact"])
        if model.dimensions != tuple(dimensions) or model.units != units:
            raise ValueError("Training resume geometry changed")
    optimizer = torch.optim.Adam(model.compiled.parameters(), lr=0.05)
    if prior is not None:
        restore_optimizer(optimizer, prior["optimizer"])
    for _ in range(steps):
        optimizer.zero_grad(set_to_none=True)
        likelihood = model.mass(rows)
        if not torch.all(torch.isfinite(likelihood)).item():
            return {"status": "unknown", "reason": "nonfinite_likelihood"}
        loss = -likelihood.clamp_min(torch.finfo(likelihood.dtype).tiny).log().mean()
        loss.backward()
        optimizer.step()
    restored_artifact = model.artifact()
    normalization = float(model.mass([[None] * len(dimensions)])[0].detach())
    if not math.isclose(normalization, 1.0, rel_tol=1e-6):
        return {"status": "unknown", "reason": "normalization_failed"}
    return {
        "status": "fitted",
        "sample_count": len(seen),
        "events": list(seen),
        "training_sha256": training,
        "negative_log_likelihood": float(loss.detach()),
        "artifact": restored_artifact,
        "optimizer": numeric_state(optimizer.state_dict()),
        "parameter_sha256": hashlib.sha256(stable_bytes(restored_artifact)).hexdigest(),
    }


def conditional(model, evidence, target):
    row = list(checked_row(evidence, model.dimensions))
    if type(target) is not int or not 0 <= target < len(row) or row[target] is not None:
        raise ValueError("Conditional query target must be an unbound column")
    with torch.no_grad():
        denominator = float(model.mass([row])[0])
        if not math.isfinite(denominator):
            return {"status": "unknown", "reason": "numeric_failure"}
        if denominator <= 0:
            return {"status": "unknown", "reason": "zero_denominator"}
        assignments = [
            [
                value if index == target else existing
                for index, existing in enumerate(row)
            ]
            for value in range(model.dimensions[target])
        ]
        numerator = model.mass(assignments)
        result = [float(value) / denominator for value in numerator]
        if not all(math.isfinite(value) and value >= 0 for value in result):
            return {"status": "unknown", "reason": "numeric_failure"}
        if not math.isclose(sum(result), 1.0, rel_tol=1e-6):
            return {"status": "unknown", "reason": "inconsistent_marginal"}
        return {
            "status": "supported",
            "probabilities": result,
            "denominator": denominator,
        }


def query_model(payload):
    model = Mixture.restore(payload["artifact"])
    target = payload["target"]
    return {
        "status": "supported",
        "rows": [conditional(model, row, target) for row in payload["evidence"]],
    }
