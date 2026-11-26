using TddESCat

const TC = TddESCat
const ROOT = normpath(joinpath(@__DIR__,"..",".."))
const WIDTHS = [1,2,4]

function translation_model(episodes)
    before,after = first(episodes)[1:2]
    effects = TC.observed_effects(before,after)
    effect = only(effects.effects)
    @assert effects.complete && effect.family == :translation
    a,b = last(before.observation.frames),last(after.observation.frames)
    anchor = TC.anchor(effect.before)
    model = TC.EffectModel(:translation,TC.MotionShape(collect(TC.shape_template(effect.before))),
        nothing,effect.values,TC.MotionShape(),false)
    entry = TC.destination_entry(a,TC.MotionBinding(effect.before,anchor),Tuple(effect.values))
    rule = TC.JointMechanism("verified-translation",1,[model],String[],effects.event_id,
        [anchor],[(0,0)],sort!(collect(entry)),nothing,TC.frame_patch(effects,a,b,[anchor]))
    return TC.ActiveMechanism(rule,TC.GuardSearch(TC.MotionPredicate[],[effects.event_id],
        String[],String[],true,true,1),String[],String[])
end

function verify_step(knowledge, before, after, choice, projection;frozen)
    a,b = last(before.observation.frames),last(after.observation.frames)
    effects = TC.observed_effects(before,after)
    assessment = TC.measure_joint((model=choice.model.rule,fragments=choice.fragments),b)
    feedback = TC.check_projection!(knowledge.projections,projection,a,b,effects,assessment,WIDTHS;frozen)
    @assert feedback.local_supported && feedback.hypothesis_complete
    return (;effects,assessment,feedback)
end

function fit_projection!(knowledge, episodes)
    rows = []
    for episode in episodes
        history = [0]
        for (before,after) in zip(episode,Iterators.drop(episode,1))
            observation = before.observation
            decision = TC.ranked_public_actions(knowledge,observation,history,Dict{TC.ConcreteAction,Int}(),4096)
            item = only(filter(row->row.action["id"] == 1,decision.ranked))
            frame = last(observation.frames)
            projection = TC.projected_contract(knowledge.projections,item.chosen,frame,history)
            claim = TC.projection_record(projection,frame)
            outcome = verify_step(knowledge,before,after,item.chosen,projection;frozen=false)
            push!(rows,(;event=after.event["event_id"],claim,feedback=outcome.feedback))
            push!(history,1)
        end
    end
    return rows
end

function execute_program(knowledge, requests, episodes)
    program = first(filter(p->length(p.steps) == 2 && all(s->s["action"]["id"] == 1,p.steps),knowledge.programs))
    config = TC.load_run_config(requests["config"])
    with_run(requests["held"]) do store
        rec = Recorder(store,config)
        TC.before_session!(rec,[row.event for episode in episodes for row in episode])
        @assert open_scorecard!(rec)["completion"] == "confirmed"
        @assert reset!(rec,config.environment["game_id"])["completion"] == "confirmed"
        prior = () -> (event=TC.read_json(TC.store_path(store,"events",rec.before_ref*".json")),
            observation=rec.observation)
        cursor = TC.ProgramCursor(program,1,[])
        history = [0]
        rows = []
        for i in 1:length(program.steps)
            before = prior()
            decision = TC.ranked_public_actions(knowledge,before.observation,history,Dict{TC.ConcreteAction,Int}(),
                4096;composing=true,programs_pending=true,program_cursor=cursor)
            item = TC.current_program_step(cursor,decision)
            @assert !isnothing(item) item
            projection = item.projection_contract
            @assert projection.status == "conditioned_projection"
            @assert projection.base != projection.frame
            frame = last(before.observation.frames)
            claim = TC.projection_record(projection,frame)
            prediction = TC.predict_public(rec,item;plan_reads=unique([program.sources;projection.reads]))
            @assert submit_action!(rec,item.action["id"];prediction)["completion"] == "confirmed"
            after = prior()
            outcome = verify_step(knowledge,before,after,item.chosen,projection;frozen=true)
            @assert outcome.feedback.matching
            status = TC.program_feedback!(cursor,item,outcome.assessment,outcome.effects)
            @assert status == (i == 1 ? "advance" : "completed") status
            push!(rows,(;event=after.event["event_id"],claim,feedback=outcome.feedback,status))
            push!(history,item.action["id"])
        end
        @assert close_scorecard!(rec)["completion"] == "confirmed"
        return (;definition=program.definition,publication=program.publication,rows)
    end
end

mode,public = ARGS
requests = TC.read_json(joinpath(public,"projected-program-inputs.json"))
load_episode(path) = TC.recover_run(TC.RunStore(path);read_only=true)
training = load_episode.(requests["training"])
corpus = TC.compile_sequence_corpus(training)
store = TC.RunStore(public)
config = TC.load_run_config(requests["config"])
knowledge = TC.OnlineKnowledge()
if mode == "prepare"
    @assert !isnothing(TC.prepare_program_learning!(knowledge,config,store,ROOT,corpus))
else
    @assert mode == "verify"
    job = only(TC.learning_jobs(store))
    manifest = TC.read_json(joinpath(job,"input","manifest.json"))
    prepared = (;job,manifest,corpus,snapshot=manifest["evidence_snapshot_id"],key=TC.program_corpus_key(corpus))
    TC.collect_program_learning!(knowledge,store,prepared,TC.read_json(joinpath(job,"worker-status.json")))
    @assert !isempty(knowledge.programs)
    push!(knowledge.active,translation_model(training))
    earlier = load_episode.(requests["scope"])
    learned = fit_projection!(knowledge,earlier)
    @assert only(values(knowledge.projections.scopes)).relative
    actual = execute_program(knowledge,requests,[training;earlier])
    TC.atomic_json(joinpath(public,"projected-program.json"),(;learned,actual))
end
