struct RunStore
    public_dir::String
end

store_path(store, parts...) = joinpath(store.public_dir, parts...)
content_hash(bytes) = bytes2hex(sha256(bytes))
utc_timestamp() = string(now(UTC)) * "Z"

function sync_directory(directory)
    handle = ccall(:open, Cint, (Cstring, Cint), directory, 0)
    systemerror("open directory", handle < 0)
    try
        systemerror("fsync directory", ccall(:fsync, Cint, (Cint,), handle) != 0)
    finally
        ccall(:close, Cint, (Cint,), handle)
    end
end

function atomic_write(path, bytes)
    directory = dirname(path)
    mkpath(directory)
    temp, io = mktemp(directory)
    try
        write(io, bytes)
        flush(io)
        systemerror("fsync file", ccall(:fsync, Cint, (Cint,), fd(io)) != 0)
        close(io)
        systemerror("rename", ccall(:rename, Cint, (Cstring, Cstring), temp, path) != 0)
        sync_directory(directory)
    finally
        isopen(io) && close(io)
        isfile(temp) && rm(temp)
    end
    return nothing
end

atomic_json(path, value) = atomic_write(path, JSON.json(value) * "\n")
parse_json(text) = JSON.parse(text; dicttype=Dict{String,Any}, allownan=false)
read_json(path) = JSON.parsefile(path; dicttype=Dict{String,Any}, allownan=false)

function with_run(f, public_dir::AbstractString)
    dir = abspath(public_dir)
    mkpath(dir)
    return open(joinpath(dir, ".writer.lock"), "a") do io
        systemerror("run already has a writer", ccall(:flock, Cint, (Cint, Cint), fd(io), 6) != 0)
        f(RunStore(dir))
    end
end

function write_blob(store, bytes)
    digest = content_hash(bytes)
    path = store_path(store, "blobs", digest)
    if isfile(path)
        read(path) == bytes || error("Existing blob digest mismatch")
    else
        atomic_write(path, bytes)
    end
    return digest
end

function read_blob(store, digest)
    digest isa String && occursin(r"^[a-f0-9]{64}\z", digest) || error("Invalid blob digest")
    bytes = read(store_path(store, "blobs", digest))
    content_hash(bytes) == digest || error("Blob digest mismatch")
    return bytes
end

function records(store, folder)
    directory = store_path(store, folder)
    isdir(directory) || return Dict{String,Any}[]
    field = folder == "events" ? "event_id" : "command_id"
    return map(filter(name -> endswith(name, ".json"), readdir(directory))) do name
        data = read_json(joinpath(directory, name))
        get(data, field, "") * ".json" == name || error("Mismatched record identity")
        data
    end
end

function save_command(store, command)
    atomic_json(store_path(store, "commands", command["command_id"] * ".json"), command)
end

function commit_event(store, event)
    path = store_path(store, "events", event["event_id"] * ".json")
    if isfile(path)
        read_json(path) == event || error("Conflicting event identity")
    else
        atomic_json(path, event)
    end
    return event
end
