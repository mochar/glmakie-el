using Mmap

const WIDTH = 3
const HEIGHT = 2
const SHM_PATH = "/dev/shm/glmakie_emacs.bin"

io = open(SHM_PATH, "w+")
truncate(io, WIDTH * HEIGHT * 4) # 4 bytes per pixel (RGBA)

shared = mmap(io, Matrix{Float32}, (WIDTH, HEIGHT))


data = randn(WIDTH, HEIGHT)
copyto!(shared, data)
Mmap.sync!(shared)
