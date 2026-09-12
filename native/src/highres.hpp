#pragma once

#include <future>
#define private public
#include <hyprland/src/pointer/cursor/CursorManager.hpp>
#undef private
#include <hyprland/src/managers/XCursorManager.hpp>
#include <hyprland/src/render/Texture.hpp>
#include <hyprland/src/helpers/memory/Memory.hpp>
#include <hyprcursor/hyprcursor.hpp>

#include <hyprutils/math/Vector2D.hpp>
#include <hyprutils/signal/Listener.hpp>
#include <string>

class CHighresHandler {
  public:
    CHighresHandler();
    ~CHighresHandler();

    void update();
    void loadShape(const std::string& name);
    /* harvest an async hyprcursor load and refresh the last shape */
    void tick();

    SP<Render::ITexture>               getTexture();
    SP<Pointer::Cursor::CCursorBuffer> getBuffer();

  private:
    bool tryHyprcursor(const std::string& name);
    bool tryXcursor(const std::string& name);
    void adoptBuffer(SP<Pointer::Cursor::CCursorBuffer> buf);
    std::string themeName();
    unsigned int targetSize();
    bool         hyprcursorWanted();

    Hyprcursor::SCursorStyleInfo style;

    UP<std::future<UP<Hyprcursor::CHyprcursorManager>>> managerFuture;
    UP<Hyprcursor::CHyprcursorManager>                  manager;

    UP<CXCursorManager> xcursor;
    unsigned int        xcLoadedSize = 0;
    std::string         xcLoadedName;

    unsigned int loadedSize = -1;
    std::string  loadedName = "";

    std::string                        shape = "left_ptr";
    SP<Render::ITexture>               texture;
    SP<Pointer::Cursor::CCursorBuffer> buffer;

    Hyprutils::Signal::CHyprSignalListener m_configReload;
};
