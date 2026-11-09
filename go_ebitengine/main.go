// Map scroller: loads a Tiled map and scrolls it with the arrow keys.
//
// The world is drawn into a 320x180 back buffer. That buffer is then scaled
// onto the window by the largest whole-number factor that fits, centered,
// with black bars filling the rest (letterboxing).
package main

import (
	"fmt"
	"image/color"
	"log"
	"math"

	"github.com/hajimehoshi/ebiten/v2"
	"github.com/hajimehoshi/ebiten/v2/ebitenutil"
	"github.com/hajimehoshi/ebiten/v2/vector"
	"github.com/lafriks/go-tiled"
)

const (
	worldWidth  = 320
	worldHeight = 180
	scrollSpeed = 180.0 // map pixels per second
	mapPath     = "../assets/island.tmx"
)

var (
	areaColor  = color.RGBA{255, 220, 0, 255}
	pointColor = color.RGBA{255, 40, 40, 255}
)

type Game struct {
	tiledMap   *tiled.Map
	tileImages []*ebiten.Image                    // one sub-image per tile ID in the tileset
	animations map[uint32][]*tiled.AnimationFrame // animated tile ID -> its frames
	buffer     *ebiten.Image                      // the 320x180 back buffer

	camX, camY float64 // top-left corner of the view, in map pixels
	elapsed    float64 // seconds since start, drives the tile animations
}

func newGame() (*Game, error) {
	m, err := tiled.LoadFile(mapPath)
	if err != nil {
		return nil, err
	}
	if len(m.Tilesets) != 1 {
		return nil, fmt.Errorf("expected exactly one tileset, got %d", len(m.Tilesets))
	}
	tileset := m.Tilesets[0]

	sheet, _, err := ebitenutil.NewImageFromFile(tileset.GetFileFullPath(tileset.Image.Source))
	if err != nil {
		return nil, err
	}

	g := &Game{
		tiledMap:   m,
		animations: map[uint32][]*tiled.AnimationFrame{},
		buffer:     ebiten.NewImage(worldWidth, worldHeight),
	}
	for id := 0; id < tileset.TileCount; id++ {
		rect := tileset.GetTileRect(uint32(id))
		g.tileImages = append(g.tileImages, sheet.SubImage(rect).(*ebiten.Image))
	}
	for _, tile := range tileset.Tiles {
		if len(tile.Animation) > 0 {
			g.animations[tile.ID] = tile.Animation
		}
	}

	// Start with the view centered on the "start" object.
	for _, group := range m.ObjectGroups {
		for _, obj := range group.Objects {
			if obj.Type == "start" {
				g.camX = obj.X - worldWidth/2
				g.camY = obj.Y - worldHeight/2
			}
		}
	}
	g.clampCamera()
	return g, nil
}

func (g *Game) Update() error {
	dt := 1.0 / float64(ebiten.TPS())
	g.elapsed += dt

	if ebiten.IsKeyPressed(ebiten.KeyArrowLeft) {
		g.camX -= scrollSpeed * dt
	}
	if ebiten.IsKeyPressed(ebiten.KeyArrowRight) {
		g.camX += scrollSpeed * dt
	}
	if ebiten.IsKeyPressed(ebiten.KeyArrowUp) {
		g.camY -= scrollSpeed * dt
	}
	if ebiten.IsKeyPressed(ebiten.KeyArrowDown) {
		g.camY += scrollSpeed * dt
	}
	g.clampCamera()
	return nil
}

func (g *Game) clampCamera() {
	mapW := float64(g.tiledMap.Width * g.tiledMap.TileWidth)
	mapH := float64(g.tiledMap.Height * g.tiledMap.TileHeight)
	g.camX = max(0, min(g.camX, mapW-worldWidth))
	g.camY = max(0, min(g.camY, mapH-worldHeight))
}

func (g *Game) Draw(screen *ebiten.Image) {
	g.drawWorld()

	// Scale the back buffer by a whole number and center it in the window.
	screenW, screenH := screen.Bounds().Dx(), screen.Bounds().Dy()
	scale := max(1, min(screenW/worldWidth, screenH/worldHeight))
	offsetX := (screenW - worldWidth*scale) / 2
	offsetY := (screenH - worldHeight*scale) / 2

	screen.Fill(color.Black)
	op := &ebiten.DrawImageOptions{} // default filter is nearest-neighbour
	op.GeoM.Scale(float64(scale), float64(scale))
	op.GeoM.Translate(float64(offsetX), float64(offsetY))
	screen.DrawImage(g.buffer, op)
}

// drawWorld renders the visible part of the map into the 320x180 back buffer.
func (g *Game) drawWorld() {
	g.buffer.Clear()
	m := g.tiledMap

	// Round the camera to whole pixels so tiles never land between pixels.
	camX, camY := math.Floor(g.camX), math.Floor(g.camY)

	// Only visit the tiles that overlap the view.
	firstCol, firstRow := int(camX)/m.TileWidth, int(camY)/m.TileHeight
	lastCol := min(firstCol+worldWidth/m.TileWidth+1, m.Width-1)
	lastRow := min(firstRow+worldHeight/m.TileHeight+1, m.Height-1)

	for _, layer := range m.Layers { // drawn in file order: Ground, Fringe, Over
		if !layer.Visible {
			continue
		}
		for row := firstRow; row <= lastRow; row++ {
			for col := firstCol; col <= lastCol; col++ {
				tile := layer.Tiles[row*m.Width+col]
				if tile.Nil {
					continue
				}
				x := float64(col*m.TileWidth) - camX
				y := float64(row*m.TileHeight) - camY
				g.drawTile(tile, x, y)
			}
		}
	}

	for _, group := range m.ObjectGroups {
		for _, obj := range group.Objects {
			x := float32(math.Floor(obj.X - camX))
			y := float32(math.Floor(obj.Y - camY))
			if obj.Width == 0 && obj.Height == 0 {
				// A point object: mark it with a small square.
				vector.FillRect(g.buffer, x-2, y-2, 4, 4, pointColor, false)
			} else {
				drawOutline(g.buffer, x, y, float32(obj.Width), float32(obj.Height), areaColor)
			}
		}
	}
}

func (g *Game) drawTile(tile *tiled.LayerTile, x, y float64) {
	id := tile.ID
	if frames, ok := g.animations[id]; ok {
		id = currentFrame(frames, int(g.elapsed*1000))
	}
	img := g.tileImages[id]

	// Flips are applied around the tile center, in the order Tiled defines:
	// diagonal (swap x and y), then horizontal, then vertical.
	half := float64(g.tiledMap.TileWidth) / 2
	op := &ebiten.DrawImageOptions{}
	op.GeoM.Translate(-half, -half)
	if tile.DiagonalFlip {
		var swapXY ebiten.GeoM
		swapXY.SetElement(0, 0, 0)
		swapXY.SetElement(0, 1, 1)
		swapXY.SetElement(1, 0, 1)
		swapXY.SetElement(1, 1, 0)
		op.GeoM.Concat(swapXY)
	}
	if tile.HorizontalFlip {
		op.GeoM.Scale(-1, 1)
	}
	if tile.VerticalFlip {
		op.GeoM.Scale(1, -1)
	}
	op.GeoM.Translate(x+half, y+half)
	g.buffer.DrawImage(img, op)
}

// currentFrame returns the tile ID an animation shows at the given time.
func currentFrame(frames []*tiled.AnimationFrame, elapsedMs int) uint32 {
	total := 0
	for _, f := range frames {
		total += int(f.Duration)
	}
	t := elapsedMs % total
	for _, f := range frames {
		if t < int(f.Duration) {
			return f.TileID
		}
		t -= int(f.Duration)
	}
	return frames[0].TileID
}

// drawOutline draws a 1-pixel border just inside the given rectangle.
func drawOutline(dst *ebiten.Image, x, y, w, h float32, clr color.Color) {
	vector.FillRect(dst, x, y, w, 1, clr, false)     // top
	vector.FillRect(dst, x, y+h-1, w, 1, clr, false) // bottom
	vector.FillRect(dst, x, y, 1, h, clr, false)     // left
	vector.FillRect(dst, x+w-1, y, 1, h, clr, false) // right
}

// Layout makes the screen image match the window's real pixel size,
// so the integer scaling in Draw maps directly onto physical pixels.
func (g *Game) Layout(outsideWidth, outsideHeight int) (int, int) {
	s := ebiten.Monitor().DeviceScaleFactor()
	return int(float64(outsideWidth) * s), int(float64(outsideHeight) * s)
}

func main() {
	game, err := newGame()
	if err != nil {
		log.Fatal(err)
	}
	ebiten.SetWindowTitle("Map scroll - Go + Ebitengine")
	ebiten.SetWindowSize(worldWidth, worldHeight)
	ebiten.SetWindowResizingMode(ebiten.WindowResizingModeEnabled)
	if err := ebiten.RunGame(game); err != nil {
		log.Fatal(err)
	}
}
