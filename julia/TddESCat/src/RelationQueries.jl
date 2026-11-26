struct RelationScope
    episode::String
    frame_ref::String
    interpretation::String
    view::String
    phase::String
end

scope_identity(scope::RelationScope) =
    [scope.episode,scope.frame_ref,scope.interpretation,scope.view,scope.phase]

struct RelationTable
    columns::Vector{Tuple{String,String}}
    scope::RelationScope
    rows::Dict{Tuple,String}
    enumerated::Bool
    domain_complete::Bool
    witnesses_complete::Bool
    completion_ref::Union{Nothing,String}
end

struct RelationRead
    name::String
    scope::RelationScope
    pattern::Tuple
    digest::String
end

struct RelationEvaluation
    scope::RelationScope
    sequence_by_event::Dict{String,Int}
    cutoff::Int
    slot::Int
    witnesses::Dict{String,Any}
    atoms::Dict{String,RelationTable}
    reads::Dict{Tuple{String,Tuple},RelationRead}
end

RelationEvaluation(scope, sequences, cutoff; slot=0) = RelationEvaluation(scope,sequences,cutoff,slot,Dict(),Dict(),Dict())

function relation_witness!(evaluation, kind, refs; detail=nothing, events=String[])
    all(haskey(evaluation.witnesses,ref) for ref in refs) || error("Unknown relation witness parent")
    all(haskey(evaluation.sequence_by_event,ref) &&
        evaluation.sequence_by_event[ref] < evaluation.cutoff for ref in events) ||
        error("Relation witness reads evidence past the declared cutoff")
    parents = sort!(unique!(collect(String,refs)))
    record = Dict("kind"=>kind,"parents"=>parents,"detail"=>detail,
        "event_reads"=>sort!(unique!(collect(String,events))),"scope"=>scope_identity(evaluation.scope))
    id = "witness-" * semantic_hash(record)
    get!(evaluation.witnesses,id,record) == record || error("Relation witness digest collision")
    return id
end

function relation_columns(values)
    columns = Tuple{String,String}[]
    for pair in values
        length(pair) == 2 && valid_id(pair[1]) && pair[2] in ("before","after","timeless") ||
            error("Invalid ordered relation column")
        push!(columns,(pair[1],pair[2]))
    end
    return columns
end

function relation_value(sort, value)
    sort == "Integer" && return strict_integer(value)
    sort == "Color" && return strict_integer(value) && 0 <= value <= 15
    sort == "Boolean" && return value isa Bool
    return valid_id(value)
end

function emit_relation_rows(evaluation, rows)
    result = Dict{Tuple,String}()
    for (tuple,refs) in rows
        unique!(refs)
        result[tuple] = length(refs) == 1 ? only(refs) : relation_witness!(evaluation,"or",refs)
    end
    return result
end

function observe_relation!(evaluation, name, columns, rows; event_reads, domain_complete, enumerated=true)
    header = relation_columns(columns)
    all(column[2] in (evaluation.scope.phase,"timeless") for column in header) ||
        error("Observed column phase differs from the relation scope")
    isempty(event_reads) && error("Observed relation requires public evidence")
    witnessed = Dict{Tuple,Vector{String}}()
    for values in rows
        tuple = Tuple(values)
        length(tuple) == length(header) &&
            all(relation_value(column[1],value) for (column,value) in zip(header,tuple)) ||
            error("Relation row violates its column contract")
        id = relation_witness!(evaluation,"atom",(); detail=[name,tuple],events=event_reads)
        push!(get!(Vector{String},witnessed,tuple),id)
    end
    complete = domain_complete && enumerated
    completion = complete ? relation_witness!(evaluation,"finite_domain",();
        detail=[name,header,sort!(collect(keys(witnessed));by=canonical_bytes)],events=event_reads) : nothing
    result = RelationTable(header,evaluation.scope,emit_relation_rows(evaluation,witnessed),
        enumerated,domain_complete,enumerated,completion)
    haskey(evaluation.atoms,name) && error("Repeated relation atom in the same evaluation")
    evaluation.atoms[name] = result
    return result
end

function query_sort!(signature, header)
    return semantic_sort!(signature,"rel",Dict("kind"=>"relation","version"=>"relation-columns-v1",
        "columns"=>relation_columns(header)))
end

function relation_operator!(signature, operation, inputs, output; layout=Dict{String,Any}())
    return semantic_operator!(signature,inputs,output,Dict("kind"=>operation,"layout"=>layout))
end

function relation_atom!(signature, name, columns; phase="before", slot=0)
    valid_id(name) || error("Invalid relation atom name")
    context = phase == "before" ? "SceneBefore" : phase == "after" ? "SceneAfter" : error("Unknown relation phase")
    any(sort->sort["id"] == context,signature["sorts"]) || push!(signature["sorts"],Dict("id"=>context))
    sort = query_sort!(signature,columns)
    head = relation_operator!(signature,"Atom",[context],sort;layout=Dict("name"=>name,"phase"=>phase))
    return (; term=Call(head,Slot(slot)), sort)
end

function joined_columns(left, right, shared, output, distinct)
    for (l,r) in shared
        checkbounds(Bool,left,l+1) && checkbounds(Bool,right,r+1) && left[l+1] == right[r+1] ||
            error("Shared relation columns differ in sort or phase")
    end
    length(shared) == length(unique(shared)) || error("Repeated join column pair")
    columns = [left;right]
    all(i->checkbounds(Bool,columns,i+1),output) && allunique(output) ||
        error("Invalid ordered join output")
    for (a,b) in distinct
        checkbounds(Bool,columns,a+1) && checkbounds(Bool,columns,b+1) && a != b &&
            columns[a+1] == columns[b+1] || error("Invalid join distinction")
    end
    return columns[output .+ 1]
end

function query_columns(signature, sort)
    header = only(s["descriptor"] for s in signature["sorts"] if s["id"] == sort)
    header["kind"] == "relation" || error("Expected an ordered relation header")
    return relation_columns(header["columns"])
end

function relation_join!(signature, left, right; shared, output, distinct=Tuple{Int,Int}[])
    columns = joined_columns(query_columns(signature,left.sort),query_columns(signature,right.sort),
        shared,output,distinct)
    sort = query_sort!(signature,columns)
    head = relation_operator!(signature,"Join",[left.sort,right.sort],sort;
        layout=Dict("shared"=>shared,"output"=>output,"distinct"=>distinct))
    return (; term=Call(head,left.term,right.term),sort)
end

function relation_project!(signature, operand, columns)
    header = query_columns(signature,operand.sort)
    allunique(columns) && all(i->checkbounds(Bool,header,i+1),columns) || error("Invalid ordered projection")
    sort = query_sort!(signature,header[columns .+ 1])
    head = relation_operator!(signature,"Project",[operand.sort],sort;layout=Dict("columns"=>columns))
    return (; term=Call(head,operand.term),sort)
end

function finite_relation_result(evaluation, kind, header, rows, tables; detail=nothing)
    all(table->scope_identity(table.scope) == scope_identity(evaluation.scope),tables) ||
        error("Cannot mix relation evaluation scopes")
    enumerated = all(table->table.enumerated,tables)
    domain_complete = all(table->table.domain_complete,tables)
    complete = enumerated && domain_complete
    completion = complete ? relation_witness!(evaluation,kind * "_complete",
        [table.completion_ref for table in tables];detail) : nothing
    return RelationTable(header,evaluation.scope,emit_relation_rows(evaluation,rows),enumerated,
        domain_complete,all(table->table.witnesses_complete,tables),completion)
end

function exact_relation_join(evaluation, left, right, layout)
    scope_identity(left.scope) == scope_identity(right.scope) || error("Cannot join different relation scopes")
    shared, output, distinct = (layout[key] for key in ("shared","output","distinct"))
    header = joined_columns(left.columns,right.columns,shared,output,distinct)
    key(row,side) = Tuple(row[pair[side]+1] for pair in shared)
    left_rows, right_rows = collect(left.rows), collect(right.rows)
    row_pairs = galley_join_pairs([key(row,1) for (row,_) in left_rows],
        [key(row,2) for (row,_) in right_rows])
    result = Dict{Tuple,Vector{String}}()
    for (l,r) in row_pairs
        lrow,lref = left_rows[l]
        rrow,rref = right_rows[r]
        row = (lrow...,rrow...)
        all(row[a+1] != row[b+1] for (a,b) in distinct) || continue
        values = Tuple(row[i+1] for i in output)
        witness = relation_witness!(evaluation,"and",[lref,rref];detail=[shared,output,distinct,row])
        push!(get!(Vector{String},result,values),witness)
    end
    return finite_relation_result(evaluation,"join",header,result,[left,right];detail=layout)
end

function apply_relation_operator(evaluation, operation, args, layout)
    operation == "Join" && return exact_relation_join(evaluation,args...,layout)
    input = first(args)
    header = input.columns
    rows = Dict{Tuple,Vector{String}}()
    if operation in ("Project","Rename")
        order = layout["columns"] .+ 1
        allunique(order) && all(i->checkbounds(Bool,header,i),order) || error("Invalid column projection")
        operation == "Rename" && length(order) != length(header) && error("Rename must be bijective")
        header = header[order]
        for (row,ref) in input.rows
            values = Tuple(row[index] for index in order)
            push!(get!(Vector{String},rows,values),ref)
        end
    elseif operation == "SelectEqual"
        column = layout["left"] + 1
        other = get(layout,"right",nothing)
        checkbounds(Bool,header,column) || error("Unknown comparison column")
        if isnothing(other)
            relation_value(header[column][1],layout["value"]) || error("Comparison constant sort mismatch")
        else
            other += 1
            checkbounds(Bool,header,other) && header[other] == header[column] || error("Comparison column sort mismatch")
        end
        for (row,ref) in input.rows
            row[column] == (isnothing(other) ? layout["value"] : row[other]) && (rows[row] = [ref])
        end
    elseif operation == "Union"
        for table in args
            table.columns == header || error("Union columns differ")
            for (row,ref) in table.rows
                push!(get!(Vector{String},rows,row),ref)
            end
        end
    elseif operation == "SafeNegate"
        domain = last(args)
        domain.columns == header || error("Negation domain columns differ")
        all(table->!isnothing(table.completion_ref),args) ||
            return RelationTable(header,evaluation.scope,Dict(),false,false,false,nothing)
        issubset(keys(input.rows),keys(domain.rows)) || error("Negation input escaped the declared domain")
        for (row,ref) in domain.rows
            haskey(input.rows,row) && continue
            rows[row] = [relation_witness!(evaluation,"finite_negation",
                [ref,input.completion_ref,domain.completion_ref];detail=row)]
        end
    else
        error("Unsupported relation operation " * operation)
    end
    return finite_relation_result(evaluation,operation,header,rows,args;detail=layout)
end

function relation_range_digest(table::RelationTable, pattern::Tuple)
    length(pattern) == length(table.columns) || throw(ArgumentError("Relation read range arity mismatch"))
    matching = [(row,witness) for (row,witness) in table.rows if
        all(isnothing(value) || value == row[position] for (position,value) in enumerate(pattern))]
    sort!(matching;by=canonical_bytes)
    return semantic_hash([table.columns,table.enumerated,table.domain_complete,
        table.witnesses_complete,matching])
end

function read_relation_range!(evaluation::RelationEvaluation,name,pattern::Tuple)
    table = evaluation.atoms[name]
    read = RelationRead(name,table.scope,pattern,relation_range_digest(table,pattern))
    evaluation.reads[(name,pattern)] = read
    return table
end

function relation_read_current(read::RelationRead,evaluation::RelationEvaluation)
    table = get(evaluation.atoms,read.name,nothing)
    return !isnothing(table) && scope_identity(read.scope) == scope_identity(table.scope) &&
        read.digest == relation_range_digest(table,read.pattern)
end

function evaluate_relation(term, evaluation, signature; slots, library=[])
    registry, definitions = registry_from(signature,library)
    wire = decode_program(term isa AbstractString ? term : render_term(term),registry)
    wire_sort(wire,registry;slots)
    function evaluate(node)
        node["kind"] == "Call" || error("Expected relation operator")
        name = node["operator"]
        if haskey(definitions,name)
            return evaluate(instantiate_wire(definitions[name]["body"],node["args"]))
        end
        op = registry[name]
        operation = op["descriptor"]["kind"]
        layout = op["descriptor"]["layout"]
        header = query_columns(signature,op["output"])
        result = if operation == "Atom"
            slot = only(node["args"])
            slot["kind"] == "Slot" && slot["index"] == evaluation.slot ||
                error("Atom context must read from the declared scene binding")
            layout["phase"] == evaluation.scope.phase || error("Atom would read from another phase")
            name = layout["name"]
            haskey(evaluation.atoms,name) ?
                read_relation_range!(evaluation,name,ntuple(_ -> nothing,length(header))) :
                RelationTable(header,evaluation.scope,Dict(),false,false,false,nothing)
        else
            apply_relation_operator(evaluation,operation,evaluate.(node["args"]),layout)
        end
        result.columns == header || error("Relation evaluator returned a different header")
        return result
    end
    return evaluate(wire)
end

function relation_member(table, values)
    haskey(table.rows,Tuple(values)) && return proven
    return table.enumerated && table.domain_complete ? disproven : unknown_truth
end

function relation_member(tables::AbstractVector, values; interpretation_complete)
    isempty(tables) && return unknown_truth
    interpretation_complete || return unknown_truth
    results = [relation_member(table,values) for table in tables]
    return all(==(first(results)),results) ? first(results) : unknown_truth
end
