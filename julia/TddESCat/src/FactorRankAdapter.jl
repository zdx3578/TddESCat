struct FiniteEncoding
    columns::Vector{Dict{Any,Int}}
    bits::Vector{UnitRange{Int}}
    layout::NamedTuple
end

function finite_encoding(domains; style="balanced")
    any(isempty,domains) && throw(ArgumentError("Empty legal domain requires an explicit empty relation"))
    values = Dict{Any,Int}[]
    blocks = UnitRange{Int}[]
    offset = 0
    for domain in domains
        unique_values = Dict{Any,Int}(value=>index-1 for (index,value) in enumerate(domain))
        length(unique_values) == length(domain) || throw(ArgumentError("Repeated finite domain value"))
        width = length(domain) <= 1 ? 0 : ndigits(length(domain)-1;base=2)
        push!(values,unique_values)
        push!(blocks,offset:(offset+width-1))
        offset += width
    end
    return FiniteEncoding(values,blocks,(;order=collect(0:offset-1),style))
end

factor_constant(value) = (;op="constant",value)
factor_or(args) = isempty(args) ? factor_constant(false) : length(args) == 1 ? only(args) : (;op="or",args)
factor_and(args) = isempty(args) ? factor_constant(true) : length(args) == 1 ? only(args) : (;op="and",args)

function bit_literals(block, index)
    return [(bit,isodd(index >> (length(block)-position))) for (position,bit) in enumerate(block)]
end

function encode_factor_row(encoding::FiniteEncoding, row)
    length(row) == length(encoding.columns) || throw(ArgumentError("Invalid finite row length"))
    literals = Tuple{Int,Bool}[]
    for (value,domain,block) in zip(row,encoding.columns,encoding.bits)
        haskey(domain,value) || throw(ArgumentError("Row outside finite domain"))
        append!(literals,bit_literals(block,domain[value]))
    end
    return literals
end

function legal_factor_domain(encoding::FiniteEncoding)
    tests = map(encoding.columns,encoding.bits) do domain, block
        width = length(block)
        count = length(domain)
        big(2)^width == count && return factor_constant(true)
        digits = bit_literals(block,count)
        terms = [(;op="cube",literals=[digits[1:index-1];[(bit,false)]])
            for (index,(bit,one)) in enumerate(digits) if one]
        return factor_or(terms)
    end
    return factor_and(tests)
end

factor_rows(encoding,rows) = factor_or([(;op="cube",literals=encode_factor_row(encoding,row)) for row in rows])

function factor_compile!(worker,snapshot,encoding::FiniteEncoding,formula)
    return compute_request!(worker,snapshot,"compile_bool",(;encoding.layout,formula))
end

function factor_membership_proof!(worker,snapshot,encoding::FiniteEncoding,required,observed)
    handles = []
    try
        for rows in (required,observed)
            result = factor_compile!(worker,snapshot,encoding,factor_rows(encoding,rows))
            result.execution == "completed" && result.answer == "value" || return result
            push!(handles,result.value)
        end
        return compute_request!(worker,snapshot,"entails_bool",(;left=handles[1],right=handles[2]))
    finally
        for handle in handles
            compute_request!(worker,snapshot,"release",(;value=handle))
        end
    end
end

function factor_frame_formula(frame,encoding::FiniteEncoding)
    isempty(frame) && return factor_constant(false)
    h,w = size(frame)
    xbits,ybits,cbits = encoding.bits
    function cells(x,y,span_x,span_y,xprefix,yprefix)
        (x >= w || y >= h) && return factor_constant(false)
        color = Int(frame[y+1,x+1])
        if x+span_x <= w && y+span_y <= h &&
                all(==(color),view(frame,y+1:y+span_y,x+1:x+span_x))
            return (;op="cube",literals=[xprefix;yprefix;bit_literals(cbits,encoding.columns[3][color])])
        end
        if span_x >= span_y && span_x > 1
            half = span_x ÷ 2
            bit = xbits[length(xprefix)+1]
            return factor_or([
                cells(x,y,half,span_y,[xprefix;(bit,false)],yprefix),
                cells(x+half,y,half,span_y,[xprefix;(bit,true)],yprefix)
            ])
        end
        half = span_y ÷ 2
        bit = ybits[length(yprefix)+1]
        return factor_or([
            cells(x,y,span_x,half,xprefix,[yprefix;(bit,false)]),
            cells(x,y+half,span_x,half,xprefix,[yprefix;(bit,true)])
        ])
    end
    return cells(0,0,1<<length(xbits),1<<length(ybits),Tuple{Int,Bool}[],Tuple{Int,Bool}[])
end

function role_factor_proof!(worker,proposal,obs,snapshot;memo=nothing)
    tests = proposal.tests
    length(tests) == 1 || return nothing
    test = only(tests)
    test.scope in (:bound,:replicated) || return nothing
    before = last(obs.frames)
    supports = [part.basis for part in test.fragments if part.family in (:pigment,:translation)]
    isempty(supports) && return nothing
    required = sort!(unique!([(x,y,c) for basis in supports for (x,y,c) in basis]))
    isempty(required) && return nothing
    # Prefer factor construction for small recurring bound regions. Large
    # regions continue to use the exact observed region view.
    length(required) <= 64 || return nothing
    all(checkbounds(Bool,before,y+1,x+1) for (x,y,_) in required) ||
        return (;execution="invalid_input",answer="unknown",coverage="unavailable",
            value=nothing,detail="bound role outside the public frame")
    origin = (minimum(first,required),minimum(row->row[2],required))
    local_required = [(x-origin[1],y-origin[2],c) for (x,y,c) in required]
    local_observed = [(x-origin[1],y-origin[2],before[y+1,x+1]) for (x,y,_) in required]
    key = (size(before),Tuple(local_required),Tuple(local_observed))
    cached = isnothing(memo) || !worker.available ? nothing : get(memo,key,nothing)
    reused = !isnothing(cached)
    checked = if reused
        cached
    else
        encoding = finite_encoding((0:size(before,2)-1,0:size(before,1)-1,UInt8(0):UInt8(15)))
        proof = factor_membership_proof!(worker,snapshot,encoding,local_required,local_observed)
        result = (;proof,proved_at=snapshot,proof_origin=origin)
        if !isnothing(memo) && proof.execution == "completed" && proof.answer == "value" && proof.coverage == "complete"
            memo[key] = result
        end
        result
    end
    return merge(checked.proof,(;reused,origin,proof_scope="translated_bound_role",receipt=snapshot,
        checked.proved_at,checked.proof_origin))
end

"""Test the finite observed destination palettes against the learned entry condition."""
function competing_entry_colors(query,expected,observed)
    values = Tuple.(observed)
    required = Tuple(expected)
    # Palette equality is cheaper locally on the measured public workloads. The
    # explicit Factor path verifies identical logical queries and worker costs.
    if isnothing(query) || get(query,:backend,:native) != :factor ||
            isnothing(query.worker) || length(unique(values)) <= 1
        return (;matches=[v == required for v in values],backend=:exact_palette,reads=String[])
    end
    worker = query.worker
    # The cache stores complete Boolean answers, never process-local diagram handles.
    key(v) = (:entry_palette,required,v)
    unseen = [v for v in unique(values) if !haskey(query.memo,key(v))]
    if !isempty(unseen)
        palette = sort!(unique!(UInt8[c for v in (required,unseen...) for c in v]))
        layout = (;order=collect(0:length(palette)-1),style="balanced")
        assignment(colors) = [(i-1,c in colors) for (i,c) in enumerate(palette)]
        formula = (;op="cube",literals=assignment(required))
        compiled = compute_request!(worker,query.snapshot,"compile_bool",(;layout,formula))
        if compiled.execution == "completed" && compiled.answer == "value"
            answer = try
                compute_request!(worker,query.snapshot,"evaluate_bool_batch",
                    (;value=compiled.value,assignments=assignment.(unseen)))
            finally
                compute_request!(worker,query.snapshot,"release",(;value=compiled.value))
            end
            if answer.execution == "completed" && answer.answer == "value" && answer.coverage == "complete"
                answers = answer.value
                length(answers) == length(unseen) && all(v->v isa Bool,answers) ||
                    error("Factor returned an invalid entry condition result")
                for (v,match) in zip(unseen,answers)
                    query.memo[key(v)] = (;match,source=query.snapshot)
                end
            end
        end
    end
    matches = [haskey(query.memo,key(v)) ? query.memo[key(v)].match : missing for v in values]
    reads = unique(String[query.memo[key(v)].source for v in values if haskey(query.memo,key(v))])
    return (;matches,backend=isempty(unseen) ? :factor_cache : :factor,reads)
end
