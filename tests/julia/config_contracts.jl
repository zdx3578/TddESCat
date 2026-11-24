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
        for (before, after) in (("schema_version = 2", "schema_version = 1"),
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

@testset "Pattern maze stays on the original local game" begin
    base = read(joinpath(root,"config/ls20_clear.toml"),String)
    mktempdir() do folder
        path = joinpath(folder,"agent.toml")
        write(path,base)
        @test load_run_config(path).planning["pattern_maze"] === true
        for (before,after) in (("competition_mode = false","competition_mode = true"),
                ("127.0.0.1","example.com"),
                ("ls20-9607627b","ls20-other"),
                ("pattern_maze = true","pattern_maze = 1"))
            write(path,replace(base,before=>after))
            @test_throws ArgumentError load_run_config(path)
        end
    end
end
