// Map scroller: loads a Tiled map and scrolls it with the arrow keys.
//
// The world is drawn into a 320x180 render texture (the back buffer). That
// texture is then scaled onto the window by the largest whole-number factor
// that fits, centered, with black bars filling the rest (letterboxing).
package main

import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

WORLD_WIDTH  :: 320
WORLD_HEIGHT :: 180
SCROLL_SPEED :: 100 // map pixels per second
MAP_PATH     :: "../assets/island.tmx"

AREA_COLOR  :: rl.Color{255, 220, 0, 255}
POINT_COLOR :: rl.Color{255, 40, 40, 255}

main :: proc() {
	// All map data lives in this arena and is freed in one go at the end.
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	tiled_map, ok := load_map(MAP_PATH, virtual.arena_allocator(&arena))
	if !ok do os.exit(1)

	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
	rl.InitWindow(WORLD_WIDTH, WORLD_HEIGHT, "Map scroll - Odin + raylib")
	defer rl.CloseWindow()

	image_path := strings.clone_to_cstring(tiled_map.tileset.image_path, context.temp_allocator)
	tileset_texture := rl.LoadTexture(image_path)
	defer rl.UnloadTexture(tileset_texture)

	buffer := rl.LoadRenderTexture(WORLD_WIDTH, WORLD_HEIGHT)
	defer rl.UnloadRenderTexture(buffer)
	rl.SetTextureFilter(buffer.texture, .POINT)

	map_width := f32(tiled_map.width * tiled_map.tile_width)
	map_height := f32(tiled_map.height * tiled_map.tile_height)

	// Top-left corner of the view, in map pixels. Start centered on the "start" object.
	camera_pos: rl.Vector2
	for obj in tiled_map.objects {
		if obj.type == "start" do camera_pos = {obj.x - WORLD_WIDTH / 2, obj.y - WORLD_HEIGHT / 2}
	}

	for !rl.WindowShouldClose() {
		// --- Update ---
		dt := rl.GetFrameTime()
		if rl.IsKeyDown(.LEFT) do camera_pos.x -= SCROLL_SPEED * dt
		if rl.IsKeyDown(.RIGHT) do camera_pos.x += SCROLL_SPEED * dt
		if rl.IsKeyDown(.UP) do camera_pos.y -= SCROLL_SPEED * dt
		if rl.IsKeyDown(.DOWN) do camera_pos.y += SCROLL_SPEED * dt
		camera_pos.x = clamp(camera_pos.x, 0, map_width - WORLD_WIDTH)
		camera_pos.y = clamp(camera_pos.y, 0, map_height - WORLD_HEIGHT)

		// --- Draw the world into the 320x180 back buffer ---
		rl.BeginTextureMode(buffer)
		rl.ClearBackground(rl.BLACK)
		draw_world(&tiled_map, tileset_texture, camera_pos, int(rl.GetTime() * 1000))
		rl.EndTextureMode()

		// --- Scale the back buffer by a whole number and center it in the window ---
		screen_w, screen_h := int(rl.GetScreenWidth()), int(rl.GetScreenHeight())
		scale := max(1, min(screen_w / WORLD_WIDTH, screen_h / WORLD_HEIGHT))
		dest := rl.Rectangle {
			x      = f32((screen_w - WORLD_WIDTH * scale) / 2),
			y      = f32((screen_h - WORLD_HEIGHT * scale) / 2),
			width  = f32(WORLD_WIDTH * scale),
			height = f32(WORLD_HEIGHT * scale),
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		// Render textures are stored upside down, hence the negative source height.
		source := rl.Rectangle{0, 0, WORLD_WIDTH, -WORLD_HEIGHT}
		rl.DrawTexturePro(buffer.texture, source, dest, {0, 0}, 0, rl.WHITE)
		rl.EndDrawing()
	}
}

draw_world :: proc(m: ^Tiled_Map, tileset_texture: rl.Texture2D, camera_pos: rl.Vector2, elapsed_ms: int) {
	// Round the camera to whole pixels so tiles never land between pixels.
	camera := rl.Camera2D {
		target = {math.floor(camera_pos.x), math.floor(camera_pos.y)},
		zoom   = 1,
	}
	rl.BeginMode2D(camera)
	defer rl.EndMode2D()

	// Only visit the tiles that overlap the view.
	first_col := int(camera.target.x) / m.tile_width
	first_row := int(camera.target.y) / m.tile_height
	last_col := min(first_col + WORLD_WIDTH / m.tile_width + 1, m.width - 1)
	last_row := min(first_row + WORLD_HEIGHT / m.tile_height + 1, m.height - 1)

	for layer in m.layers { // drawn in file order: Ground, Fringe, Over
		if !layer.visible do continue
		for row in first_row ..= last_row {
			for col in first_col ..= last_col {
				gid := layer.gids[row * m.width + col]
				if gid == 0 do continue
				position := rl.Vector2{f32(col * m.tile_width), f32(row * m.tile_height)}
				draw_tile(m, tileset_texture, gid, position, elapsed_ms)
			}
		}
	}

	for obj in m.objects {
		x, y := math.floor(obj.x), math.floor(obj.y)
		if obj.is_point {
			rl.DrawRectangleRec({x - 2, y - 2, 4, 4}, POINT_COLOR)
		} else {
			rl.DrawRectangleLinesEx({x, y, obj.width, obj.height}, 1, AREA_COLOR)
		}
	}
}

draw_tile :: proc(m: ^Tiled_Map, tileset_texture: rl.Texture2D, gid: u32, position: rl.Vector2, elapsed_ms: int) {
	tileset := &m.tileset
	tile_id := (gid & GID_MASK) - tileset.first_gid
	if frames, is_animated := tileset.animations[tile_id]; is_animated {
		tile_id = current_frame(frames, elapsed_ms)
	}

	tile_w, tile_h := f32(m.tile_width), f32(m.tile_height)
	source := rl.Rectangle {
		x      = f32(int(tile_id) % tileset.columns) * tile_w,
		y      = f32(int(tile_id) / tileset.columns) * tile_h,
		width  = tile_w,
		height = tile_h,
	}

	// raylib mirrors via a negative source size, then rotates around `origin`.
	// Tiled's diagonal flip (swap x and y) is the same as mirroring vertically
	// and turning 90 degrees clockwise, which also swaps the roles of the
	// horizontal and vertical flip flags.
	flip_x := gid & FLIP_HORIZONTAL != 0
	flip_y := gid & FLIP_VERTICAL != 0
	rotation: f32 = 0
	if gid & FLIP_DIAGONAL != 0 {
		rotation = 90
		flip_x, flip_y = flip_y, !flip_x
	}
	if flip_x do source.width = -source.width
	if flip_y do source.height = -source.height

	half := rl.Vector2{tile_w / 2, tile_h / 2}
	dest := rl.Rectangle{position.x + half.x, position.y + half.y, tile_w, tile_h}
	rl.DrawTexturePro(tileset_texture, source, dest, half, rotation, rl.WHITE)
}
