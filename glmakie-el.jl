using Mmap, GLMakie, Makie, Colors, Match, Logging
using FixedPointNumbers: N0f8


### Custom window

# https://docs.makie.org/stable/explanations/backends/glmakie

import ShaderAbstractions, GLFW, Makie

struct EmacsWindow
    id::String
    height::Int
    width::Int
    glfw_window::GLFW.Window
end

function EmacsWindow(id::String, height::Int, width::Int)
    glfw_window = GLFW.Window(
        resolution = (width, height),
        windowhints = [
            (GLFW.SAMPLES, 0),
            (GLFW.DEPTH_BITS, 0),

            # SETTING THE ALPHA BIT IS REALLY IMPORTANT ON OSX, SINCE IT WILL JUST KEEP SHOWING A BLACK SCREEN
            # WITHOUT ANY ERROR -.-
            (GLFW.ALPHA_BITS, 8),
            (GLFW.RED_BITS, 8),
            (GLFW.GREEN_BITS, 8),
            (GLFW.BLUE_BITS, 8),

            (GLFW.STENCIL_BITS, 0),
            (GLFW.AUX_BUFFERS, 0),

            (GLFW.SCALE_TO_MONITOR, true),  # Windows & X11
            (GLFW.SCALE_FRAMEBUFFER, true), # OSX & Wayland
        ],
        visible = false,
        focus = false,
        fullscreen = false,
    )
    EmacsWindow(id, height, width, glfw_window)
end

Base.isopen(::EmacsWindow) = true

# Switch to the OpenGL context of the window
ShaderAbstractions.native_switch_context!(w::EmacsWindow) = 
    ShaderAbstractions.native_switch_context!(w.glfw_window)

# Check if the window OpenGL context is still valid
ShaderAbstractions.native_context_alive(w::EmacsWindow) =
    ShaderAbstractions.native_context_alive(w.glfw_window)

# Get the size of the windows framebuffer
GLMakie.framebuffer_size(w::EmacsWindow) = (w.width, w.height)

# 'Destroy' the window, this should be a no-op unless you want GLMakie to really
# close the window
# GLMakie.destroy!(::EmacsWindow) = nothing
GLMakie.destroy!(w::EmacsWindow) = GLMakie.destroy!(w.glfw_window)

GLMakie.was_destroyed(w::EmacsWindow) = w.glfw_window.handle == C_NULL

GLMakie.window_size(w::EmacsWindow) = (w.width, w.height)

# Event handler disconnect called when screen closed
# Overwrite disconnect_screen, otherwise have to implement disconnect! for each event type.
Makie.disconnect_screen(scene::Scene, screen::GLMakie.Screen{EmacsWindow}) = nothing
# function GLMakie.disconnect!(screen::GLMakie.Screen{EmacsWindow}, f)
#     return
# end

function GLMakie.reopen!(screen::GLMakie.Screen{EmacsWindow})
    gl = screen.glscreen.glfw_window # screen.glscreen=EmacsWindow
    # @assert !was_destroyed(gl)
    # @assert GLAbstraction.context_alive(gl)
    if GLFW.WindowShouldClose(gl)
        GLFW.SetWindowShouldClose(gl, false)
    end
    # @assert isempty(screen.window_open.listeners)
    # screen.window_open[] = true
    # on(scalechangeobs(screen), screen.scalefactor)
    # @assert isopen(screen)
    return screen
end

function Base.resize!(screen::GLMakie.Screen{EmacsWindow}, w::Int, h::Int)
    window = screen.glscreen
    (w > 0 && h > 0 && isopen(window)) || return nothing
    ppu = screen.px_per_unit[]
    fbw, fbh = round.(Int, ppu .* (w, h))
    Base.resize!(screen.framebuffer, fbw, fbh)
    
    GLMakie.gl_switch_context!(window)
    winw, winh = GLMakie.window_size(screen, w, h)
    if GLMakie.window_size(window) != (winw, winh)
        GLFW.SetWindowSize(window.glfw_window, winw, winh)
    end
    screen.size = (winw, winh)
end


function GLMakie.scale_factor(w::EmacsWindow)
    GLMakie.was_destroyed(w.glfw_window) && return 1.0f0
    return minimum(GLFW.GetWindowContentScale(w.glfw_window))
end

GLMakie.set_screen_visibility!(screen::GLMakie.Screen{EmacsWindow}, visible::Bool) = nothing

GLFW.SwapBuffers(w::EmacsWindow) = GLFW.SwapBuffers(w.glfw_window)

# Connect input signals for e.g. the keyboard and mouse; you may want to
# implement the individual connection methods instead.
# See: [[file:~/.julia/packages/Makie/XzVRj/src/interaction/events.jl::function connect_screen(scene::Scene, screen)]]
function GLMakie.connect_screen(scene::Scene, screen::GLMakie.Screen{EmacsWindow})
    
end

### SHM Canvas

id_to_shm_path(id) = string("/dev/shm/", id, ".bin")

mutable struct EmacsCanvas
    id::String
    path::String
    screen::GLMakie.Screen{EmacsWindow}
    buffer::Matrix{RGBA{N0f8}}
end

function sync!(canvas::EmacsCanvas)
    colorbuf = colorbuffer(canvas.screen)
    copyto!(canvas.buffer, colorbuf')
    Mmap.sync!(canvas.buffer)
end

function init_canvas(id::String, height::Int, width::Int)::EmacsCanvas
    shm_path = id_to_shm_path(id)
    io = open(shm_path, "w+")
    truncate(io, width * height * 4) # 4 bytes per pixel (RGBA)
    shared_buf = mmap(io, Matrix{RGBA{N0f8}}, (height, width))
    
    window = EmacsWindow(id, height, width)
    screen = GLMakie.Screen(; window=window, start_renderloop=false)
    # Base.resize!(screen, width, height) # Force the screen out of 10x10 fallback
    
    f = Figure(size=(width, height))
    lines(f[1,1], sin.(1:100))
    GLMakie.render_frame(screen)
    display(screen, f)

    canvas = EmacsCanvas(id, shm_path, screen, shared_buf)
    sync!(canvas)
    canvas
end

function resize!(canvas::EmacsCanvas, h::Int, w::Int)
    # GC old buffer (I think this calls munmap?)
    finalize(canvas.buffer)
                        
    # Resize the shared memory file on disk
    io = open(canvas.path, "w+")
    truncate(io, w * h * 4)
    
    # Remap the Julia buffer to the new size
    canvas.buffer = mmap(io, Matrix{RGBA{N0f8}}, (h, w))
    close(io)
    
    # Render and sync the new frame
    Base.resize!(canvas.screen.scene, w, h)
    GLMakie.render_frame(canvas.screen)
    sync!(canvas)
end

function close!(canvas::EmacsCanvas)
    GLMakie.destroy!(canvas.screen)
    finalize(canvas.buffer)
    rm(canvas.path, force=true)
end


### Server

using Sockets, Base.Threads

port = 8888
server::Sockets.TCPServer = listen(port)
server_task::Union{Nothing, Task} = nothing
server_stop_flag = Threads.Atomic{Bool}(false)
conns = TCPSocket[]
canvases = Dict{Tuple{TCPSocket, String}, EmacsCanvas}()

function start_server()
    global server, server_stop_flag, server_task
    
    server_stop_flag[] = false
    if !isopen(server)
        server = listen(port)
    end
    server_task = @async begin
        while !server_stop_flag[]
            conn = accept(server)
            @info "New connection: $conn"
            push!(conns, conn)
        
            @async begin
                try
                    while isopen(conn)
                        line = readline(conn)

                        if isempty(line)
                            @info "Connection killed"
                            break
                        end

                        @info "Message: $line"

                        try
                            Base.invokelatest(process_message, conn, line)
                        catch e
                            # TODO Close buffer?
                            @error e
                        end
                    end
                catch e
                    @error e
                finally
                    close(conn)
                    for (c, id) in keys(canvases)
                        if c == conn
                            close!(pop!(canvases, (c, id)))
                        end
                    end
                    deleteat!(conns, findall(x->x==conn, conns))
                end
            end
        end
    end
end

function stop_server()
    server_stop_flag[] = true
    
    # Interrupt the blocking accept() call
    if isopen(server)
        close(server)
    end
    
    # Clean up any active client connections
    for conn in conns
        if isopen(conn)
            close(conn)
        end
    end
    empty!(conns)
    
    @info "Server stopped and connections cleared"
end

function process_message(conn::TCPSocket, message::AbstractString)
    parts = split(message)
    @match parts begin
        ["INIT", id, h, w] => process_init(conn, id, h, w)
        ["RESIZE", id, h, w] => process_resize(conn, id, h, w)
        ["MOUSE", btn, action, id, x, y] => process_mouse(conn, btn, action, id, x, y)
        ["KEY", btn, action, id] => process_key(conn, btn, action, id)
        ["CLOSE", id] => close!(pop!(canvases, (conn, String(id))))
    end
end

function process_init(conn, id, h, w)
    id = String(id)
    h, w = parse.(Int, [h, w])
    
    canvas = init_canvas(id, h, w)
    if haskey(canvases, (conn, id))
        close!(pop!(canvases, (conn, id)))
    end
    canvases[(conn, id)] = canvas
    println(conn, "INIT $id $h $w")
end

function process_resize(conn, id, h, w)
    id = String(id)
    h, w = parse.(Int, [h, w])
    
    canvas = canvases[(conn, id)]
    resize!(canvas, h, w)
    println(conn, "RESIZE $id $h $w") 
end

function process_mouse(conn, btn, action, id, x, y)
    id = String(id)
    canvas = canvases[(conn, id)]
    window = canvas.screen.glscreen
    
    x, y = parse.(Float32, [x, y])
    y = window.height - y

    events = canvas.screen.scene.events
    events.mouseposition[] = (x, y)
                        
    if action != "DRAG"
        btn = btn == "LEFT" ? Makie.Mouse.left : Makie.Mouse.right
        action = action == "PRESS" ? Makie.Mouse.press : Makie.Mouse.release
        events.mousebutton[] = Makie.MouseButtonEvent(btn, action)
    end

    GLMakie.render_frame(canvas.screen)
    sync!(canvas)
    println(conn, "REFRESH $id") 
end

function process_key(conn, btn, action, id)
    id = String(id)
    canvas = canvases[(conn, id)]
    window = canvas.screen.glscreen
    
    btn = @eval Makie.Keyboard.$(Symbol(lowercase(btn)))
    action = @match action begin
        "PRESS" => Makie.Keyboard.press
        "RELEASE" => Makie.Keyboard.release
        "REPEAT" => Makie.Keyboard.repeat
    end
                        
    events = canvas.screen.scene.events
    events.keyboardbutton[] = Makie.KeyEvent(btn, action)

    GLMakie.render_frame(canvas.screen)
    sync!(canvas)
    println(conn, "REFRESH $id") 
end

errormonitor(start_server())
