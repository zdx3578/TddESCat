using TddESCat
import JSON

const TC = TddESCat
const requests = JSON.parsefile(only(ARGS))
const history_lengths = [1,2,4]

function preceding(path)
    episode = recover_run(TC.RunStore(path);read_only=true)
    before,after = episode
    return (;before,after,effects=TC.observed_effects(before,after))
end

function earlier_case(record,knowledge)
    before = last(record.before.observation.frames)
    row = only(filter(x->x.action["id"] == 1,TC.ranked_public_actions(
        knowledge,record.before.observation,[0],Dict{TC.ConcreteAction,Int}(),4096).ranked))
    @assert !isnothing(row.chosen)
    projection = TC.projected_contract(knowledge.projections,row.chosen,before,[0])
    after = last(record.after.observation.frames)
    local_feedback = TC.measure_joint((model=row.chosen.model.rule,fragments=row.chosen.fragments),after)
    verdict = TC.check_projection!(knowledge.projections,projection,before,after,record.effects,
        local_feedback,history_lengths;frozen=false)
    @assert verdict.local_supported && verdict.hypothesis_complete
    return verdict
end

earlier = preceding.(requests["earlier"])
base = first(earlier)
effect = only(base.effects.effects)
@assert effect.family == :translation && base.effects.complete
frame = last(base.before.observation.frames)
after = last(base.after.observation.frames)
anchors = [TC.anchor(effect.before)]
model = TC.EffectModel(:translation,TC.MotionShape(collect(TC.shape_template(effect.before))),
    nothing,effect.values,TC.MotionShape(),false)
colors = TC.destination_entry(frame,TC.MotionBinding(effect.before,only(anchors)),Tuple(effect.values))
rule = TC.JointMechanism("observed-translation",1,[model],String[],base.effects.event_id,
    anchors,[(0,0)],sort!(collect(colors)),nothing,TC.frame_patch(base.effects,frame,after,anchors))
knowledge = TC.OnlineKnowledge()
support = TC.GuardSearch(TC.MotionPredicate[],[base.effects.event_id],String[],String[],true,true,1)
push!(knowledge.active,TC.ActiveMechanism(rule,support,String[],String[]))
observed = [earlier_case(record,knowledge) for record in earlier[1:3]]
@assert observed[1].matching && !observed[2].matching && observed[3].local_supported
@assert isempty(observed[2].inside_writes) && !isempty(observed[2].outside_writes)
@assert !isnothing(observed[2].revision)
id = only(keys(knowledge.projections.scopes))
before_patch = knowledge.projections.scopes[id].version
outputs = []
prior = [entry.event for path in requests["earlier"] for entry in recover_run(TC.RunStore(path);read_only=true)]
for (index,probe) in enumerate(requests["probes"])
    config = load_run_config(probe["config"])
    result = with_run(probe["output"]) do store
        rec = Recorder(store,config)
        TC.before_session!(rec,prior)
        @assert open_scorecard!(rec)["completion"] == "confirmed"
        @assert reset!(rec,config.environment["game_id"])["completion"] == "confirmed"
        obs = rec.observation
        entry = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),observation=obs)
        decision() = TC.ranked_public_actions(knowledge,obs,[0],Dict{TC.ConcreteAction,Int}(),4096;
            composing=true)
        if index == 1
            rejected = only(filter(x->x.action["id"] == 1,decision().ranked))
            @assert rejected.projection === nothing && rejected.reason == "unproved_projection_scope"
            additional = earlier_case(earlier[4],knowledge)
            push!(observed,additional)
            @assert knowledge.projections.scopes[id].version != before_patch
        end
        item = first(decision().ranked)
        @assert item.action["id"] == 1 && item.projection_contract.status == "conditioned_projection"
        claim = TC.projection_record(item.projection_contract,last(obs.frames))
        local_prediction = TC.predict_public(rec,item;plan_reads=item.projection_contract.reads)
        command = submit_action!(rec,item.action["id"];prediction=local_prediction)
        @assert command["completion"] == "confirmed"
        outcome = rec.observation
        step = (event=TC.read_json(TC.store_path(store,"events",rec.before_ref * ".json")),observation=outcome)
        assessment = TC.measure_joint((model=item.chosen.model.rule,fragments=item.chosen.fragments),
            last(outcome.frames))
        feedback = TC.check_projection!(knowledge.projections,item.projection_contract,
            last(obs.frames),last(outcome.frames),TC.observed_effects(entry,step),assessment,
            history_lengths;frozen=true)
        @assert feedback.matching && feedback.local_supported
        @assert close_scorecard!(rec)["completion"] == "confirmed"
        (;before_ref=entry.event["event_id"],ref=step.event["event_id"],claim,feedback,resulting=outcome.state)
    end
    push!(outputs,result)
end
TC.atomic_json(requests["output"],(;observed,outputs))
