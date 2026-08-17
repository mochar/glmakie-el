using Mmap, GLMakie, Makie, Colors
using FixedPointNumbers: N0f8

const SHM_PATH = "/dev/shm/glmakie_emacs.bin"

# f = Figure()
# lines(f[1,1], sin.(1:100))
# display(f)
# screen = f.scene.current_screens[1]
# framebuf = screen.framebuffer.buffers[:color]
# WIDTH, HEIGHT = size(framebuf)

# io = open(SHM_PATH, "w+")
# truncate(io, WIDTH * HEIGHT * 4) # 4 bytes per pixel (RGBA)

# shared = mmap(io, Matrix{RGBA{N0f8}}, (HEIGHT, WIDTH))


# cpubuf = colorbuffer(screen)
# copyto!(shared, cpubuf')
# Mmap.sync!(shared)


### Server

module Server

using Sockets, Base.Threads

global server = listen(8888)
global conns = []

server_task = @spawn begin
    while true
        conn = accept(server)
        push!(conns, conn)
        @spawn begin
            try
                while isopen(conn)
                    line = readline(conn)

                    if isempty(line)
                        println("Connection killed")
                        deleteat!(conns, findall(x->x==conn, conns))
                        break
                    end

                    println("Got $line")
                    println(conn, "Nice")
                    
                    # parts = split(line)
                    # if parts[1] == "RESIZE"
                    #     w = parse(Int, parts[2])
                    #     h = parse(Int, parts[3])
                    #     resize_and_render(w, h)
                    #     # Acknowledge completion back to Emacs
                    #     println(conn, "DONE") 
                    # end
                end
            catch e
                println("Connection error: ", e)
            end
        end
    end
end

errormonitor(server_task)

end
