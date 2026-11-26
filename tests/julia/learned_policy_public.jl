using TddESCat

const TC = TddESCat
const ROOT = normpath(joinpath(@__DIR__,"..",".."))

read_point(data) = Tuple(Int.(data))
read_value(data) = TC.VisualValue(data["width"],data["height"],UInt64(data["mask"]),UInt8(data["pigment"]))
function read_field(data)
    b = data["box"]
    return TC.VisualField(TC.Window(b["x"],b["y"],b["width"],b["height"]),UInt8(data["background"]),data["scale"])
end
read_site(data) = TC.VisualSite(read_field(data["field"]),read_value(data["value"]),data["event"])

function training_prefix(source,cutoff)
    events = TC.recover_run(TC.RunStore(source);read_only=true)
    final = findfirst(row->row.event["command_ref"] == cutoff,events)
    isnothing(final) && error("Training cutoff was not observed")
    prefix = events[1:final]
    control,spatial = TC.VisualControl(),TC.SpatialLearning()
    for (before,after) in zip(prefix,Iterators.drop(prefix,1))
        if after.observation.action["id"] == 0
            TC.begin_visual_attempt!(control)
            continue
        end
        check = TC.read_json(joinpath(source,"checks",after.event["command_ref"]*".json"))
        raw = check["contact_feedback"]
        if !isnothing(raw)
            remaining = [(read_point(p),read_site(q)) for (p,q) in raw["facts"]["remaining"]]
            for (p,q) in remaining
                control.targets[p] = q
            end
            witness = read_site(raw["site"])
            target = read_point(raw["point"])
            facts = TC.ContactFacts(remaining,raw["facts"]["previous_action"],raw["facts"]["domain_reads"])
            spatial.role = TC.MotionShape([(x,y,c) for (x,y,c) in raw["role"]])
            contact = TC.ContactSample(raw["level"],target,read_value(raw["context"]),witness,
                read_field(raw["field"]),read_point(raw["origin"]),raw["action"],Symbol(raw["outcome"]),
                raw["before"],raw["event"],spatial.role,raw["motion_event"],facts,raw["public_state"])
            push!(control.contact_samples,contact)
            push!(control.goal_samples,TC.goal_sample(contact,before,after;attempt=control.attempt_epoch))
            if contact.outcome == :entered
                control.targets[target] = witness
                control.site_entries[target] = contact.event
            end
        end
        if before.observation.levels_completed == after.observation.levels_completed
            TC.update_contact_sites!(control,spatial,after)
        else
            TC.begin_visual_level!(control,spatial)
        end
    end
    return control,[row.event for row in prefix],last(prefix).event["event_id"]
end

function frozen_public_case(knowledge,training,events,held)
    config = TC.load_run_config(held["config"])
    control = TC.VisualControl()
    append!(control.contact_samples,training.contact_samples)
    append!(control.goal_samples,training.goal_samples)
    digest() = TC.content_hash(TC.JSON.json([control.contact_samples,control.goal_samples]))
    original = digest()
    return with_run(held["public"]) do store
        rec = Recorder(store,config)
        TC.before_session!(rec,events)
        @assert open_scorecard!(rec)["completion"] == "confirmed"
        @assert reset!(rec,config.environment["game_id"])["completion"] == "confirmed"
        event = TC.read_json(TC.store_path(store,"events",rec.before_ref*".json"))
        result = TC.run_online!(rec,(;event,observation=rec.observation),config,ROOT;
            knowledge=deepcopy(knowledge),frozen=true,visual_state=control)
        @assert result.frozen_before == result.frozen_after && original == digest()
        TC.atomic_json(joinpath(held["public"],"frozen.json"),merge(result,(training_digest=original,)))
    end
end

mode,source,cutoff,dest,agent = ARGS[1:5]
control,events,available_after = training_prefix(source,cutoff)
store = TC.RunStore(dest)
knowledge = TC.OnlineKnowledge()
config = TC.load_run_config(agent)
if mode == "prepare"
    @assert !isnothing(TC.prepare_policy_learning!(knowledge,config,store,ROOT,control))
else
    @assert mode == "verify"
    job = only(TC.learning_jobs(store))
    corpus = TC.policy_corpus(control)
    manifest = TC.read_json(joinpath(job,"input","manifest.json"))
    snapshot = manifest["evidence_snapshot_id"]
    prepared = (;job,manifest,corpus,snapshot,key=replace(snapshot,"policy-"=>""))
    status = TC.read_json(joinpath(job,"worker-status.json"))
    TC.collect_policy_learning!(knowledge,store,prepared,status;available_after)
    policy = only(knowledge.policies)
    TC.atomic_json(joinpath(dest,"verified-policy.json"),policy)
    for held in TC.read_json(last(ARGS))
        frozen_public_case(knowledge,control,events,held)
    end
end
