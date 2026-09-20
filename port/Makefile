# calfNXT macOS — single build entry point.
#
# Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
#
# Builds with the Xcode generator (like auxVST): Xcode writes proper bundle
# metadata (PkgInfo, full Info.plist) and applies the SDK's codesign step.
# Local builds are ad-hoc signed; distribution signing is tools/release.sh.
#
#   make                      # configure + build all 25 plugins (UI + DSP + bundle + sign)
#   make PLUGIN=compressor    # one plugin
#   make ui                   # UI packs only
#   make dsp                  # DSP targets only
#   make install              # copy bundles to ~/Library/Audio/Plug-Ins/VST3
#   make check                # validator + seam drift checks
#   make release VERSION=2.3.1.1            # clean rebuild + Developer ID sign → Releases/2.3.1.1/
#   make release VERSION=2.3.1.1 NOTARIZE=1 #   + notarize + staple (see HOWTO-DISTRIBUTE.md)
#   make sync-upstream TAG=vX.Y.Z
#   make clean | distclean
#
# Variables: CONFIG=Release|Debug  PLUGIN=<id>  JOBS=<n>  NOTARIZE=1  VERSION=2.3.1.1
# Release credentials: CODE_SIGN_IDENTITY / DEVELOPMENT_TEAM / NOTARY_PROFILE
# (usually via repo-root .env.local — see .env.local.example)

CONFIG      ?= Release
PLUGIN      ?=
JOBS        ?= $(shell sysctl -n hw.ncpu 2>/dev/null || echo 8)
BUILD_DIR   := $(CURDIR)/build
UPSTREAM    := $(CURDIR)/../calfnxt

PLUGINS     := equalizer stereo transients compressor expander deesser delay reverb \
               mbcomp limiter mblimiter harmonics analyzer filter ringmod pulsator \
               crusher phaser flanger chorus split tuner octaver bender impulse

ifeq ($(PLUGIN),)
  TARGETS   := calfnxt-plugins
else
  TARGETS   := calfnxt-$(PLUGIN) calfnxt-$(PLUGIN)-resources
endif

.PHONY: all ui dsp install check release sync-upstream clean distclean configure

# Release credentials propagate to tools/release.sh (which also loads .env.local).
export CODE_SIGN_IDENTITY DEVELOPMENT_TEAM CODE_SIGN_STYLE NOTARY_PROFILE VERSION

all: $(TARGETS)

configure:
	@if [ -f "$(BUILD_DIR)/CMakeCache.txt" ] && ! grep -q '^CMAKE_GENERATOR:INTERNAL=Xcode$$' "$(BUILD_DIR)/CMakeCache.txt"; then \
	  echo "[make] build dir was not generated with Xcode — wiping $(BUILD_DIR)"; \
	  rm -rf "$(BUILD_DIR)"; \
	fi
	@cmake -S "$(CURDIR)" -B "$(BUILD_DIR)" -G Xcode \
	  -DSMTG_XCODE_MANUAL_CODE_SIGN_STYLE=ON \
	  -DSMTG_BUILD_UNIVERSAL_BINARY=OFF

$(TARGETS): configure
	@cmake --build "$(BUILD_DIR)" --config $(CONFIG) --target $@ --parallel $(JOBS)

ui: configure
	@cmake --build "$(BUILD_DIR)" --config $(CONFIG) --target calfnxt_web_ui --parallel $(JOBS)

dsp: configure
	@cmake --build "$(BUILD_DIR)" --config $(CONFIG) --target $(if $(PLUGIN),calfnxt-$(PLUGIN),calfnxt-plugins) --parallel $(JOBS)

install: all
	@cmake --build "$(BUILD_DIR)" --config $(CONFIG) --target install-user-vst3 --parallel $(JOBS)

check: configure
	@"$(CURDIR)/tools/check-seam.sh" "$(UPSTREAM)"
	@"$(CURDIR)/tools/validate-all.sh" "$(BUILD_DIR)" "$(CONFIG)"

# release.sh owns the clean rebuild; do not depend on incremental `all` here.
release:
	@"$(CURDIR)/tools/release.sh" $(VERSION) $(if $(NOTARIZE),--notarize,) CONFIG=$(CONFIG)

sync-upstream:
	@"$(CURDIR)/tools/upstream-sync.sh" "$(TAG)"

clean:
	@rm -rf "$(BUILD_DIR)"

distclean: clean
	@rm -rf "$(UPSTREAM)/ui/dist" "$(UPSTREAM)/ui/node_modules"
