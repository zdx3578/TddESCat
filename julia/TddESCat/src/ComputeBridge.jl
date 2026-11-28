const COMPUTE_PROTOCOL = "compute/v1"
const COMPUTE_EXECUTION = ("completed","incomplete","unsupported","invalid_input","failed","invalidated")

mutable struct ComputeWorker
    process::Base.Process
    request_id::Int
    lock::ReentrantLock
    available::Bool
    capabilities::Union{Nothing,Dict{String,Any}}
end

ComputeWorker(command::Cmd) = ComputeWorker(open(command,"r+"),0,ReentrantLock(),true,nothing)

function compute_request!(worker::ComputeWorker, snapshot::String, operation::String, payload=nothing)
    return lock(worker.lock) do
        worker.available || return (;execution="invalidated",answer="unknown",coverage="unavailable",
            value=nothing,detail="worker generation is closed")
        if !isnothing(worker.capabilities) && operation ∉ worker.capabilities["operations"]
            return (;execution="unsupported",answer="unknown",coverage="unavailable",
                value=nothing,detail="operation is outside the declared backend capabilities")
        end
        worker.request_id += 1
        id = worker.request_id
        body = Dict{String,Any}("protocol"=>COMPUTE_PROTOCOL,"request_id"=>id,
            "snapshot"=>snapshot,"operation"=>operation)
        isnothing(payload) || (body["payload"] = payload)
        try
            write(worker.process,JSON.json(body),'\n')
            flush(worker.process)
            eof(worker.process) && error("Compute worker exited")
            result = parse_json(readline(worker.process))
            result["protocol"] == COMPUTE_PROTOCOL && result["request_id"] == id &&
                result["snapshot"] == snapshot || error("Compute response identity mismatch")
            execution,answer,coverage = result["execution"],result["answer"],result["coverage"]
            execution in COMPUTE_EXECUTION && answer in ("value","unknown") &&
                coverage in ("complete","partial","unavailable") || error("Invalid compute result status")
            execution == "completed" || answer == "unknown" || error("Incomplete computation claimed an answer")
            return (;execution,answer,coverage,value=result["value"],detail=result["detail"])
        catch e
            e isa InterruptException && rethrow()
            worker.available = false
            return (;execution="failed",answer="unknown",coverage="unavailable",
                value=nothing,detail=sprint(showerror,e))
        end
    end
end

function Base.close(worker::ComputeWorker)
    lock(worker.lock) do
        worker.available = false
        isopen(worker.process) && close(worker.process)
    end
end

function declare_compute_backend!(worker,entry,expected,required)
    capabilities = require_compute_value(compute_request!(worker,"bootstrap","capabilities"))
    operations = get(capabilities,"operations",nothing)
    capabilities["backend"] == expected && nonempty_string(get(capabilities,"version",nothing)) &&
        operations isa AbstractVector && all(nonempty_string,operations) && allunique(operations) ||
        error("Invalid compute capabilities for " * entry)
    issubset(required,operations) || error("Compute backend is missing required operations for " * entry)
    worker.capabilities = capabilities
    return worker
end

function with_compute(f,config)
    backends = Dict{String,ComputeWorker}()
    try
        if !isnothing(config.compute)
            for (name,path) in config.compute
                command = endswith(name,"_python") ? Cmd([path,"-m","tddesc_compute.worker"]) : Cmd([path])
                worker = ComputeWorker(command)
                backends[name] = worker
                if name == "circuit_python"
                    declare_compute_backend!(worker,name,"cvc5",["train_circuit","query_circuit"])
                elseif name == "solver_python"
                    declare_compute_backend!(worker,name,"cvc5",["solve","synthesize_guard"])
                else
                    required = ["compile_bool","entails_bool","release"]
                    if !isnothing(config.learning) && get(config.learning,"competing_role_backend","native") == "factor"
                        push!(required,"evaluate_bool_batch")
                    end
                    declare_compute_backend!(worker,name,"atddc",required)
                end
            end
            if haskey(config.compute,"solver_python") && !isnothing(config.learning) &&
                    get(config.learning,"sequences",false)
                command = Cmd([config.compute["solver_python"],"-m","tddesc_compute.worker"])
                worker = ComputeWorker(command)
                backends["policy_synthesis"] = worker
                declare_compute_backend!(worker,"policy_synthesis","cvc5",["synthesize_guard"])
            end
        end
        return f(backends)
    finally
        for worker in values(backends)
            close(worker)
        end
    end
end

function require_compute_value(result)
    result.execution == "completed" && result.answer == "value" && result.coverage == "complete" ||
        throw(ArgumentError("Compute value unavailable ($(result.execution), $(result.detail))"))
    return result.value
end
