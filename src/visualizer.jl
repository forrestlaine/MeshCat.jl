using MsgPack
using Mux
using Logging
import Mux.WebSockets

struct CoreVisualizer
    tree::SceneNode
    command_channel::Channel{Vector{UInt8}}
    new_connections::Channel{Bool}
    queues::Dict{Any, Any}
    host::IPAddr
    port::Int

    function CoreVisualizer(host::IPAddr = ip"127.0.0.1", default_port=8700)
        cmd = Channel{Vector{UInt8}}(typemax(Int))
        new_connections = Channel{Bool}(typemax(Int))
        queues = Dict()
        tree = SceneNode()
        port = find_open_port(host, default_port, 500)
        core = new(tree, cmd, new_connections, queues,
                   host, port)
        @async while true
            if isempty(queues)
                wait(new_connections)
            end
            while isready(new_connections)
                take!(new_connections)
            end
            message = take!(cmd)
            for queue in values(queues)
                put!(queue, message)
            end
        end
        start_server(core)
        return core
    end
end

function find_open_port(host, default_port, max_retries)
    for port in default_port:(default_port + max_retries)
        server = try
            listen(host, port)
        catch e
            if e isa Base.IOError
                continue
            end
        end
        close(server)
        # It is *possible* that a race condition could occur here, in which
        # some other process grabs the given port in between the close() above
        # and the open() below. But it's unlikely and would not be terribly
        # damaging (the user would just have to call open() again).
        return port
    end
end

function start_server(core::CoreVisualizer)
    asset_files = Set(["index.html", "main.min.js", "main.js"])

    function read_asset(file)
        if file in asset_files
            return open(s -> read(s, String), joinpath(VIEWER_ROOT, file))
        else
            return "Not found"
        end
    end
    default = "index.html"
    @app h = (
        Mux.defaults,
        page("/index.html", req -> read_asset("index.html")),
        page("/main.js", req -> read_asset("main.js")),
        page("/main.min.js", req -> read_asset("main.min.js")),
        page("/", req -> read_asset(default)),
        Mux.notfound());
    @app w = (
        Mux.wdefaults,
        route("/", req -> add_connection!(core, req)),
        Mux.wclose,
        Mux.notfound());
    @async begin
        # Suppress noisy unhelpful log messages from HTTP.jl, e.g.
        # https://github.com/JuliaWeb/HTTP.jl/issues/392
        Logging.with_logger(Logging.NullLogger()) do
            WebSockets.serve(
            WebSockets.ServerWS(
                Mux.http_handler(h),
                Mux.ws_handler(w),
            ), core.port);
        end
    end
    @info "MeshCat server started. You can open the visualizer by visiting the following URL in your browser:\n$(url(core))"
end

function url(core::CoreVisualizer)
    "http://localhost:$(core.port[])"
end

function add_connection!(core::CoreVisualizer, req)
    connection = req[:socket]
    queue = Channel{Vector{UInt8}}(0)
    core.queues[connection] = queue
    put!(core.new_connections, true)
    send_scene(core)
    while true
        message = take!(queue)
        if isopen(connection)
            WebSockets.writeguarded(connection, message)
        else
            break
        end
    end
    delete!(core.queues, connection)
end

function update_tree!(core::CoreVisualizer, cmd::SetObject, data)
    core.tree[cmd.path].object = data
end

function update_tree!(core::CoreVisualizer, cmd::SetTransform, data)
    core.tree[cmd.path].transform = data
end

function update_tree!(core::CoreVisualizer, cmd::Delete, data)
    if length(cmd.path) == 0
        core.tree = SceneNode()
    else
        delete!(core.tree, cmd.path)
    end
end

update_tree!(core::CoreVisualizer, cmd::SetAnimation, data) = nothing
update_tree!(core::CoreVisualizer, cmd::SetProperty, data) = nothing

function send_scene(core::CoreVisualizer)
    foreach(core.tree) do node
        if node.object !== nothing
            put!(core.command_channel, node.object)
        end
        if node.transform !== nothing
            put!(core.command_channel, node.transform)
        end
    end
end

function send(c::CoreVisualizer, cmd::AbstractCommand)
    data = pack(lower(cmd))
    update_tree!(c, cmd, data)
    put!(c.command_channel, data)
    nothing
end

function Base.wait(c::CoreVisualizer)
    while isempty(c.queues)
        sleep(0.5)
    end
end

"""
    vis = Visualizer()

Construct a new MeshCat visualizer instance.

Useful methods:

    vis[:group1] # get a new visualizer representing a sub-tree of the scene
    setobject!(vis, geometry) # set the object shown by this visualizer's sub-tree of the scene
    settransform!(vis], tform) # set the transformation of this visualizer's sub-tree of the scene
"""
struct Visualizer <: AbstractVisualizer
    core::CoreVisualizer
    path::Path
end

Visualizer() = Visualizer(CoreVisualizer(), ["meshcat"])

"""
$(SIGNATURES)

Wait until at least one browser has connected to the
visualizer's server. This is useful in scripts to delay
execution until the browser window has opened.
"""
Base.wait(v::Visualizer) = wait(v.core)

# IJuliaCell(vis::Visualizer; kw...) = iframe(vis.core; kw...)

Base.show(io::IO, v::Visualizer) = print(io, "MeshCat Visualizer with path $(v.path) at $(url(v.core))")

"""
$(SIGNATURES)

Set the object at this visualizer's path. This replaces whatever
geometry was presently at that path. To draw multiple geometries,
place them at different paths by using the slicing notation:

    setobject!(vis[:group1][:box1], geometry1)
    setobject!(vis[:group1][:box2], geometry2)
"""
function setobject!(vis::Visualizer, obj::AbstractObject)
    send(vis.core, SetObject(obj, vis.path))
    vis
end

"""
$(SIGNATURES)

Set the transform of this visualizer's path. This can be done
before or after adding an object at that path. The overall transform
of an object is the composition of the transforms of all of its parents,
so setting the transform of `vis[:group1]` affects the poses of the objects
at `vis[:group1][:box1]` and `vis[:group1][:box2]`.
"""
function settransform!(vis::Visualizer, tform::Transformation)
    send(vis.core, SetTransform(tform, vis.path))
    vis
end

"""
$(SIGNATURES)

Delete the geometry at this visualizer's path and all of its descendants.
"""
function delete!(vis::Visualizer)
    send(vis.core, Delete(vis.path))
    vis
end

"""
$(SIGNATURES)

Set a single property for the object at the given path.

(this is named setprop! instead of setproperty! to avoid confusion
with the Base.setproperty! function introduced in Julia v0.7)
"""
function setprop!(vis::Visualizer, property::AbstractString, value)
    send(vis.core, SetProperty(vis.path, property, value))
    vis
end

function setanimation!(vis::Visualizer, anim::Animation; play::Bool=true, repetitions::Integer=1)
    cmd = SetAnimation(anim, play, repetitions)
    send(vis.core, cmd)
end

Base.getindex(vis::Visualizer, path...) =
    Visualizer(vis.core, joinpath(vis.path, path...))
