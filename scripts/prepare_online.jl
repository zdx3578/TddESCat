import JSON
import Preferences
import TOML

project = Base.active_project()
package = TOML.parsefile(project)
package["name"] == "TddESCat" || error("Activate the TddESCat project before preparing online methods")
uuid = Base.UUID(package["uuid"])
if Preferences.load_preference(uuid,"precompile_online",false) !== true
    Preferences.set_preferences!((uuid,package["name"]),
        "precompile_online"=>true;project_toml=project,force=true)
end

using TddESCat

started = time_ns()
compiled = TddESCat.precompile_online_methods()
println(JSON.json((;enabled=TddESCat.PRECOMPILE_ONLINE,compiled,
    method_check_seconds=(time_ns()-started)/1e9,julia_version=string(VERSION))))
