using Mmap, GLMakie, Makie, Colors
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

server = listen(8888)
conns = TCPSocket[]
canvases = Dict{Tuple{TCPSocket, String}, EmacsCanvas}()

server_task = @async begin
    while true
        conn = accept(server)
        push!(conns, conn)
        
        @async begin
            try
                while isopen(conn)
                    line = readline(conn)

                    if isempty(line)
                        println("Connection killed")
                        break
                    end

                    println("Got $line")
                    
                    parts = split(line)
                    if parts[1] == "INIT"
                        id = String(parts[2])
                        h = parse(Int, parts[3])
                        w = parse(Int, parts[4])
                        
                        canvas = init_canvas(id, h, w)

                        if haskey(canvases, (conn, id))
                            close!(pop!(canvases, (conn, id)))
                        end
                        canvases[(conn, id)] = canvas
                        
                        println(conn, "INIT $id $h $w")
                    elseif parts[1] == "RESIZE"
                        id = String(parts[2])
                        h = parse(Int, parts[3])
                        w = parse(Int, parts[4])
                        
                        canvas = canvases[(conn, id)]
                        resize!(canvas, h, w)
                        
                        println(conn, "RESIZE $id $h $w") 
                    elseif parts[1] == "CLOSE"
                        id = String(parts[2])
                        close!(pop!(canvases, (c, id)))
                    end
                end
            catch e
                println("Connection error: ", e)
            finally
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

errormonitor(server_task)
