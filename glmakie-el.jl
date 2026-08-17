using Mmap, GLMakie, Makie, Colors
using FixedPointNumbers: N0f8

const SHM_PATH = "/dev/shm/glmakie_emacs.bin"

f = Figure()
lines(f[1,1], sin.(1:100))
screen = f.scene.current_screens[1]
framebuf = screen.framebuffer.buffers[:color]
WIDTH, HEIGHT = size(framebuf)

io = open(SHM_PATH, "w+")
truncate(io, WIDTH * HEIGHT * 4) # 4 bytes per pixel (RGBA)

shared = mmap(io, Matrix{RGBA{N0f8}}, (HEIGHT, WIDTH))


cpu_buffer = colorbuffer(screen)
copyto!(shared, cpu_buffer')
Mmap.sync!(shared)
