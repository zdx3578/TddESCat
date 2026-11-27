constraint_term(op,args...) = Dict("op"=>op,"args"=>collect(args))
constraint_value(value::Bool) = Dict("sort"=>"Bool","value"=>value)
constraint_value(value::Integer) = Dict("sort"=>"Int","value"=>value)
constraint_variable(name) = Dict("var"=>name)

function boolean_connective(values,decisive::Bool)
    all(value->value isa Union{Bool,Nothing},values) ||
        throw(ArgumentError("Boolean constraint needs Boolean operands"))
    any(value->value === decisive,values) && return decisive
    return any(isnothing,values) ? nothing : !decisive
end

function evaluate_constraint(expr,variables)
    haskey(expr,"var") && return variables[expr["var"]]
    if haskey(expr,"value")
        value = expr["value"]
        sort = expr["sort"]
        valid = sort == "Bool" ? value isa Bool : sort == "Int" ? strict_integer(value) : false
        valid && return value
        sort == "Real" && value isa String || throw(ArgumentError("Invalid constraint constant"))
        parts = split(value,'/';limit=2)
        return parse(BigInt,first(parts)) // (length(parts) == 1 ? 1 : parse(BigInt,last(parts)))
    end
    args = [evaluate_constraint(child,variables) for child in expr["args"]]
    op = expr["op"]
    op == "and" && return boolean_connective(args,false)
    op == "or" && return boolean_connective(args,true)
    any(isnothing,args) && return nothing
    op == "not" && return !only(args)
    op == "eq" && return allequal(args)
    op == "distinct" && return allunique(args)
    op == "ite" && return args[1] ? args[2] : args[3]
    func = get(Dict("lt"=>(<),"le"=>(<=),"gt"=>(>),"ge"=>(>=),
        "add"=>(+),"subtract"=>(-),"multiply"=>(*)),op,nothing)
    isnothing(func) && throw(ArgumentError("Unsupported typed constraint"))
    return func(args...)
end

function checked_constraint_query!(worker,snapshot,variables,assertions)
    result = compute_request!(worker,snapshot,"solve",(;variables,assertions))
    result.execution == "completed" && result.answer == "value" || return result
    status = result.value["status"]
    if status == "sat"
        model = result.value["model"]
        Set(keys(model)) == Set(keys(variables)) || error("Constraint solver omitted model variables")
        assignment = Dict(name => evaluate_constraint(Dict("sort"=>sort,
            "value"=>sort == "Int" ? parse(BigInt,model[name]) : model[name]),Dict())
            for (name,sort) in variables)
        all(evaluate_constraint(assertion,assignment) === true for assertion in assertions) ||
            error("Constraint solver supplied an invalid witness")
    elseif status != "unsat"
        error("Constraint solver supplied an invalid answer")
    end
    return result
end

function constraint_implication!(worker,snapshot,variables,domain,premise,consequence)
    assumptions = [domain,premise]
    feasible = checked_constraint_query!(worker,snapshot,variables,assumptions)
    feasible.execution == "completed" && feasible.answer == "value" ||
        return (;status=:unknown,feasible,counterexample=nothing)
    feasible.value["status"] == "unsat" && return (;status=:empty_premise,feasible,counterexample=nothing)
    checked = checked_constraint_query!(worker,snapshot,variables,[assumptions;[constraint_term("not",consequence)]])
    checked.execution == "completed" && checked.answer == "value" ||
        return (;status=:unknown,feasible,counterexample=checked)
    return (;status=checked.value["status"] == "unsat" ? :proven : :refuted,feasible,counterexample=checked)
end

function resource_constraint_proof!(worker,proposal,snapshot)
    length(proposal.tests) == 1 || return nothing
    test = only(proposal.tests)
    test.scope in (:bound,:replicated) || return nothing
    constraints = Dict{String,Any}[]
    bindings = Dict{String,Any}[]
    consequences = Dict{String,Any}[]
    variables = Dict{String,String}()
    for (index,fragment) in enumerate(test.fragments)
        fragment.family == :measurement || continue
        name = "resource_" * string(index)
        variables[name] = "Int"
        variable = constraint_variable(name)
        limit = constraint_value(meter_length(fragment.binding.face.box))
        nonnegative = constraint_value(0)
        within(value) = constraint_term("and",constraint_term("ge",value,nonnegative),
            constraint_term("le",value,limit))
        push!(constraints,within(variable))
        push!(bindings,constraint_term("eq",variable,constraint_value(fragment.value)))
        push!(consequences,within(constraint_term("add",variable,
            constraint_value(fragment.expected-fragment.value))))
    end
    isempty(variables) && return nothing
    return constraint_implication!(worker,snapshot,variables,constraint_term("and",constraints...),
        constraint_term("and",bindings...),constraint_term("and",consequences...))
end
