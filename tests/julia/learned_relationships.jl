using Test, TddESCat

const TC = TddESCat

@testset "Meter outcomes are fitted from distinct public transfers" begin
    memory = TC.MeterDynamics()
    ground, supply = (0,0), (9,)
    for (i,(action, patch, used, before, after)) in enumerate((
            (1,ground,false,8,7),(1,ground,false,6,5),
            (2,ground,false,8,6),(2,ground,false,6,4),
            (3,supply,false,2,4),(3,supply,false,4,6),
            (3,supply,true,4,5),(3,supply,true,6,7)))
        TC.record_meter_transition!(memory,action,patch,used,true,before,after,"event-"*string(i))
    end
    model = TC.fit_meter_dynamics(memory)
    @test TC.meter_transition(model,1,ground,5,10).value == 4
    @test TC.meter_transition(model,2,ground,5,10).value == 3
    @test TC.meter_transition(model,3,supply,5,10).value == 7
    @test TC.meter_transition(model,3,supply,5,10;used=true).value == 6
    @test TC.meter_transition(model,4,ground,5,10) === nothing
    TC.record_meter_transition!(memory,2,ground,false,true,8,5,"meter-refutes")
    @test TC.meter_transition(TC.fit_meter_dynamics(memory),2,ground,8,10) === nothing
end

@testset "Relative corrections require distinctive joint contexts" begin
    history = [0,1]
    corrections = TC.ProjectionTrial[]
    function trial(i,x,local_color,remote)
        frame = fill(UInt8(2),12,28)
        frame[7,x+1] = UInt8(4)
        frame[7,x+2] = UInt8(local_color)
        frame[3,26] = UInt8(remote)
        same = local_color == remote
        patch = same ? NTuple{5,Int}[] : [(x+1,6,local_color,local_color,8)]
        outcome = same ? "unchanged" : TC.semantic_hash(patch)
        return TC.ProjectionTrial("after-"*string(i),"before-"*string(i),
            frame,history,Int[],outcome,patch,(x,6),String[])
    end
    for (i,(a,b)) in enumerate([(a,b) for a in 0:1 for b in 0:1 for _ in 1:2])
        push!(corrections,trial(i,2i,a,b))
    end
    memory = TC.ProjectionMemory()
    for row in corrections
        TC.observe_projection!(memory,"test",row,[0,1,2])
    end
    fit = memory.scopes["test"]
    @test fit.relative
    @test any(row->first(row.feature) == "joint",fit.conditions)
    held = trial(9,21,0,1)
    applicable = TC.projection_applicability(memory,"test",held.before,history,Int[];origin=held.origin)
    @test applicable.status == "conditioned_projection"
    @test applicable.correction == [(22,6,0,0,8)]
    unseen = copy(held.before)
    unseen[3,26] = UInt8(7)
    @test TC.projection_applicability(memory,"test",unseen,history,Int[];origin=held.origin).status ==
        "unproved_projection_scope"
end
