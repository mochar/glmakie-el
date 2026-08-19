
canvas = collect(values(canvases))[1]
scene = canvas.screen.scene
events = scene.events

on(events(scene).mousebutton) do event
    mp = events(scene).mouseposition[]
    println("MOUSE")
end

scene.events.mouseposition[] = (10., 12.0)
scene.events.mousebutton[] = Makie.MouseButtonEvent(Makie.Mouse.left, Makie.Mouse.press)



scene.events.mousebutton[] = Makie.MouseButtonEvent(Makie.Mouse.left, Makie.Mouse.press)
scene.events.mouseposition[] = (100., 12.0)
scene.events.mousebutton[] = Makie.MouseButtonEvent(Makie.Mouse.left, Makie.Mouse.release)


# 3. Press the left mouse button down
events.mousebutton[] = Makie.MouseButtonEvent(Makie.Mouse.left, Makie.Mouse.press)

# 4. Move the mouse to a new position while the button is down (this triggers the pan!)
# Let's drag it 50 pixels to the right and 20 pixels up
events.mouseposition[] = (200.0, 120.0)

# 5. Release the left mouse button
events.mousebutton[] = Makie.MouseButtonEvent(Makie.Mouse.left, Makie.Mouse.release)





GLMakie.render_frame(canvas.screen)
sync!(canvas)
