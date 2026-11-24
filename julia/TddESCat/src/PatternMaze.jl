const MazePoint = NTuple{2,Int}
const MazePicture = Tuple{UInt16,UInt8}
const MAZE_MOVES = ((0,-5),(0,5),(-5,0),(5,0))
const MAZE_UNKNOWN = 0xff
const MAZE_CAPACITY = 42

@enum MazeRune TurnRune PatternRune ColorRune
const MAZE_RUNES = Dict(
    TurnRune => (3,0,3,1,0,0,3,1,3),
    PatternRune => (0,3,3,3,0,0,3,0,3),
    ColorRune => (9,14,14,9,0,8,12,12,8),
)
const MAZE_BATTERY = (11,11,11,11,3,11,11,11,11)

# Cycles identified by changing one visible rune at a time in the native game.
const MAZE_PICTURES = UInt16[410,359,371,466,493,174]
const MAZE_COLORS = UInt8[9,14,8,12]

maze_add(a, b) = (a[1] + b[1], a[2] + b[2])
maze_pixel(frame, x, y) = 0 <= x < 64 && 0 <= y < 64 ? frame[y+1,x+1] : MAZE_UNKNOWN
maze_inside(q, x, y, side) = q[1] <= x < q[1]+side && q[2] <= y < q[2]+side
maze_lit(p, x, y) = (2(x-p[1])-3)^2 + (2(y-p[2])-3)^2 <= 40^2
maze_hud(x, y) = y >= 60 || (x <= 10 && y >= 53)

function maze_avatar(frame)
    size(frame) == (64,64) || throw(ProtocolError("pattern_maze_frame_size"))
    positions = MazePoint[]
    for y in 0:50, x in 0:59
        frame[y+1,x+1] == 12 || continue
        all(frame[y+dy+1,x+dx+1] == (dy < 2 ? 12 : 9) for dy in 0:4 for dx in 0:4) &&
            push!(positions, (x,y))
    end
    length(positions) == 1 || throw(ProtocolError("pattern_maze_avatar"))
    return only(positions)
end

function maze_pattern(frame, x, y, stride)
    values = ntuple(i -> maze_pixel(frame, x + stride*mod(i-1,3), y + stride*div(i-1,3)), 9)
    colors = unique(filter(!=(0x05), values))
    length(colors) == 1 && only(colors) in MAZE_COLORS || return nothing
    color = only(colors)
    bits = UInt16(sum(UInt16(values[i] == color) << (i-1) for i in 1:9))
    return (bits, color)
end

function maze_observation(frame)
    point = maze_avatar(frame)
    picture = maze_pattern(frame, 3, 55, 2)
    isnothing(picture) && throw(ProtocolError("pattern_maze_hud"))
    charge = count(==(0x0b), @view frame[62,14:55])
    return (; point, picture, charge)
end

function maze_ring(f, x, y, width, color)
    return all(maze_pixel(f,x+i,y) == maze_pixel(f,x+i,y+width-1) ==
               maze_pixel(f,x,y+i) == maze_pixel(f,x+width-1,y+i) == color for i in 0:width-1)
end

maze_glyph(f, (x,y)) = ntuple(i -> maze_pixel(f, x+1+mod(i-1,3), y+1+div(i-1,3)), 9)

function maze_slide(frame, (x,y), d)
    dx, dy = d
    x += dx == 0 ? 0 : dx > 0 ? 5 : -1
    y += dy == 0 ? 0 : dy > 0 ? 5 : -1
    return all(maze_pixel(frame, x + (dy == 0 ? 0 : i), y + (dx == 0 ? 0 : i)) == 1 for i in 0:4)
end

mutable struct MazeEvidence
    pixels::Matrix{UInt8}
    points::Vector{MazePoint}
    floor::Set{MazePoint}
    goals::Dict{MazePoint,MazePicture}
    batteries::Set{MazePoint}
    slides::Dict{MazePoint,MazePoint}
    runes::Dict{MazeRune,Dict{Int,MazePoint}}
    views::Set{MazePoint}
    reads::Vector{String}
    start::MazePoint
    fog::Bool
    rate::Int
end

function MazeEvidence(frame)
    p = maze_avatar(frame)
    fog = all(maze_hud(x,y) || maze_lit(p,x,y) || frame[y+1,x+1] == 5 for x in 4:63 for y in 0:59)
    points = [(x,y) for y in mod(p[2],5):5:50 for x in mod(p[1],5):5:59]
    return MazeEvidence(fill(MAZE_UNKNOWN,64,64), points, Set{MazePoint}(),
        Dict{MazePoint,MazePicture}(), Set{MazePoint}(), Dict{MazePoint,MazePoint}(),
        Dict{MazeRune,Dict{Int,MazePoint}}(), Set{MazePoint}(), String[], p, fog, 0)
end

function maze_reveal!(board, frame, point, tick, event)
    new_view = point ∉ board.views
    push!(board.views, point)
    push!(board.floor, point)
    push!(board.reads, event)
    if new_view
        for y in 0:59, x in 0:63
            board.pixels[y+1,x+1] == MAZE_UNKNOWN && !maze_hud(x,y) &&
                !maze_inside(point,x,y,5) && (!board.fog || maze_lit(point,x,y)) &&
                (board.pixels[y+1,x+1] = frame[y+1,x+1])
        end
    end
    tiles = board.pixels
    symbols = Dict{MazeRune,MazePoint}()
    for p in board.points
        x,y = p
        glyph = maze_glyph(frame,p)
        for (rune, icon) in MAZE_RUNES
            glyph == icon && (symbols[rune] = p; push!(board.floor,p))
        end
        new_view || continue
        if maze_ring(tiles,x-2,y-2,9,3) && maze_ring(tiles,x-1,y-1,7,5)
            target = maze_pattern(tiles,x+1,y+1,1)
            isnothing(target) || (board.goals[p] = target; push!(board.floor,p))
        end
        count(==(0x03), @view tiles[y+1:y+5,x+1:x+5]) >= 16 && push!(board.floor,p)
        p in board.floor || continue
        maze_glyph(tiles,p) == MAZE_BATTERY && push!(board.batteries,p)
        for d in MAZE_MOVES
            maze_slide(tiles,p,d) && (board.slides[p] = (-d[1],-d[2]))
        end
    end
    for (rune,p) in symbols
        history = get!(Dict{Int,MazePoint}, board.runes, rune)
        history[tick] = p
    end
    return symbols
end

function maze_cycle(sightings)
    length(sightings) >= 3 || return nothing
    # Visible samples at the same residue must agree. Occluded samples contribute no label.
    span = maximum(keys(sightings)) - minimum(keys(sightings))
    for period in 1:min(span,length(sightings)-2)
        residues = Dict{Int,MazePoint}()
        for (tick,p) in sightings
            phase = mod(tick,period)
            get(residues,phase,p) == p || break
            residues[phase] = p
        end
        all(get(residues,mod(tick,period),nothing) == p for (tick,p) in sightings) || continue
        length(residues) == period || continue
        path = [residues[i] for i in 0:period-1]
        if period > 1
            adjacent(a,b) = abs(a[1]-b[1]) + abs(a[2]-b[2]) == 5
            all(adjacent(path[i],path[mod1(i+1,period)]) for i in 1:period) || continue
        end
        return path
    end
    return nothing
end

function maze_turn(bits)
    return sum(((bits >> (3y+x)) & 0x0001) << (3x+2-y) for y in 0:2 for x in 0:2)
end

function maze_next_pattern(bits)
    for turns in 0:3
        index = findfirst(==(bits), MAZE_PICTURES)
        if !isnothing(index)
            next = MAZE_PICTURES[mod1(index+1,length(MAZE_PICTURES))]
            for _ in 1:mod(-turns,4)
                next = maze_turn(next)
            end
            return next
        end
        bits = maze_turn(bits)
    end
    return nothing
end

function maze_apply(rune::MazeRune, (bits,color))
    rune == TurnRune && return (maze_turn(bits),color)
    if rune == PatternRune
        next = maze_next_pattern(bits)
        return isnothing(next) ? nothing : (next,color)
    end
    i = findfirst(==(color),MAZE_COLORS)
    return (bits,MAZE_COLORS[mod1(i+1,length(MAZE_COLORS))])
end

struct MazeState
    point::MazePoint
    picture::MazePicture
    charge::Int
    used::UInt64
    matched::UInt64
    phase::Int
end

struct MazeModel
    board::MazeEvidence
    gates::Dict{MazePoint,UInt64}
    power::Dict{MazePoint,UInt64}
    runes::Vector{Dict{MazePoint,MazeRune}}
    all_gates::UInt64
    mapped_runes::Bool
end

function maze_model(board)
    bits(ps) = Dict(p => UInt64(1) << (i-1) for (i,p) in enumerate(sort!(collect(ps))))
    gates, power = bits(keys(board.goals)), bits(board.batteries)
    paths = Dict(rune => maze_cycle(data) for (rune,data) in board.runes)
    solved = all(!isnothing,values(paths))
    period = solved ? foldl(lcm, (length(path) for path in values(paths)); init=1) : 1
    runes = [Dict{MazePoint,MazeRune}() for _ in 1:period]
    if solved
        for (rune,path) in paths, phase in 0:period-1
            runes[phase+1][path[mod1(phase+1,length(path))]] = rune
        end
    end
    return MazeModel(board,gates,power,runes,foldl(|,values(gates);init=UInt64(0)),solved)
end

function maze_state(model, obs, used, matched, tick)
    mask(table, points) = foldl(|,(get(table,p,UInt64(0)) for p in points);init=UInt64(0))
    return MazeState(obs.point,obs.picture,obs.charge,mask(model.power,used),
        mask(model.gates,matched),mod(tick,length(model.runes)))
end

function maze_step(model, s, id; explore=false)
    board = model.board
    q = maze_add(s.point,MAZE_MOVES[id])
    s.charge > 0 && q in board.floor || return nothing
    pending(p) = (get(model.gates,p,UInt64(0)) & ~s.matched) != 0
    if haskey(board.slides,q)
        direction = board.slides[q]
        while true
            next = maze_add(q,direction)
            next in board.floor && !pending(next) || break
            q = next
        end
    end
    if pending(q)
        (explore || board.goals[q] != s.picture) && return nothing
    end
    explored_goal = get(model.gates,q,UInt64(0))
    refill = get(model.power,q,UInt64(0)) & ~s.used
    remaining = iszero(refill) ? max(0,s.charge-max(1,board.rate)) : MAZE_CAPACITY
    phase = explore ? 0 : mod(s.phase+1,length(model.runes))
    picture = s.picture
    if !explore && haskey(model.runes[phase+1],q)
        picture = maze_apply(model.runes[phase+1][q],picture)
        isnothing(picture) && return nothing
    end
    return MazeState(q,picture,remaining,s.used|refill,s.matched|explored_goal,phase)
end

maze_key(s) = (s.point,s.picture,s.used,s.matched,s.phase)

function maze_route(model, start, actions; explore=false, lookout=Dict{MazePoint,Int}())
    states = [start]
    parents = [0]
    moves = [0]
    best_charge = Dict(maze_key(start)=>start.charge)
    best_rank = (0,0)
    goal_index = 0
    index = 1
    while index <= length(states)
        s = states[index]
        if explore
            gain = get(lookout,s.point,0)
            rank = (gain,s.charge)
            if gain > 0 && rank > best_rank
                goal_index, best_rank = index, rank
            end
        elseif s.matched == model.all_gates
            goal_index = index
            break
        end
        for id in actions
            next = maze_step(model,s,id;explore)
            isnothing(next) && continue
            key = maze_key(next)
            next.charge > get(best_charge,key,-1) || continue
            best_charge[key] = next.charge
            push!(states,next)
            push!(parents,index)
            push!(moves,id)
        end
        index += 1
    end
    goal_index > 0 || return nothing
    route = Tuple{Int,MazeState}[]
    while parents[goal_index] > 0
        push!(route,(moves[goal_index],states[goal_index]))
        goal_index = parents[goal_index]
    end
    return reverse!(route)
end

function maze_frontier(board)
    return Dict(p => count(board.pixels[y+1,x+1] == MAZE_UNKNOWN && !maze_hud(x,y) &&
        !maze_inside(p,x,y,5) && maze_lit(p,x,y) for x in 4:63 for y in 0:59)
        for p in board.floor if p ∉ board.views && !haskey(board.goals,p))
end

function maze_vantage(board, p)
    score = 0
    for sightings in values(board.runes)
        isnothing(maze_cycle(sightings)) || continue
        for q in unique(values(sightings))
            x,y = q
            maze_lit(p,x+1,y+1) && maze_lit(p,x+3,y+3) && q != p && (score += 1)
        end
    end
    return score
end

function maze_prediction(rec, board, id, expected)
    known = !isnothing(expected)
    values = known ? Dict("point"=>expected.point,"picture"=>expected.picture,
        "minimum_charge"=>expected.charge,"matched_mask"=>expected.matched) : Dict()
    return (before_ref=rec.before_ref, payload=Dict("model_version"=>"ls20-public-pattern-v1",
        "binding"=>[], "event_reads"=>copy(board.reads), "action"=>Dict("id"=>id),
        "guard_truth"=>known ? "true" : "unknown", "query_scope"=>collect(keys(values)),
        "predicted_values"=>values, "enumeration_complete"=>known,
        "assumptions"=>[known ? "observed maze and periodic runes" : "public maze calibration"]))
end

function maze_goal_open(frame, (x,y))
    # The player can hide the center after arrival. The gray perimeter stays readable.
    return !maze_ring(frame,x-1,y-1,7,5)
end

function run_pattern_maze!(rec)
    while rec.observation.state ∉ ("WIN","GAME_OVER") && rec.sent_count < rec.limit && !rec.frozen
        reason = run_pattern_level!(rec)
        reason == "advanced" || return pattern_maze_result(rec,reason)
    end
    reason = rec.frozen ? "quarantined" : rec.observation.state == "WIN" ? "win" :
        rec.observation.state == "GAME_OVER" ? "game_over" : "command_budget"
    return pattern_maze_result(rec,reason)
end

function pattern_maze_result(rec, reason)
    obs = rec.observation
    return (; reason, game_id=obs.game_id, state=obs.state, levels_completed=obs.levels_completed,
        win_levels=obs.win_levels, terminal_event=rec.before_ref)
end

function run_pattern_level!(rec)
    level = rec.observation.levels_completed
    frame = last(rec.observation.frames)
    board = MazeEvidence(frame)
    obs = maze_observation(frame)
    tick = 0
    used, matched = Set{MazePoint}(), Set{MazePoint}()
    maze_reveal!(board,frame,obs.point,tick,rec.before_ref)
    route = Tuple{Int,MazeState}[]
    mode = "observe"
    reset_at = nothing
    while rec.sent_count < rec.limit && !rec.frozen
        actions = sort!(filter(i -> 1 <= i <= 4, rec.observation.available_actions))
        isempty(actions) && return "no_movement_action"
        model = maze_model(board)
        s = maze_state(model,obs,used,matched,tick)
        if isempty(route)
            planned = if !isempty(board.goals) && model.mapped_runes && board.rate > 0 &&
                    s.matched != model.all_gates
                maze_route(model,s,actions)
            end
            if !isnothing(planned) && !isempty(planned)
                mode = "solve"
                route = planned
            else
                mode = "observe"
                look = board.fog && board.rate > 0 ? maze_frontier(board) : Dict{MazePoint,Int}()
                planned = isempty(look) ? nothing : maze_route(model,s,actions;explore=true,lookout=look)
                if !isnothing(planned) && !isempty(planned)
                    mode = "map"
                    route = planned
                elseif !model.mapped_runes || board.rate == 0
                    local_moves = Tuple{Int,MazeState}[]
                    for id in actions
                        next = maze_step(model,s,id;explore=true)
                        isnothing(next) || push!(local_moves,(id,next))
                    end
                    if !isempty(local_moves)
                        # Prefer a direct, reversible step whose view keeps the tracked rune visible.
                        id,next = first(sort!(local_moves;by=entry->begin
                            p = entry[2].point
                            (p in board.batteries, haskey(board.slides,maze_add(s.point,MAZE_MOVES[entry[1]])),
                                -maze_vantage(board,p), entry[1])
                        end))
                        route = [(id,next)]
                    end
                end
            end
        end
        if isempty(route)
            # A reset refills the same level. Previously confirmed map and phase samples remain available.
            evidence_size = (length(board.views),sum(length,values(board.runes);init=0))
            if obs.point == board.start && obs.charge == MAZE_CAPACITY || reset_at == evidence_size
                return "route_unresolved"
            end
            reset_at = evidence_size
            receipt = reset!(rec,rec.observation.game_id)
            receipt["completion"] == "confirmed" || return "unconfirmed_reset"
            rec.observation.levels_completed == level || return "reset_changed_level"
            frame = last(rec.observation.frames)
            obs = maze_observation(frame)
            tick = 0
            empty!(used)
            empty!(matched)
            maze_reveal!(board,frame,obs.point,tick,rec.before_ref)
            continue
        end
        id, expected = popfirst!(route)
        # Choosing another route after a refutation is allowed only from the newly confirmed scene.
        before = obs
        command = command_id(rec.next_sequence)
        result = submit_action!(rec,id;prediction=maze_prediction(rec,board,id,mode=="solve" ? expected : nothing))
        result["completion"] == "confirmed" || return "unconfirmed_action"
        public_obs = rec.observation
        if public_obs.levels_completed > level
            public_obs.levels_completed == level+1 || return "unexpected_level_progress"
            atomic_json(store_path(rec.store,"pattern-maze",command*".json"),
                (; level,mode,outcome="advanced",event=rec.before_ref,
                    completed=public_obs.levels_completed,state=public_obs.state))
            return "advanced"
        end
        public_obs.state == "GAME_OVER" && return "game_over"
        frame = last(public_obs.frames)
        obs = maze_observation(frame)
        tick += obs.point != before.point
        if obs.point != before.point && haskey(board.goals,obs.point) && maze_goal_open(frame,obs.point)
            push!(matched,obs.point)
        end
        if obs.point != before.point && obs.point in board.batteries && obs.charge == MAZE_CAPACITY
            push!(used,obs.point)
        elseif board.rate == 0 && obs.point != before.point && before.charge > obs.charge
            board.rate = before.charge-obs.charge
        end
        symbols = maze_reveal!(board,frame,obs.point,tick,rec.before_ref)
        agreement = if mode == "solve"
            obs.point == expected.point && obs.picture == expected.picture && obs.charge >= expected.charge &&
                all(get(model.runes[expected.phase+1],p,nothing) == rune for (rune,p) in symbols) &&
                maze_state(model,obs,used,matched,tick).matched == expected.matched
        else
            obs.point == expected.point && obs.charge >= expected.charge
        end
        atomic_json(store_path(rec.store,"pattern-maze",command*".json"),
            (; level,mode,event=rec.before_ref,tick,used=sort!(collect(used)),matched=sort!(collect(matched)),
                outcome=mode == "solve" ? (agreement ? "supported" : "refuted") : "observed",
                actual=obs,expected=mode == "solve" ? expected : nothing))
        if !agreement
            empty!(route)
        end
    end
    return rec.frozen ? "quarantined" : "command_budget"
end
