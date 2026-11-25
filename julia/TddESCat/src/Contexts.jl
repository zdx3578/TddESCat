const Pixel = NTuple{2,Int}
const ColorCell = Tuple{Int,Int,UInt8}

struct Window
    x::Int
    y::Int
    width::Int
    height::Int
    function Window(x, y, width, height)
        all(strict_integer, (x, y, width, height)) &&
            0 <= x <= 63 && 0 <= y <= 63 && 1 <= width <= 64 && 1 <= height <= 64 ||
            throw(ArgumentError("Invalid window"))
        new(x, y, width, height)
    end
end

struct PixelSource
    event_id::String
    response_frame_index::Int
    x::Int
    y::Int
    interpretation_version::String
end

whole_window(frame) = Window(0, 0, size(frame, 2), size(frame, 1))
in_window(b::Window,x,y) = b.x <= x < b.x+b.width && b.y <= y < b.y+b.height

function crop_frame(frame, window::Window)
    window.x + window.width <= size(frame, 2) &&
        window.y + window.height <= size(frame, 1) || throw(ArgumentError("Window outside frame"))
    return copy(@view frame[window.y .+ (1:window.height), window.x .+ (1:window.width)])
end

function embed_point(window::Window, point::Pixel)
    x, y = point
    0 <= x < window.width && 0 <= y < window.height || throw(ArgumentError("Point outside window"))
    return (window.x + x, window.y + y)
end
