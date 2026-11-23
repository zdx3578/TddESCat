abstract type ConceptTerm end

struct Literal <: ConceptTerm
    sort::String
    value::Union{Int,String}
    function Literal(sort, value)
        value isa String || (strict_integer(value) && typemin(Int) <= value <= typemax(Int)) ||
            throw(ArgumentError("Literal must contain an integer or string"))
        new(sort, value)
    end
end
struct Slot <: ConceptTerm
    index::Int
    function Slot(index)
        strict_integer(index) && 0 <= index <= typemax(Int) || throw(ArgumentError("Invalid free slot"))
        new(index)
    end
end
struct Parameter <: ConceptTerm
    index::Int
    function Parameter(index)
        strict_integer(index) && 0 <= index <= typemax(Int) || throw(ArgumentError("Invalid parameter"))
        new(index)
    end
end
struct Call <: ConceptTerm
    name::String
    children::Vector{ConceptTerm}
end
Call(name, children::ConceptTerm...) = Call(name, ConceptTerm[children...])

struct Primitive
    inputs::Vector{String}
    output::String
    reads::Vector{Int}
end

function primitive(inputs, output)
    return Primitive(collect(String, inputs), output, collect(1:length(inputs)))
end

function evidence_signature()
    return Dict(
        "vec" => primitive(("Integer", "Integer"), "Delta"),
        "link" => primitive(("RoleBefore", "RoleAfter", "Delta"), "Relation"),
        "marked" => primitive(("Relation",), "Relation"),
        "pair" => primitive(("Relation", "Relation"), "Relation"),
    )
end

function infer_term(term::ConceptTerm, registry; slots=String[], params=String[], mode=:program)
    if term isa Literal
        term.sort in ("Integer", "Color", "Atom") || throw(ArgumentError("Unknown literal sort"))
        valid = term.sort == "Integer" ? term.value isa Int :
            term.sort == "Color" ? term.value isa Int && 0 <= term.value <= 15 :
            term.value isa String && valid_id(term.value)
        valid || throw(ArgumentError("Literal does not have its declared sort"))
        return (sort=term.sort, reads=Tuple{Symbol,Int}[])
    elseif term isa Slot || term isa Parameter
        kind = term isa Slot ? :slot : :param
        context = term isa Slot ? slots : params
        (kind == :slot ? mode == :program : mode == :definition) &&
            0 <= term.index < length(context) || throw(ArgumentError("Undeclared term reference"))
        return (sort=context[term.index + 1], reads=[(kind, term.index)])
    end
    op = get(registry, term.name, nothing)
    isnothing(op) && throw(ArgumentError("Unknown operator"))
    args = [infer_term(child, registry; slots, params, mode) for child in term.children]
    [arg.sort for arg in args] == op.inputs || throw(ArgumentError("Operator input sort mismatch"))
    reads = Tuple{Symbol,Int}[reference for index in op.reads for reference in args[index].reads]
    return (sort=op.output, reads=unique(reads))
end

function historical_program(correspondence::SupportCorrespondence)
    dx, dy = correspondence.delta
    return Call("link", Slot(0), Slot(1), Call("vec", Literal("Integer", dx), Literal("Integer", dy)))
end

function render_term(term::ConceptTerm)
    if term isa Slot
        return "\$" * string(term.index)
    elseif term isa Parameter
        return "?#" * string(term.index)
    elseif term isa Literal
        return term.sort == "Integer" ? "i" * string(term.value) :
            term.sort == "Color" ? "color" * string(term.value) : string(term.value)
    end
    return isempty(term.children) ? term.name :
        "(" * join([term.name; render_term.(term.children)], " ") * ")"
end
