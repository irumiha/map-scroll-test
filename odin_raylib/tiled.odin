// A minimal loader for Tiled maps (.tmx) with one external tileset (.tsx).
//
// Supports what the example map uses: orthogonal tile layers stored as
// base64 + zlib, tile flip flags, animated tiles, and rectangle/point objects.
package main

import "core:bytes"
import "core:compress/zlib"
import "core:encoding/base64"
import "core:encoding/endian"
import "core:encoding/xml"
import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// The top three bits of a tile GID are flip flags; the rest is the tile number.
FLIP_HORIZONTAL :: 0x80000000
FLIP_VERTICAL   :: 0x40000000
FLIP_DIAGONAL   :: 0x20000000
GID_MASK        :: 0x1FFFFFFF

Tiled_Map :: struct {
	width, height:           int, // in tiles
	tile_width, tile_height: int, // in pixels
	layers:                  [dynamic]Tile_Layer,
	objects:                 [dynamic]Map_Object,
	tileset:                 Tileset,
}

Tile_Layer :: struct {
	name:    string,
	visible: bool,
	gids:    []u32, // width * height entries, row by row; 0 means empty
}

Map_Object :: struct {
	name, type:          string,
	x, y, width, height: f32,
	is_point:            bool,
}

Tileset :: struct {
	first_gid:  u32,
	columns:    int,
	image_path: string,
	animations: map[u32][]Animation_Frame, // animated tile ID -> its frames
}

Animation_Frame :: struct {
	tile_id:     u32,
	duration_ms: int,
}

// Loads a map. Everything, including the parsed XML that the strings point into,
// is allocated with `allocator`, so an arena can free it all at once.
load_map :: proc(path: string, allocator := context.allocator) -> (m: Tiled_Map, ok: bool) {
	context.allocator = allocator
	doc, err := xml.load_from_file(path)
	if err != nil {
		fmt.eprintln("could not read map", path, err)
		return
	}
	root := xml.Element_ID(0)

	m.width = attr_int(doc, root, "width")
	m.height = attr_int(doc, root, "height")
	m.tile_width = attr_int(doc, root, "tilewidth")
	m.tile_height = attr_int(doc, root, "tileheight")

	for value in doc.elements[root].value {
		id := value.(xml.Element_ID) or_continue
		switch doc.elements[id].ident {
		case "tileset":
			tsx_path := path_next_to(path, attr(doc, id, "source"))
			m.tileset = load_tileset(tsx_path) or_return
			m.tileset.first_gid = u32(attr_int(doc, id, "firstgid"))

		case "layer":
			data, found := xml.find_child_by_ident(doc, id, "data")
			if !found || attr(doc, data, "encoding") != "base64" || attr(doc, data, "compression") != "zlib" {
				fmt.eprintln("only base64 + zlib layer data is supported")
				return
			}
			text := doc.elements[data].value[0].(string)
			gids := decode_layer_data(text, m.width * m.height) or_return
			append(&m.layers, Tile_Layer{
				name    = attr(doc, id, "name"),
				visible = attr(doc, id, "visible") != "0", // absent means visible
				gids    = gids,
			})

		case "objectgroup":
			for child in doc.elements[id].value {
				obj := child.(xml.Element_ID) or_continue
				_, is_point := xml.find_child_by_ident(doc, obj, "point")
				append(&m.objects, Map_Object{
					name     = attr(doc, obj, "name"),
					type     = attr(doc, obj, "type"),
					x        = attr_f32(doc, obj, "x"),
					y        = attr_f32(doc, obj, "y"),
					width    = attr_f32(doc, obj, "width"),
					height   = attr_f32(doc, obj, "height"),
					is_point = is_point,
				})
			}
		}
	}
	return m, true
}

@(private = "file")
load_tileset :: proc(path: string) -> (ts: Tileset, ok: bool) {
	doc, err := xml.load_from_file(path)
	if err != nil {
		fmt.eprintln("could not read tileset", path, err)
		return
	}
	root := xml.Element_ID(0)
	ts.columns = attr_int(doc, root, "columns")

	for value in doc.elements[root].value {
		id := value.(xml.Element_ID) or_continue
		switch doc.elements[id].ident {
		case "image":
			ts.image_path = path_next_to(path, attr(doc, id, "source"))

		case "tile":
			animation := xml.find_child_by_ident(doc, id, "animation") or_continue
			frames: [dynamic]Animation_Frame
			for child in doc.elements[animation].value {
				frame := child.(xml.Element_ID) or_continue
				append(&frames, Animation_Frame{
					tile_id     = u32(attr_int(doc, frame, "tileid")),
					duration_ms = attr_int(doc, frame, "duration"),
				})
			}
			ts.animations[u32(attr_int(doc, id, "id"))] = frames[:]
		}
	}
	return ts, true
}

// Layer data is base64 text of zlib-compressed little-endian u32 GIDs.
@(private = "file")
decode_layer_data :: proc(text: string, tile_count: int) -> (gids: []u32, ok: bool) {
	compressed, b64_err := base64.decode(strings.trim_space(text))
	if b64_err != nil {
		fmt.eprintln("bad base64 in layer data:", b64_err)
		return
	}
	buf: bytes.Buffer
	if zlib_err := zlib.inflate(compressed, &buf); zlib_err != nil {
		fmt.eprintln("bad zlib in layer data:", zlib_err)
		return
	}
	raw := bytes.buffer_to_bytes(&buf)
	if len(raw) != tile_count * 4 {
		fmt.eprintln("layer data has the wrong size")
		return
	}
	gids = make([]u32, tile_count)
	for &gid, i in gids {
		gid = endian.unchecked_get_u32le(raw[i * 4:])
	}
	return gids, true
}

// Returns the tile ID an animation shows at the given time.
current_frame :: proc(frames: []Animation_Frame, elapsed_ms: int) -> u32 {
	total := 0
	for f in frames do total += f.duration_ms
	t := elapsed_ms % total
	for f in frames {
		if t < f.duration_ms do return f.tile_id
		t -= f.duration_ms
	}
	return frames[0].tile_id
}

// Resolves `name` relative to the directory that contains `file`.
@(private = "file")
path_next_to :: proc(file, name: string) -> string {
	joined, _ := filepath.join({filepath.dir(file), name})
	return joined
}

@(private = "file")
attr :: proc(doc: ^xml.Document, id: xml.Element_ID, key: string) -> string {
	value, _ := xml.find_attribute_val_by_key(doc, id, key)
	return value
}

@(private = "file")
attr_int :: proc(doc: ^xml.Document, id: xml.Element_ID, key: string) -> int {
	n, _ := strconv.parse_int(attr(doc, id, key))
	return n
}

@(private = "file")
attr_f32 :: proc(doc: ^xml.Document, id: xml.Element_ID, key: string) -> f32 {
	n, _ := strconv.parse_f32(attr(doc, id, key))
	return n
}
