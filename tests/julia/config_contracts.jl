using Test
using TddESCat

root = normpath(joinpath(@__DIR__, "../.."))
@testset "Run configuration" begin
    cfg = load_run_config(joinpath(root, "config/real_public.toml"))
    @test cfg.run_root == joinpath(root, "runs")
    @test cfg.environment["credentials_file"] == joinpath(root, "config/secrets.local.toml")
    @test cfg.learning["engine"] == joinpath(root, "target/release/tddesc-stitch")
    @test !haskey(load_run_config(joinpath(root, "config/bench_agent.toml")).environment, "credentials_file")
    mktempdir() do folder
        path = joinpath(folder, "agent.toml")
        base = read(joinpath(root, "config/bench_agent.toml"), String)
        for (before, after) in (("schema_version = 1", "schema_version = 2"),
                ("post_retry = false", "post_retry = true"),
                ("redirect = false", "redirect = 0"),
                ("max_public_commands = 2", "max_public_commands = true"),
                ("game_selection = \"public_list\"", "game_selection = \"explicit\""))
            write(path, replace(base, before => after))
            @test_throws ArgumentError load_run_config(path)
        end
        write(path, base * "\nunknown_field = 1\n")
        @test_throws ArgumentError load_run_config(path)
    end
end
