PLUGIN_NAME=omacursorshake

# Every tool is a variable so bin/backend.sh can pass absolute, validated paths
# on the command line, where they outrank both the environment and this file.
# The bare defaults keep `make` usable for development; the plugin itself is
# never built that way -- backend.sh runs this under `env -i` with CXX,
# PKG_CONFIG, SED, LDFLAGS and EXTRA_CXXFLAGS all given explicitly, so an
# inherited toolchain variable cannot reach the .so Hyprland dlopens.
# (CXX already has a built-in default of g++, so it is not restated here.)
PKG_CONFIG ?= pkg-config
SED ?= sed
HYPRCTL ?= hyprctl

SOURCE_FILES := $(wildcard ./src/*.cpp ./src/*/*.cpp ./src/*/*/*.cpp)
HEADER_FILES := $(wildcard ./src/*.hpp ./src/*/*.hpp ./src/*/*/*.hpp)

OBJECT_FILES := $(patsubst ./src/%.cpp, out/%.o, $(SOURCE_FILES))
CXXFLAGS := -Wall -fPIC -std=c++26 -g \
	$(shell $(PKG_CONFIG) --cflags hyprland pixman-1 libdrm | $(SED) 's#-I\([^ ]*/hyprland\)\($$\| \)#-I\1 -I\1/src #g')

OUTPUT=out/$(PLUGIN_NAME).so

# notdir: CXX arrives as an absolute path, so comparing against a bare `g++`
# would silently stop adding --no-gnu-unique -- the flag that keeps a reloaded
# .so from dangling on STB_GNU_UNIQUE symbols after dlclose.
ifeq ($(notdir $(CXX)),g++)
    CXXFLAGS += --no-gnu-unique
endif

.PHONY: all clean load unload format

all: $(OUTPUT)

$(OUTPUT): $(OBJECT_FILES)
	$(CXX) -shared $^ $(LDFLAGS) -o $@

out/%.o: ./src/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) $(EXTRA_CXXFLAGS) -c $< -o $@

clean:
	$(RM) $(OUTPUT) $(OBJECT_FILES)

format:
	clang-format -i $(HEADER_FILES) $(SOURCE_FILES)

load: all unload
	$(HYPRCTL) plugin load ${PWD}/$(OUTPUT)

unload:
	$(HYPRCTL) plugin unload ${PWD}/$(OUTPUT)
