source_event_id(source::AbstractString) = source
source_event_id(source) = source.event_id

function check_available(reads, sequence_by_event, decision_cutoff::Integer)
    violations = [
        source for source in reads if get(sequence_by_event, source_event_id(source), typemax(Int)) >= decision_cutoff
    ]
    return (available=isempty(violations), violations=violations)
end
