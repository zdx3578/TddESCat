"""Lower the project's Boolean and arithmetic terms to the pinned cvc5 API."""

from fractions import Fraction
import re

import cvc5
from cvc5 import Kind

KINDS = {
    "and": Kind.AND,
    "or": Kind.OR,
    "not": Kind.NOT,
    "eq": Kind.EQUAL,
    "distinct": Kind.DISTINCT,
    "lt": Kind.LT,
    "le": Kind.LEQ,
    "gt": Kind.GT,
    "ge": Kind.GEQ,
    "add": Kind.ADD,
    "subtract": Kind.SUB,
    "multiply": Kind.MULT,
    "ite": Kind.ITE,
}
SYMBOL = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
SORTS = {
    "Bool": cvc5.TermManager.getBooleanSort,
    "Int": cvc5.TermManager.getIntegerSort,
    "Real": cvc5.TermManager.getRealSort,
}


def typed_value(manager, sort, value):
    if sort == "Bool" and isinstance(value, bool):
        return manager.mkBoolean(value)
    if sort == "Int" and type(value) is int:
        return manager.mkInteger(str(value))
    if sort == "Real" and isinstance(value, str):
        ratio = Fraction(value)
        return manager.mkReal(str(ratio))
    raise ValueError(f"Invalid {sort} constant")


def lower(manager, node, variables):
    match node:
        case {"var": name} if set(node) == {"var"}:
            if name not in variables:
                raise ValueError(f"Unbound variable {name}")
            return variables[name]
        case {"sort": sort, "value": value} if set(node) == {"sort", "value"}:
            return typed_value(manager, sort, value)
        case {"op": op, "args": args} if set(node) == {"op", "args"}:
            if op not in KINDS or type(args) is not list:
                raise ValueError("Unsupported typed operation")
            children = [lower(manager, child, variables) for child in args]
            if op in ("and", "or"):
                if not children:
                    return manager.mkBoolean(op == "and")
                if len(children) == 1 and children[0].getSort().isBoolean():
                    return children[0]
            return manager.mkTerm(KINDS[op], *children)
        case _:
            raise ValueError("Malformed typed expression")


def encode_value(term):
    if term.isBooleanValue():
        return term.getBooleanValue()
    if term.isIntegerValue():
        return str(term.getIntegerValue())
    if term.isRealValue():
        return str(term.getRealValue())
    raise ValueError("Model value is outside the declared scalar language")


def solve(payload):
    if set(payload) != {"variables", "assertions"}:
        raise ValueError("Unexpected solve fields")
    manager = cvc5.TermManager()
    solver = cvc5.Solver(manager)
    solver.setOption("produce-models", "true")
    solver.setLogic("ALL")
    variables = {}
    for name, sort in payload["variables"].items():
        if not SYMBOL.fullmatch(name) or sort not in SORTS:
            raise ValueError("Invalid SMT variable name or sort")
        variables[name] = manager.mkConst(SORTS[sort](manager), name)
    for expression in payload["assertions"]:
        assertion = lower(manager, expression, variables)
        if not assertion.getSort().isBoolean():
            raise ValueError("SMT assertions must be Boolean")
        solver.assertFormula(assertion)
    result = solver.checkSat()
    if result.isSat():
        return {
            "status": "sat",
            "model": {
                name: encode_value(solver.getValue(term))
                for name, term in variables.items()
            },
        }
    if result.isUnsat():
        return {"status": "unsat"}
    return {"status": "unknown", "reason": str(result.getUnknownExplanation())}


def export_boolean(term, variables):
    for name, variable in variables.items():
        if term == variable:
            return {"var": name}
    if term.isBooleanValue():
        return {"sort": "Bool", "value": term.getBooleanValue()}
    names = {Kind.AND: "and", Kind.OR: "or", Kind.NOT: "not"}
    if term.getKind() not in names:
        raise ValueError("Synthesized term escaped the guard grammar")
    return {
        "op": names[term.getKind()],
        "args": [export_boolean(child, variables) for child in term],
    }


def synthesize_guard(payload):
    if set(payload) != {"features", "samples"}:
        raise ValueError("Unexpected synthesis fields")
    names = payload["features"]
    if (
        not names
        or len(set(names)) != len(names)
        or not all(SYMBOL.fullmatch(name) for name in names)
    ):
        raise ValueError("Invalid Boolean feature names")
    manager = cvc5.TermManager()
    solver = cvc5.Solver(manager)
    solver.setOption("sygus", "true")
    solver.setOption("tlimit-per", "1000")
    solver.setLogic("ALL")
    boolean = manager.getBooleanSort()
    variables = [manager.mkVar(boolean, name) for name in names]
    start = manager.mkVar(boolean, "Start")
    grammar = solver.mkGrammar(variables, [start])
    grammar.addRules(
        start,
        [
            *variables,
            manager.mkTerm(Kind.NOT, start),
            manager.mkTerm(Kind.AND, start, start),
            manager.mkTerm(Kind.OR, start, start),
        ],
    )
    guard = solver.synthFun("guard", variables, boolean, grammar)
    assertions = {}
    for sample in payload["samples"]:
        if set(sample) != {"features", "expected"} or len(sample["features"]) != len(
            names
        ):
            raise ValueError("Wrong feature row shape")
        values = tuple(sample["features"])
        expected = sample["expected"]
        if not all(isinstance(value, bool) for value in values) or not isinstance(
            expected, bool
        ):
            raise ValueError(
                "Synthesis requires decided feature and outcome Boolean values"
            )
        if values in assertions and assertions[values] != expected:
            return {"status": "no_solution", "reason": "ambiguous_observed_features"}
        assertions[values] = expected
    if set(assertions.values()) != {True, False}:
        raise ValueError("A guard needs both distinguishable outcomes")
    for values, expected in assertions.items():
        call = manager.mkTerm(
            Kind.APPLY_UF, guard, *(manager.mkBoolean(v) for v in values)
        )
        solver.addSygusConstraint(
            manager.mkTerm(Kind.EQUAL, call, manager.mkBoolean(expected))
        )
    result = solver.checkSynth()
    if result.hasSolution():
        solution = solver.getSynthSolution(guard)
        if solution.getKind() == Kind.LAMBDA:
            solution = solution[1]
        return {
            "status": "solution",
            "guard": export_boolean(solution, dict(zip(names, variables, strict=True))),
        }
    if result.hasNoSolution():
        return {"status": "no_solution"}
    return {"status": "unknown"}
