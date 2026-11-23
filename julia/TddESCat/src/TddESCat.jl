module TddESCat

using TOML
using SHA
using Dates
import HTTP
import JSON

include("Config.jl")
include("PublicAPI.jl")
include("RunStore.jl")
include("Evidence.jl")

export load_run_config, open_client, list_games, screen_click, with_run, Recorder
export open_scorecard!, reset!, submit_action!, close_scorecard!, recover_run, replay_run!

end
