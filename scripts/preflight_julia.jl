using TOML
using Pkg
using Test

length(ARGS) == 2 && ARGS[1] == "--config" || error("usage: preflight_julia.jl --config <path>")
runtime = TOML.parsefile(ARGS[2])
VERSION == VersionNumber(runtime["julia"]["version"]) || error("Unexpected Julia VERSION: $VERSION")
depot = runtime["julia_cache"]["depot"]
depot in DEPOT_PATH || pushfirst!(DEPOT_PATH, depot)

project_path = joinpath(@__DIR__, "..", "julia", "TddESCat", "Project.toml")
realpath(Base.active_project()) == realpath(project_path) || error("Activate julia/TddESCat first")
Pkg.status()

using TddESCat
import HTTP
import JSON

@testset "HTTP and JSON dependency APIs" begin
    bytes = JSON.json(Dict("action" => 6, "x" => 17, "y" => 29))
    request = HTTP.Request("POST", "/api/cmd/ACTION6", ["Content-Type" => "application/json"], bytes)
    @test request.method == "POST"
    @test JSON.parse(String(request.body)) == Dict("action" => 6, "x" => 17, "y" => 29)
end

include(joinpath(@__DIR__, "..", "tests", "julia", "dependency_contracts.jl"))
