"""Verify V13 library capabilities in the isolated preparation environment.

This is a dependency check, not the production compute protocol or an ARC agent.
All fixtures are independent finite examples; no game data or actions are used.
"""

import argparse
import hashlib
import importlib.metadata
import json
import platform
import sys
from datetime import datetime, timezone
from pathlib import Path


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def solver_checks() -> dict:
    import cvc5
    from cvc5 import Kind

    manager = cvc5.TermManager()
    solver = cvc5.Solver(manager)
    solver.setLogic("QF_LIA")
    solver.setOption("produce-models", "true")
    solver.setOption("incremental", "true")
    integer = manager.getIntegerSort()
    x = manager.mkConst(integer, "x")
    solver.assertFormula(manager.mkTerm(Kind.GT, x, manager.mkInteger(0)))
    solver.assertFormula(manager.mkTerm(Kind.LT, x, manager.mkInteger(2)))
    require(solver.checkSat().isSat(), "Expected a satisfiable finite SMT fixture")
    value = solver.getValue(x).getIntegerValue()
    require(value == 1, "SMT model does not satisfy the independent expected value")
    solver.push()
    solver.assertFormula(manager.mkTerm(Kind.LEQ, x, manager.mkInteger(0)))
    require(solver.checkSat().isUnsat(), "Expected contradictory SMT assumptions to be unsat")
    solver.pop()
    require(solver.checkSat().isSat(), "Incremental pop did not restore the original context")

    synthesis = cvc5.Solver(manager)
    synthesis.setOption("sygus", "true")
    synthesis.setLogic("LIA")
    argument = manager.mkVar(integer, "argument")
    function = synthesis.synthFun("increment", [argument], integer)
    variable = synthesis.declareSygusVar("variable", integer)
    synthesis.addSygusConstraint(
        manager.mkTerm(
            Kind.EQUAL,
            manager.mkTerm(Kind.APPLY_UF, function, variable),
            manager.mkTerm(Kind.ADD, variable, manager.mkInteger(1)),
        )
    )
    require(synthesis.checkSynth().hasSolution(), "SyGuS did not produce the specified increment function")
    solution = synthesis.getSynthSolutions([function])[0]
    checker = cvc5.Solver(manager)
    checker.setLogic("ALL")
    probe = manager.mkConst(integer, "probe")
    checker.assertFormula(
        manager.mkTerm(
            Kind.DISTINCT,
            manager.mkTerm(Kind.APPLY_UF, solution, probe),
            manager.mkTerm(Kind.ADD, probe, manager.mkInteger(1)),
        )
    )
    require(checker.checkSat().isUnsat(), "Synthesized function failed independent all-input verification")
    return {"sat_model": value, "contradiction": "unsat", "incremental_restore": "sat", "sygus_solution": str(solution), "sygus_counterexample_query": "unsat"}


def history_checks() -> dict:
    from aalpy.learning_algs import run_RPNI

    # Prefix-closed Mealy observations; labels are the final transition outputs.
    observations = [
        (("toggle",), "on"),
        (("toggle", "toggle"), "off"),
        (("toggle", "toggle", "toggle"), "on"),
        (("toggle", "toggle", "toggle", "toggle"), "off"),
    ]
    model = run_RPNI(observations, automaton_type="mealy", input_completeness=None, print_info=False)
    require(model is not None, "RPNI rejected consistent prefix-closed observations")
    for inputs, expected in observations:
        model.reset_to_initial()
        result = None
        for symbol in inputs:
            result = model.step(symbol)
        require(result == expected, "RPNI model disagrees with an observed transition")
    require(all("unobserved" not in state.transitions for state in model.states), "Unknown inputs were spuriously completed")
    return {"states": len(model.states), "observed_prefixes_checked": len(observations), "input_completeness": None, "unknown_inputs_preserved": True}


def circuit_checks() -> dict:
    import numpy as np
    import torch
    from cirkit.backend.torch.queries import IntegrateQuery
    from cirkit.pipeline import PipelineContext
    from cirkit.symbolic.circuit import Circuit
    from cirkit.symbolic.initializers import ConstantTensorInitializer
    from cirkit.symbolic.layers import CategoricalLayer, HadamardLayer, SumLayer
    from cirkit.symbolic.parameters import Parameter, SoftmaxParameter, TensorParameter
    from cirkit.utils.scope import Scope

    def normalized_parameter(probabilities: np.ndarray) -> Parameter:
        logits = TensorParameter(
            *probabilities.shape,
            initializer=ConstantTensorInitializer(np.log(probabilities)),
        )
        return Parameter.from_sequence(logits, SoftmaxParameter(probabilities.shape, axis=-1))

    px = np.array([[0.2, 0.8], [0.7, 0.3]], dtype=np.float64)
    py = np.array([[0.9, 0.1], [0.4, 0.6]], dtype=np.float64)
    weights = np.array([[0.4, 0.6]], dtype=np.float64)
    left = CategoricalLayer(Scope([0]), 2, num_categories=2, probs=normalized_parameter(px))
    right = CategoricalLayer(Scope([1]), 2, num_categories=2, probs=normalized_parameter(py))
    product = HadamardLayer(2, arity=2)
    mixture = SumLayer(2, 1, weight=normalized_parameter(weights))
    symbolic = Circuit([left, right, product, mixture], {product: [left, right], mixture: [product]}, [mixture])
    compiled = PipelineContext(backend="torch", semiring="lse-sum").compile(symbolic).to(dtype=torch.float64, device="cpu")
    compiled.reset_parameters()
    assignments = torch.tensor([[0, 0], [0, 1], [1, 0], [1, 1]], dtype=torch.long)
    expected = torch.tensor([0.24, 0.26, 0.36, 0.14], dtype=torch.float64)
    probabilities = compiled(assignments).exp()
    require(tuple(probabilities.shape) == (4, 1, 1), "Unexpected CirKit output shape; do not silently squeeze arbitrary outputs")
    require(torch.allclose(probabilities[:, 0, 0], expected, atol=2e-7, rtol=2e-7), "Circuit differs from the explicitly enumerated mixture")
    query = IntegrateQuery(compiled)
    total_mass = float(query(torch.tensor([[0, 0]], dtype=torch.long), integrate_vars=Scope([0, 1])).exp()[0, 0, 0].detach())
    require(abs(total_mass - 1.0) < 2e-7, "Normalized circuit does not have unit mass")

    # Missing Y uses a valid category placeholder and the complement of observed_mask.
    samples = torch.tensor([[1, 0], [0, 0]], dtype=torch.long)
    observed_mask = torch.tensor([[True, False], [False, True]], dtype=torch.bool)
    marginals = query(samples, integrate_vars=~observed_mask).exp()[:, 0, 0]
    require(torch.allclose(marginals, torch.tensor([0.5, 0.6], dtype=torch.float64), atol=2e-7, rtol=2e-7), "Observed-mask marginalization does not match the independent finite sum")
    numerator = probabilities[2, 0, 0]
    conditional = float((numerator / marginals[0]).detach())
    require(abs(conditional - 0.72) < 2e-7, "Conditional probability does not match 0.36 / 0.5")

    training_samples = torch.tensor([[1, 1], [1, 1], [0, 0], [1, 0]], dtype=torch.long)
    optimizer = torch.optim.Adam(compiled.parameters())
    before = [parameter.detach().clone() for parameter in compiled.parameters()]
    loss_before = -compiled(training_samples).mean()
    optimizer.zero_grad()
    loss_before.backward()
    require(all(parameter.grad is None or bool(torch.isfinite(parameter.grad).all()) for parameter in compiled.parameters()), "Non-finite gradients")
    optimizer.step()
    changed = any(not torch.equal(previous, parameter.detach()) for previous, parameter in zip(before, compiled.parameters()))
    require(changed, "Adam did not update trainable circuit parameters")
    loss_after = -compiled(training_samples).mean()
    require(float(loss_after.detach()) < float(loss_before.detach()), "One default Adam step did not improve the fixed fixture likelihood")
    mass_after = float(query(torch.tensor([[0, 0]], dtype=torch.long), integrate_vars=Scope([0, 1])).exp()[0, 0, 0].detach())
    require(abs(mass_after - 1.0) < 2e-7, "Training broke normalization")
    return {"device": "cpu", "torch": torch.__version__, "joint_probabilities": probabilities[:, 0, 0].detach().tolist(), "mass_before": total_mass, "marginals": marginals.detach().tolist(), "conditional": conditional, "loss_before": float(loss_before.detach()), "loss_after": float(loss_after.detach()), "mass_after": mass_after, "parameters_updated": changed, "adam_learning_rate": optimizer.param_groups[0]["lr"]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", action="store_true", help="Verify explicitly installed AALpy history capability")
    parser.add_argument("--output", type=Path, help="Write the same JSON evidence to this path")
    args = parser.parse_args()
    expected = {"cvc5": "1.4.2", "libcirkit": "0.3.1", "torch": "2.15.0+cpu"}
    if args.history:
        expected["aalpy"] = "2.0.0"
    versions = {name: importlib.metadata.version(name) for name in expected}
    require(versions == expected, f"Installed preparation versions differ: {versions!r}")
    require(sys.version_info[:2] == (3, 12), "This preparation profile requires Python 3.12")
    script = Path(__file__).resolve()
    lock = script.parents[1] / "uv.lock"
    script_command = ["python", "python/compute/tests/dependency_smoke.py"]
    if args.history:
        script_command.append("--history")
    # The report omits host interpreter paths. --output is an artifact destination,
    # not a capability parameter, and is therefore recorded only by its filename.
    if args.output is not None:
        script_command.extend(["--output", args.output.name])
    report = {
        "status": "passed",
        "scope": "isolated_library_capabilities_only",
        "checked_at_utc": datetime.now(timezone.utc).isoformat(),
        "python": platform.python_version(),
        "project_python_pin": "3.12.9",
        "project_python_matched": platform.python_version() == "3.12.9",
        "project_toolchain_status": "not_validated",
        "unvalidated_toolchains": ["julia", "rust"],
        "platform": platform.platform(),
        "execution": {
            "script_command": script_command,
            "script_path": "python/compute/tests/dependency_smoke.py",
            "script_sha256": hashlib.sha256(script.read_bytes()).hexdigest(),
            "lock_path": "python/compute/uv.lock",
            "lock_sha256": hashlib.sha256(lock.read_bytes()).hexdigest(),
        },
        "versions": versions,
        "solver": solver_checks(),
        "circuit": circuit_checks(),
    }
    if args.history:
        report["history"] = history_checks()
    encoded = json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    print(encoded, end="")


if __name__ == "__main__":
    main()
