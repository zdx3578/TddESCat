const COMPUTE_PROTOCOL = "compute/v1"
const COMPUTE_EXECUTION = ("completed","incomplete","unsupported","invalid_input","failed","invalidated")

mutable struct ComputeWorker
    process::Base.Process
    request_id::Int
    lock::ReentrantLock
    available::Bool
end

ComputeWorker(command::Cmd) = ComputeWorker(open(command,"r+"),0,ReentrantLock(),true)

function compute_request!(worker::ComputeWorker, snapshot::String, operation::String, payload=nothing)
    return lock(worker.lock) do
        worker.available || return (;execution="invalidated",answer="unknown",coverage="unavailable",
            value=nothing,detail="worker generation is closed")
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

function with_compute(f,config)
    backends = Dict{String,ComputeWorker}()
    try
        if !isnothing(config.compute)
            for (name,path) in config.compute
                command = endswith(name,"_python") ? Cmd([path,"-m","tddesc_compute.worker"]) : Cmd([path])
                worker = ComputeWorker(command)
                backends[name] = worker
                expected = endswith(name,"_python") ? "cvc5" : "atddc"
                capabilities = require_compute_value(compute_request!(worker,"bootstrap","capabilities"))
                capabilities["backend"] == expected || error("Unexpected compute backend")
            end
            if haskey(config.compute,"solver_python") && get(config.learning,"sequences",false)
                command = Cmd([config.compute["solver_python"],"-m","tddesc_compute.worker"])
                backends["policy_synthesis"] = ComputeWorker(command)
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
