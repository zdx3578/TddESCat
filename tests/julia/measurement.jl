using Test
using TddESCat

const TC = TddESCat

function panel!(frame,b,n)
    frame[b.y:b.y+b.height+1,b.x:b.x+b.width+1] .= 0x08
    for u in 0:TC.meter_length(b)-1, v in 0:TC.meter_thickness(b)-1
        x,y = TC.meter_point(b,u,v)
        frame[y+1,x+1] = u < n ? 0x0b : 0x06
    end
end

function frames_at(left,right,actor=3)
    frame = fill(0x00,18,20)
    frame[12:13,actor:actor+1] .= 0x03
    panel!(frame,Window(2,2,8,2),left)
    panel!(frame,Window(14,2,1,8),right)
    return frame
end

function snapshot(n,action,frames)
    event = Dict("event_id"=>"receipt-$n","before_ref"=>n == 1 ? nothing : "receipt-$(n-1)",
        "sequence"=>n,"response_blob"=>"response-$n")
    observation = TC.PublicObservation("counter-fixture","test-session",frames,"NOT_FINISHED",
        0,1,Dict("id"=>action),[1,5],false)
    return (;event,observation)
end

@testset "A display keeps its own method, value and public witness" begin
    full = frames_at(8,8)
    a = frames_at(6,6)
    b = frames_at(4,4,5)
    c = frames_at(0,8,5)
    episodes = [[snapshot(1,0,[full]),snapshot(2,5,[a,a]),snapshot(3,1,[b]),snapshot(4,5,[c])]]
    observations = TC.replay_effects!(Dict{String,TC.PublicEffects}(),episodes)
    still = observations["receipt-2"]
    meter = still.effects
    @test [effect.family for effect in meter] == [:measurement,:measurement]
    @test isempty(still.residual) && still.complete
    @test meter[1].context.instance != meter[2].context.instance
    @test all(e->e.context.before_value == 8 && e.context.after_value == 6,meter)
    @test all(e->e.context.response_values == [6,6],meter)
    @test isempty(still.live_meters)
    moved = observations["receipt-3"]
    @test length(moved.live_meters) == 2
    @test any(e->e.family == :translation,moved.effects)
    @test all(e->e.context.binding.calibrated_at == "receipt-2",filter(e->e.family == :measurement,moved.effects))
    @test isempty(moved.residual) && moved.complete
    @test [e.context.after_value for e in observations["receipt-4"].effects if e.family == :measurement] == [0,8]
    @test all(e->!isnothing(TC.read_meter(c,e.context.binding)),meter)

    corpus = TC.compile_sequence_corpus(episodes;observations)
    @test corpus.confirmed_program_actions == 3
    @test length(only(corpus.scopes)["shared"][1]) == 2
    @test any(slot->slot["sort"] == "MeasureBefore",corpus.slots)
    effect_corpus = TC.relation_corpus(collect(zip(only(episodes)[1:3],only(episodes)[2:4]));observations)
    @test effect_corpus.observed[2] === moved
    @test any(program->occursin("display_shift",program),effect_corpus.programs)
    @test all(program->!occursin("count_shift",program),effect_corpus.programs)

    models = [TC.EffectModel(:measurement,TC.MotionShape(),nothing,e.values,TC.MotionShape(),false,
        e.context.binding) for e in meter]
    rule = TC.JointMechanism("meter-rule",5,models,["meter-definition"],"receipt-2",
        TC.Pixel[],TC.Pixel[],UInt8[],nothing,nothing)
    registry = [e.context.binding for e in meter]
    groups = TC.public_components(a)
    prediction = TC.evaluate_joint_rule(rule,a,groups,[],Dict("id"=>5);meters=registry)
    @test prediction.truth == TC.proven
    @test length(TC.plan_channels(prediction.fragments)) == 2
    @test all(==("supported"),values(TC.measure_joint((model=rule,fragments=prediction.fragments),frames_at(4,4)).assessments))
    @test TC.evaluate_joint_rule(rule,c,TC.public_components(c),[],Dict("id"=>5);meters=registry).reason ==
        "resource_precondition"
    @test isnothing(TC.match_meter(first(registry),[TC.MeterBinding(
        TC.MeterFace(first(registry).face.box,0x0a,0x08,"other"),0x06,false,"calibration"),
        TC.MeterBinding(TC.MeterFace(first(registry).face.box,0x09,0x08,"another"),0x06,false,"other-calibration")]))

    dirty = copy(b)
    dirty[3,3] = 0x0d
    @test isnothing(TC.read_meter(dirty,first(registry)))
    @test isnothing(TC.read_meter(b[1:9,1:8],first(registry)))
    ob = TC.replay_effects!(Dict{String,TC.PublicEffects}(),[[episodes[1][1:2];snapshot(3,1,[dirty,b])]])
    @test !ob["receipt-3"].complete
    @test "measurement_visibility_unresolved" in ob["receipt-3"].alternatives
    @test "intermediate_frames_require_separate_interpretation" in ob["receipt-3"].alternatives

    unaltered = TC.replay_effects!(Dict{String,TC.PublicEffects}(),[[episodes[1][1:3];snapshot(4,5,[b])]])
    @test isempty(unaltered["receipt-4"].effects)
    @test isempty(unaltered["receipt-4"].residual)
end
