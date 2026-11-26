module TddESCat

using TOML
using SHA
using Dates
import HTTP
import JSON

include("Config.jl")
include("PublicAPI.jl")
include("RunStore.jl")
include("ComputeBridge.jl")
include("FactorRankAdapter.jl")
include("ConstraintAdapter.jl")
include("Evidence.jl")
include("Contexts.jl")
include("Grounding.jl")
include("PhaseCheck.jl")
include("CategoryBackend.jl")
include("ConceptTerms.jl")
include("ConceptIdentity.jl")
include("Schemas.jl")
include("StitchCodec.jl")
include("Library.jl")
include("StitchBridge.jl")
include("Mechanisms.jl")
include("Measurement.jl")
include("LocalEffects.jl")
include("JointMechanisms.jl")
include("GuardRepair.jl")
include("Revision.jl")
include("Controller.jl")
include("ExperimentDesign.jl")
include("AssociationScheduler.jl")
include("VisualFields.jl")
include("RelationSemantics.jl")
include("SpatialLearning.jl")
include("SceneMemory.jl")
include("ContactLearning.jl")
include("GoalLearning.jl")
include("InterventionLearning.jl")
include("MeterDynamics.jl")
include("VisualControl.jl")
include("ProjectionRevision.jl")
include("RelationTasks.jl")
include("OnlineSession.jl")
include("GalleyAdapter.jl")
include("RelationQueries.jl")
include("AssociationIndex.jl")
include("ConceptConstruction.jl")
include("SequenceCorpus.jl")
include("ProgramSemantics.jl")
include("PolicySemantics.jl")
include("RelationPolicies.jl")
include("RelationLearning.jl")
include("Plan.jl")
include("QueryAbstraction.jl")
include("ProjectedPlanning.jl")
include("GoalRegression.jl")

export load_run_config, open_client, list_games, screen_click, with_run, Recorder
export open_scorecard!, reset!, submit_action!, close_scorecard!, recover_run, replay_run!

export Window, PixelSource, crop_frame, embed_point, color_components, support_candidates
export correspondence_candidates, ground_event, scene_transform_candidates, check_available
export support_graph, match_pattern, glue_patterns, glue_matches, check_schema_map
export ConceptTerm, Literal, Slot, Parameter, Call, Primitive, infer_term, evidence_signature
export historical_program, render_term, schema_context

export LibrarySnapshot, freeze_stitch_job, read_stitch_rounds, publish_library

end
