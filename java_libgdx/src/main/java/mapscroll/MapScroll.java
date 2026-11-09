package mapscroll;

import com.badlogic.gdx.ApplicationAdapter;
import com.badlogic.gdx.Gdx;
import com.badlogic.gdx.Input;
import com.badlogic.gdx.backends.lwjgl3.Lwjgl3Application;
import com.badlogic.gdx.backends.lwjgl3.Lwjgl3ApplicationConfiguration;
import com.badlogic.gdx.graphics.Color;
import com.badlogic.gdx.graphics.OrthographicCamera;
import com.badlogic.gdx.graphics.Pixmap;
import com.badlogic.gdx.graphics.Texture;
import com.badlogic.gdx.graphics.g2d.SpriteBatch;
import com.badlogic.gdx.graphics.glutils.FrameBuffer;
import com.badlogic.gdx.graphics.glutils.ShapeRenderer;
import com.badlogic.gdx.maps.MapLayer;
import com.badlogic.gdx.maps.MapObject;
import com.badlogic.gdx.maps.objects.PointMapObject;
import com.badlogic.gdx.maps.objects.RectangleMapObject;
import com.badlogic.gdx.maps.tiled.TiledMap;
import com.badlogic.gdx.maps.tiled.TmxMapLoader;
import com.badlogic.gdx.maps.tiled.renderers.OrthogonalTiledMapRenderer;
import com.badlogic.gdx.math.MathUtils;
import com.badlogic.gdx.math.Matrix4;
import com.badlogic.gdx.math.Rectangle;
import com.badlogic.gdx.math.Vector2;
import com.badlogic.gdx.utils.ScreenUtils;

/**
 * Map scroller: loads a Tiled map and scrolls it with the arrow keys.
 *
 * <p>The world is drawn into a 320x180 frame buffer (the back buffer). That buffer is then
 * scaled onto the window by the largest whole-number factor that fits, centered, with black
 * bars filling the rest (letterboxing).
 *
 * <p>Note that libGDX uses y-up coordinates; the map loader flips the map accordingly.
 */
public class MapScroll extends ApplicationAdapter {
    static final int WORLD_WIDTH = 320;
    static final int WORLD_HEIGHT = 180;
    static final float SCROLL_SPEED = 180; // map pixels per second
    static final String MAP_PATH = "../assets/island.tmx";

    static final Color AREA_COLOR = new Color(1f, 0.86f, 0f, 1f);
    static final Color POINT_COLOR = new Color(1f, 0.16f, 0.16f, 1f);

    TiledMap map;
    OrthogonalTiledMapRenderer mapRenderer; // draws tile layers, including animated tiles
    ShapeRenderer shapes;                   // draws the objects
    OrthographicCamera camera;
    FrameBuffer buffer;                     // the 320x180 back buffer
    SpriteBatch screenBatch;                // draws the back buffer onto the window
    final Matrix4 screenProjection = new Matrix4();

    float mapWidth, mapHeight;
    final Vector2 viewCenter = new Vector2(); // center of the view, in map pixels (y-up)

    @Override
    public void create() {
        map = new TmxMapLoader().load(MAP_PATH);
        mapRenderer = new OrthogonalTiledMapRenderer(map);
        shapes = new ShapeRenderer();
        screenBatch = new SpriteBatch();

        buffer = new FrameBuffer(Pixmap.Format.RGBA8888, WORLD_WIDTH, WORLD_HEIGHT, false);
        buffer.getColorBufferTexture().setFilter(Texture.TextureFilter.Nearest, Texture.TextureFilter.Nearest);

        camera = new OrthographicCamera();
        camera.setToOrtho(false, WORLD_WIDTH, WORLD_HEIGHT);

        int tileWidth = map.getProperties().get("tilewidth", Integer.class);
        int tileHeight = map.getProperties().get("tileheight", Integer.class);
        mapWidth = map.getProperties().get("width", Integer.class) * tileWidth;
        mapHeight = map.getProperties().get("height", Integer.class) * tileHeight;

        // Start with the view centered on the "start" object.
        for (MapLayer layer : map.getLayers()) {
            for (MapObject object : layer.getObjects()) {
                if (object instanceof PointMapObject point && "start".equals(object.getProperties().get("type"))) {
                    viewCenter.set(point.getPoint());
                }
            }
        }
        clampView();
    }

    @Override
    public void render() {
        update(Gdx.graphics.getDeltaTime());
        drawWorld();
        drawBufferToScreen();
    }

    void update(float dt) {
        if (Gdx.input.isKeyPressed(Input.Keys.LEFT)) viewCenter.x -= SCROLL_SPEED * dt;
        if (Gdx.input.isKeyPressed(Input.Keys.RIGHT)) viewCenter.x += SCROLL_SPEED * dt;
        if (Gdx.input.isKeyPressed(Input.Keys.UP)) viewCenter.y += SCROLL_SPEED * dt;
        if (Gdx.input.isKeyPressed(Input.Keys.DOWN)) viewCenter.y -= SCROLL_SPEED * dt;
        clampView();
    }

    void clampView() {
        viewCenter.x = MathUtils.clamp(viewCenter.x, WORLD_WIDTH / 2f, mapWidth - WORLD_WIDTH / 2f);
        viewCenter.y = MathUtils.clamp(viewCenter.y, WORLD_HEIGHT / 2f, mapHeight - WORLD_HEIGHT / 2f);
    }

    /** Renders the visible part of the map into the 320x180 back buffer. */
    void drawWorld() {
        // Round the camera to whole pixels so tiles never land between pixels.
        camera.position.set(MathUtils.floor(viewCenter.x), MathUtils.floor(viewCenter.y), 0);
        camera.update();

        buffer.begin();
        ScreenUtils.clear(Color.BLACK);

        mapRenderer.setView(camera);
        mapRenderer.render(); // all tile layers in file order: Ground, Fringe, Over

        shapes.setProjectionMatrix(camera.combined);
        shapes.begin(ShapeRenderer.ShapeType.Filled);
        for (MapLayer layer : map.getLayers()) {
            if (!layer.isVisible()) continue;
            for (MapObject object : layer.getObjects()) { // tile layers have no objects
                if (object instanceof PointMapObject point) {
                    float x = MathUtils.floor(point.getPoint().x);
                    float y = MathUtils.floor(point.getPoint().y);
                    shapes.setColor(POINT_COLOR);
                    shapes.rect(x - 2, y - 2, 4, 4);
                } else if (object instanceof RectangleMapObject area) {
                    Rectangle r = area.getRectangle();
                    drawOutline(r.x, r.y, r.width, r.height);
                }
            }
        }
        shapes.end();

        buffer.end();
    }

    /** Draws a 1-pixel border just inside the given rectangle. */
    void drawOutline(float x, float y, float w, float h) {
        shapes.setColor(AREA_COLOR);
        shapes.rect(x, y, w, 1);         // bottom
        shapes.rect(x, y + h - 1, w, 1); // top
        shapes.rect(x, y, 1, h);         // left
        shapes.rect(x + w - 1, y, 1, h); // right
    }

    /** Scales the back buffer by a whole number and centers it in the window. */
    void drawBufferToScreen() {
        int screenWidth = Gdx.graphics.getBackBufferWidth();
        int screenHeight = Gdx.graphics.getBackBufferHeight();
        int scale = Math.max(1, Math.min(screenWidth / WORLD_WIDTH, screenHeight / WORLD_HEIGHT));
        int width = WORLD_WIDTH * scale;
        int height = WORLD_HEIGHT * scale;
        int x = (screenWidth - width) / 2;
        int y = (screenHeight - height) / 2;

        Gdx.gl.glViewport(0, 0, screenWidth, screenHeight);
        ScreenUtils.clear(Color.BLACK);

        screenBatch.setProjectionMatrix(screenProjection.setToOrtho2D(0, 0, screenWidth, screenHeight));
        screenBatch.begin();
        // Frame buffer textures are stored upside down, hence flipY = true.
        screenBatch.draw(buffer.getColorBufferTexture(), x, y, width, height,
                0, 0, WORLD_WIDTH, WORLD_HEIGHT, false, true);
        screenBatch.end();
    }

    @Override
    public void dispose() {
        screenBatch.dispose();
        buffer.dispose();
        shapes.dispose();
        mapRenderer.dispose();
        map.dispose();
    }

    public static void main(String[] args) {
        Lwjgl3ApplicationConfiguration config = new Lwjgl3ApplicationConfiguration();
        config.setTitle("Map scroll - Java + libGDX");
        config.setWindowedMode(WORLD_WIDTH, WORLD_HEIGHT);
        config.setResizable(true);
        config.useVsync(true);
        new Lwjgl3Application(new MapScroll(), config);
    }
}
