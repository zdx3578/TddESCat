function check_available(reads, sequence_by_event, decision_cutoff::Integer)
    violations = [
        source for source in reads if get(sequence_by_event, source.event_id, typemax(Int)) >= decision_cutoff
    ]
    return (available=isempty(violations), violations=violations)
end
