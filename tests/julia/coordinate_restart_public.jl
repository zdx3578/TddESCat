using Test, TddESCat

const TC = TddESCat
const CONFIG = load_run_config(first(ARGS))

@testset "The confirmed coordinate ledger survives a failed attempt" begin
    with_run(last(ARGS)) do store
        rec = Recorder(store,CONFIG)
        memory = TC.InterventionMemory()
        @test open_scorecard!(rec)["completion"] == "confirmed"
        @test reset!(rec,CONFIG.environment["game_id"])["completion"] == "confirmed"
        entry() = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),
            observation=rec.observation)
        function step(ordinal)
            before = entry()
            choice = TC.choose_intervention(memory,NamedTuple[],before.observation,NamedTuple[],Dict();
                explore=true,goal_learning=true,confirmed_count=ordinal-1)
            @test choice.probe == :coordinate
            @test submit_action!(rec,6;x=choice.action["x"],y=choice.action["y"])["completion"] == "confirmed"
            after = entry()
            TC.observe_intervention!(memory,choice,before,after,TC.observed_effects(before,after);ordinal)
            return (action=choice.action,event=after.event["event_id"],state=after.observation.state)
        end
        failed = step(1)
        @test failed.action == TC.click_action((0,0)) && failed.state == "GAME_OVER"
        @test reset!(rec,CONFIG.environment["game_id"])["completion"] == "confirmed"
        retry = rec.before_ref
        TC.rebind_interventions!(memory)
        @test (0,(0,0)) in memory.points && isnothing(memory.prior_observation)
        next = step(2)
        @test next.action == TC.click_action((0,32)) && next.state == "WIN"
        @test close_scorecard!(rec)["completion"] == "confirmed"
        @test last(recover_run(store)).event["event_id"] == next.event
        TC.atomic_json(TC.store_path(store,"coordinate-restart.json"),(;failed,retry,next))
    end
end
