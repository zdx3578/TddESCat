"""Learn response states from confirmed prefixes without issuing environment actions."""

from aalpy.learning_algs import run_RPNI


def learn_history(payload):
    episodes = payload.get("episodes", [])
    examples = {}
    events = set()
    initial = {episode["origin"] for episode in episodes if episode["steps"]}
    if len(initial) != 1:
        return {"status": "unknown", "reason": "initial_bindings_not_equivalent"}
    origin = next(iter(initial))
    for episode in episodes:
        prefix = []
        for step in episode["steps"]:
            action, output, event = (step[key] for key in ("input", "output", "event"))
            if not all(
                isinstance(value, str) and value for value in (action, output, event)
            ):
                raise ValueError("History encoding requires confirmed typed symbols")
            if event in events:
                raise ValueError("Duplicate event in history task")
            events.add(event)
            prefix.append(action)
            key = tuple(prefix)
            if key in examples and examples[key][0] != output:
                return {
                    "status": "conflict",
                    "prefix": list(prefix),
                    "read_events": [examples[key][1], event],
                }
            examples[key] = (output, event)
    if len(episodes) < 2 or len({value for value, _ in examples.values()}) < 2:
        return {"status": "unknown", "reason": "insufficient_distinguishing_responses"}
    result = run_RPNI(
        [(prefix, value) for prefix, (value, _) in examples.items()],
        automaton_type="mealy",
        input_completeness=None,
        print_info=False,
    )
    if result is None:
        return {"status": "unknown", "reason": "no_consistent_automaton"}
    states = {state.state_id: index for index, state in enumerate(result.states)}
    initial = states[result.initial_state.state_id]
    edges = {}
    for state in result.states:
        index = states[state.state_id]
        edges[str(index)] = {
            action: {
                "state": states[successor.state_id],
                "output": state.output_fun[action],
            }
            for action, successor in state.transitions.items()
        }
    for prefix, (expected, _) in examples.items():
        state = initial
        for action in prefix:
            edge = edges[str(state)].get(action)
            if edge is None:
                raise ValueError("Learned automaton omitted a confirmed prefix")
            state = edge["state"]
        if edge["output"] != expected:
            raise ValueError("Learned automaton disagrees with a confirmed response")

    return {
        "status": "learned",
        "origin": origin,
        "initial": initial,
        "edges": edges,
        "alphabet": sorted({action for prefix in examples for action in prefix}),
        "read_events": sorted(events),
    }
