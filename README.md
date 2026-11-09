# map-scroll-bench

The same small program written three times: load the Tiled map in `assets/`
and scroll it with the arrow keys.

| Directory        | Language | Library            | Map loading                         |
|------------------|----------|--------------------|-------------------------------------|
| `go_ebitengine/` | Go       | Ebitengine 2.10    | `lafriks/go-tiled`                  |
| `odin_raylib/`   | Odin     | raylib 6 (vendor)  | hand-written, `tiled.odin`          |
| `java_libgdx/`   | Java     | libGDX 1.14        | built-in `TmxMapLoader` + renderer  |

All three follow the same rules:

- The world is drawn into a **320x180 back buffer**. Only that buffer is
  scaled to the window.
- The scale is the **largest whole number** that fits the window (at least 1).
  The image is centered and the rest of the window is black (letterboxing).
- The window starts at 320x180 and can be resized to any size.
- All map features are drawn: the three tile layers in order, animated tiles,
  flipped or rotated tiles, and objects. Rectangles are drawn as yellow
  outlines and points as small red squares.
- The view starts centered on the `start` object, scrolls at 120 px/s, and
  stays inside the map.

## Running

Each program loads `../assets/island.tmx`, so run it from its own directory.

```sh
cd go_ebitengine && go run .
cd odin_raylib   && odin run .
cd java_libgdx   && ./gradlew run
```
