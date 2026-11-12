{
  clangStdenv,
  lib,
  fetchFromGitHub,
  cmake,
  pkg-config,
  wrapGAppsHook3,
  assimp,
  boost186,
  cereal,
  cgal,
  curl,
  dbus,
  draco,
  eigen_5,
  expat,
  ffmpeg,
  glew,
  glfw,
  glib,
  glib-networking,
  gmp,
  gst_all_1,
  gtest,
  gtk3,
  hicolor-icon-theme,
  libdatachannel,
  libsecret,
  libpng,
  mpfr,
  nlopt,
  opencascade-occt,
  openvdb,
  opencv,
  python312,
  systemdLibs,
  onetbb,
  usrsctp,
  uv,
  webkitgtk_4_1,
  wxwidgets_3_3,
  libx11,
  libnoise,
  withSystemd ? clangStdenv.hostPlatform.isLinux,
  withNvidiaGLWorkaround ? false,
}:
let
  versionInfo = lib.importJSON ./version.json;

  wxGTK' =
    (wxwidgets_3_3.override {
      withPrivateFonts = true;
      withWebKit = true;
      withEGL = true;
    }).overrideAttrs
      (old: {
        buildInputs = old.buildInputs ++ [ libsecret ];
        configureFlags = old.configureFlags ++ [
          "--enable-debug=no"
          "--enable-secretstore"
        ];
      });

  # Small vendored dependency (upstream builds it itself via deps/wxInspector), not
  # packaged in nixpkgs: a wxWidgets debug-inspector panel, linked unconditionally by
  # src/CMakeLists.txt. Built against the same wxGTK' as OrcaSlicer itself.
  wxInspector = clangStdenv.mkDerivation {
    pname = "wxInspector";
    version = "1.0.0";

    src = fetchFromGitHub {
      owner = "Noisyfox";
      repo = "wxInspector";
      tag = "v1.0.0";
      hash = "sha256-AQbV2vAGJXatAXwLAxhWVXTdKqxj2v0THexQyKbroJw=";
    };

    nativeBuildInputs = [
      cmake
      pkg-config
    ];
    buildInputs = [
      wxGTK'
      gtk3
    ];

    meta = {
      description = "wxWidgets debug/inspector panel used by OrcaSlicer";
      homepage = "https://github.com/Noisyfox/wxInspector";
      platforms = lib.platforms.linux;
    };
  };
in
# Build with clang even on Linux: GCC uses absolutely obscene amounts of memory
# on this particular code base (OOM with 32GB memory and --cores 16 on GCC,
# succeeds with --cores 32 on clang).
clangStdenv.mkDerivation (finalAttrs: {
  pname = "orca-slicer";
  version = versionInfo.version;

  src = fetchFromGitHub {
    owner = "OrcaSlicer";
    repo = "OrcaSlicer";
    tag = "v${finalAttrs.version}";
    hash = versionInfo.hash;
  };

  __structuredAttrs = true;
  strictDeps = true;

  nativeBuildInputs = [
    cmake
    pkg-config
    wrapGAppsHook3
    wxGTK'
    # Needed on the PATH at configure time for find_package(Python3 ... COMPONENTS Interpreter ...).
    python312
  ];

  buildInputs = [
    assimp
    boost186
    boost186.dev
    cereal
    cgal
    curl
    dbus
    draco
    eigen_5
    expat
    ffmpeg
    glew
    glfw
    glib
    glib-networking
    gmp
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-bad
    (gst_all_1.gst-plugins-good.override { gtkSupport = true; })
    gtk3
    hicolor-icon-theme
    libdatachannel
    libsecret
    libpng
    mpfr
    nlopt
    opencascade-occt
    openvdb
    onetbb
    usrsctp
    # Embeds libpython via pybind11::embed.
    python312
    webkitgtk_4_1
    wxGTK'
    wxInspector
    libx11
    opencv.cxxdev
    libnoise
  ]
  ++ lib.optionals withSystemd [ systemdLibs ]
  ++ finalAttrs.checkInputs;

  patches = [
    # Fix for webkitgtk linking
    ./patches/0001-link-against-webkit2gtk.patch
    # Pick https://github.com/prusa3d/PrusaSlicer/pull/14207 to remove unused and insecure ilmbase dependency
    ./patches/no-ilmbase.patch
  ];

  doCheck = true;
  checkInputs = [ gtest ];

  separateDebugInfo = true;

  env = {
    NLOPT = nlopt;

    NIX_CFLAGS_COMPILE = toString [
      "-Wno-ignored-attributes"
      "-I${opencv.out}/include/opencv4"
      "-Wno-error=incompatible-pointer-types"
      "-Wno-error=format-security"
      "-Wno-uninitialized"
      "-Wno-unused-result"
      "-Wno-deprecated-declarations"
      "-Wno-format-overflow"
      "-DBOOST_ALLOW_DEPRECATED_HEADERS"
      "-DBOOST_MATH_DISABLE_STD_FPCLASSIFY"
      "-DBOOST_MATH_NO_LONG_DOUBLE_MATH_FUNCTIONS"
      "-DBOOST_MATH_DISABLE_FLOAT128"
      "-DBOOST_MATH_NO_QUAD_SUPPORT"
      "-DBOOST_MATH_MAX_FLOAT128_DIGITS=0"
      "-DBOOST_CSTDFLOAT_NO_LIBQUADMATH_SUPPORT"
      "-DBOOST_MATH_DISABLE_FLOAT128_BUILTIN_FPCLASSIFY"
    ];

    NIX_LDFLAGS = toString [
      (lib.optionalString withSystemd "-ludev")
      "-L${boost186}/lib"
      "-lboost_log"
      "-lboost_log_setup"
    ];
  };

  prePatch = ''
    sed -i \
      -e 's|<libnoise/module/modulebase.h>|<noise/module/modulebase.h>|' \
      -e 's|"libnoise/noise.h"|"noise/noise.h"|' \
      src/libslic3r/Feature/FuzzySkin/FuzzySkin.cpp

    # wx 3.3.4 renamed/removed wxGridCellChoiceEditor::OnComboCloseUp; both editors in
    # this file still call the old API (upstream bug, not yet fixed for 3.3.4).
    substituteInPlace src/slic3r/GUI/GUI_ObjectTable.cpp \
      --replace-fail "wxGridCellChoiceEditor::OnComboCloseUp(evt)" "wxGridCellChoiceEditor::DismissEditor()"

    # Link opencv_core/imgproc/imgcodecs instead of the monolithic opencv_world,
    # which nixpkgs' opencv does not build.
    substituteInPlace src/libslic3r/CMakeLists.txt \
      --replace-fail "opencv_world" "opencv_core
        opencv_imgproc
        opencv_imgcodecs"

    # On Linux, src/CMakeLists.txt unconditionally copies a hardcoded, exact-version
    # set of ffmpeg .so files (e.g. libavformat.so.61.1.100) out of CMAKE_PREFIX_PATH
    # next to the build-tree binary, for self-contained/AppImage-style distribution.
    # That's both unnecessary under SLIC3R_FHS (the installed binary finds ffmpeg via
    # its normal rpath) and immediately fails configure since nixpkgs' ffmpeg is a
    # different major version with different sonames. Skip it for FHS installs.
    substituteInPlace src/CMakeLists.txt \
      --replace-fail 'if (NOT APPLE)' 'if (NOT APPLE AND NOT SLIC3R_FHS)'

    # Same story for the top-level install() rule that copies those same ffmpeg .so
    # files from the build tree into $out/bin: it depends on the build-tree copy step
    # just disabled above, and is equally unnecessary since the installed binary links
    # ffmpeg via its normal rpath.
    substituteInPlace CMakeLists.txt \
      --replace-fail 'install(FILES ''${LIBRARY_FILES} DESTINATION "''${CMAKE_INSTALL_PREFIX}/bin")' 'if (NOT SLIC3R_FHS)
        install(FILES ''${LIBRARY_FILES} DESTINATION "''${CMAKE_INSTALL_PREFIX}/bin")
    endif ()'

    # Upstream pins the embedded interpreter to an exact Python patch version
    # (3.12.13 at the time of writing) that is baked into their own deps build.
    # Relax it to a minor-version match so it accepts whatever 3.12.x nixpkgs ships.
    substituteInPlace CMakeLists.txt \
      --replace-fail "''${_bundled_python_version} EXACT" "''${_bundled_python_version_short}"
  '';

  # Upstream's own CMake configure step stages Python, OpenCASCADE and usrsctp from a
  # single CMAKE_PREFIX_PATH ("<prefix>/libpython", "<prefix>/lib/cmake/occt",
  # "<prefix>/lib/libusrsctp.a") following their own deps-build convention; it does not
  # look any of these up in the normal nixpkgs way. Build that small staging tree here,
  # outside the Nix store, from the real packages.
  #
  # This has to happen with __structuredAttrs on, cmakeFlags entries are passed to cmake
  # literally (no shell expansion), so $TMPDIR can't appear there; append to the
  # setup-hook's own cmakeFlagsArray instead, which *is* built by this shell script.
  preConfigure = ''
    cmakePrefixDir="$TMPDIR/cmake-prefix"
    mkdir -p "$cmakePrefixDir/lib/cmake"
    ln -s "${python312}" "$cmakePrefixDir/libpython"

    # OCCT's exported Targets.cmake computes its _IMPORT_PREFIX from the on-disk
    # location of the file CMake includes (two directories up from lib/cmake/<name>/),
    # without resolving symlinks. Symlinking just lib/cmake/opencascade in would make
    # it look for the actual .so files under cmakePrefixDir/lib too, so mirror those
    # into cmakePrefixDir/lib directly rather than symlinking the whole tree in one go.
    for f in "${opencascade-occt}"/lib/*.so* "${opencascade-occt}"/lib/*.a; do
      [ -e "$f" ] && ln -s "$f" "$cmakePrefixDir/lib/$(basename "$f")"
    done
    ln -s "${opencascade-occt}/lib/cmake/opencascade" "$cmakePrefixDir/lib/cmake/occt"
    mkdir -p "$cmakePrefixDir/include"
    ln -s "${opencascade-occt}/include/opencascade" "$cmakePrefixDir/include/opencascade"

    ln -s "${usrsctp}/lib/libusrsctp.a" "$cmakePrefixDir/lib/libusrsctp.a"

    cmakeFlagsArray+=("-DCMAKE_PREFIX_PATH=$cmakePrefixDir")
  '';

  cmakeFlags = [
    (lib.cmakeBool "SLIC3R_STATIC" false)
    (lib.cmakeBool "SLIC3R_FHS" true)
    (lib.cmakeFeature "SLIC3R_GTK" "3")
    # The parametric Design/CAD tab needs upstream's own vendored SolveSpace solver
    # build (deps/SLVS, producing a bespoke SLVSConfig.cmake) that isn't packaged in
    # nixpkgs; leave it off rather than vendor that build ourselves.
    (lib.cmakeBool "SLIC3R_CAD" false)
    (lib.cmakeBool "BBL_RELEASE_TO_PUBLIC" true)
    (lib.cmakeBool "BUILD_TESTS" false)
    (lib.cmakeBool "ORCA_BUILD_PYTHON_STUBGEN_MODULE" false)
    # Points the embedded interpreter's package manager at a prebuilt uv instead of
    # letting CMake configure download one (the Nix sandbox has no network access).
    (lib.cmakeFeature "ORCA_BUNDLED_UV_EXECUTABLE" (lib.getExe uv))
    (lib.cmakeFeature "CMAKE_CXX_FLAGS" "-DGL_SILENCE_DEPRECATION")
    (lib.cmakeFeature "CMAKE_EXE_LINKER_FLAGS" "-Wl,--no-as-needed")
    (lib.cmakeFeature "LIBNOISE_INCLUDE_DIR" "${libnoise}/include")
    (lib.cmakeFeature "LIBNOISE_LIBRARY_RELEASE" "${libnoise}/lib/libnoise-static.a")
    "-Wno-dev"
  ];

  # Generate translation files
  postBuild = "( cd .. && ./scripts/run_gettext.sh )";

  preFixup = ''
    gappsWrapperArgs+=(
      # OCCT's shared libs are only ever linked by their path under the synthetic
      # cmake-prefix staging dir (see preConfigure), which doesn't exist once the
      # build sandbox is gone; the ld wrapper's automatic rpath from that path gets
      # stripped as dangling during fixup, so point the loader at the real one here.
      --prefix LD_LIBRARY_PATH : "$out/lib:${
        lib.makeLibraryPath [
          glew
          opencascade-occt
        ]
      }"
      --set WEBKIT_DISABLE_COMPOSITING_MODE 1
      ${lib.optionalString withNvidiaGLWorkaround ''
        --set __GLX_VENDOR_LIBRARY_NAME mesa
        --set __EGL_VENDOR_LIBRARY_FILENAMES /run/opengl-driver/share/glvnd/egl_vendor.d/50_mesa.json
        --set MESA_LOADER_DRIVER_OVERRIDE zink
        --set GALLIUM_DRIVER zink
        --set WEBKIT_DISABLE_DMABUF_RENDERER 1
      ''}
    )
  '';

  postInstall = ''
    rm -f $out/LICENSE.txt
  '';

  meta = {
    description = "G-code generator for 3D printers (Bambu, Prusa, Voron, VzBot, RatRig, Creality, etc.)";
    homepage = "https://github.com/OrcaSlicer/OrcaSlicer";
    changelog = "https://github.com/OrcaSlicer/OrcaSlicer/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.agpl3Only;
    mainProgram = "orca-slicer";
    platforms = lib.platforms.linux;
  };
})
