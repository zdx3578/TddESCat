"""Small source audit; not an ARC agent or a replacement concept engine."""
from pathlib import Path
import sys
import hashlib
import itertools
import json
import platform
import time

CONFIG_PATH = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).with_name("cca-probe-config.json")).resolve()
CONFIG = json.loads(CONFIG_PATH.read_text())
def configured_path(key):
    return (CONFIG_PATH.parent / CONFIG[key]).resolve()
ROOT = configured_path("source_dir")
DEPENDENCIES = configured_path("dependency_dir")
OUTPUT = configured_path("output_file")
expected_hash = CONFIG["source_sha256"]
actual_hash = hashlib.sha256((ROOT / "cgnav.py").read_bytes()).hexdigest()
if actual_hash != expected_hash:
    raise RuntimeError("Upstream cgnav.py hash differs from the audited source")
sys.path.insert(0, str(DEPENDENCIES))
sys.path.insert(0, str(ROOT))
import cgnav
import pygraphviz
from cgnav import PCFFile, PatternStructure, IntensionGraph, node, star

def finite_hom_exists(pattern, data):
    """Exhaustive semantic oracle for the tiny finite relational test cases."""
    source_nodes, target_nodes = pattern[0], data[0]
    for values in itertools.product(target_nodes, repeat=len(source_nodes)):
        assignment = dict(zip((n.id for n in source_nodes), values))
        if any(not n.atts <= assignment[n.id].atts for n in source_nodes):
            continue
        if any(name not in data.window or assignment[n.id].id != data.window[name].id
               for name, n in pattern.window.items()):
            continue
        valid = True
        for arity in range(1, len(pattern.schema)):
            for edge in pattern[arity]:
                required_tuple = tuple(assignment[n.id].id for n in edge.nodes)
                candidates = data[arity] if arity < len(data.schema) else []
                if not any(tuple(n.id for n in actual.nodes) == required_tuple
                           and edge.atts <= actual.atts for actual in candidates):
                    valid = False
                    break
            if not valid:
                break
        if valid:
            return True
    return False

started = time.perf_counter()
pcf = PCFFile(str(ROOT / "resources" / "family_relations.pcf")).parse()
lattice = PatternStructure(IntensionGraph, pcf).build()
official = {
    "case": "official_family_relations",
    "expected_concept_count": 9,
    "observed_concept_count": len(lattice),
    "passes_count_check": len(lattice) == 9,
    "seconds": time.perf_counter() - started,
}
cases = [
    ("unary_positive",
     node({"a"}, "x").windowed(), node({"a"}, "z").windowed()),
    ("unary_negative",
     node({"b"}, "x").windowed(), node({"a"}, "z").windowed()),
    ("disconnected_second_constraint",
     (node({"a"}, "x") + node({"b"}, "y")).windowed(),
     node({"a"}, "z").windowed()),
    ("two_public_roles_same_target",
     star({"r"}, "x", "y"),
     star({"r"}, "a", "b").windowed(x="a", y="a")),
    ("different_binary_predicate",
     star({"r"}, "x", "y").windowed(x="x"),
     star({"q"}, "a", "b").windowed(x="a")),
]
results = []
for name, pattern, data in cases:
    # All cases use one common relation signature, as required by the theory.
    common_schema = pattern.schema.union(data.schema)
    pattern.schema = common_schema
    data.schema = common_schema
    expected = finite_hom_exists(pattern, data)
    observed = pattern.leq(data)
    results.append({
        "case": name,
        "finite_semantics_expected": expected,
        "cgnav_observed": observed,
        "agrees": expected == observed,
    })
result = {
    "scope": "Unmodified author source; tiny finite semantic audit, not benchmark or full proof.",
    "source_commit": "816e514d24467cfd2ec29494c44a901d885d8f75",
    "source_sha256": hashlib.sha256((ROOT / "cgnav.py").read_bytes()).hexdigest(),
    "python": platform.python_version(),
    "pygraphviz": pygraphviz.__version__,
    "official_example": official,
    "semantic_cases": results,
}
OUTPUT.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(result, ensure_ascii=False, indent=2))
