# ---------------------------------------------------------------------------
# Canary — a minimal but genuine JUCE 8 audio plugin.
#
# Its only job is to prove the Runner Forge pipeline end to end: that a real
# plugin compiles for every target, produces every artifact the contract in
# docs/VERIFICATION.md demands, and does it fast enough on a warm cache.
#
# It deliberately does NOT depend on the private RecRoll repository or on the
# proprietary Avid AAX SDK, so end-to-end verification is reproducible by
# anyone.
# ---------------------------------------------------------------------------
cmake_minimum_required(VERSION 3.22)

# --- versions come from versions.toml, never from this file ----------------
#
# No version string is hardcoded outside versions.toml. When the canary is
# published standalone (to <owner>/runner-forge-canary) versions.toml must be
# copied alongside it; see canary/README.md.
function(canary_find_versions_toml out_var)
  foreach(candidate
      "${CMAKE_CURRENT_SOURCE_DIR}/versions.toml"
      "${CMAKE_CURRENT_SOURCE_DIR}/../versions.toml"
      "${CMAKE_SOURCE_DIR}/versions.toml"
      "${CMAKE_SOURCE_DIR}/../versions.toml")
    if(EXISTS "${candidate}")
      get_filename_component(resolved "${candidate}" ABSOLUTE)
      set(${out_var} "${resolved}" PARENT_SCOPE)
      return()
    endif()
  endforeach()
  message(FATAL_ERROR
    "versions.toml not found. It is the single source of truth for every pinned "
    "version and this project refuses to guess one. Looked in:\n"
    "  ${CMAKE_CURRENT_SOURCE_DIR}/versions.toml\n"
    "  ${CMAKE_CURRENT_SOURCE_DIR}/../versions.toml\n"
    "  ${CMAKE_SOURCE_DIR}/versions.toml\n"
    "  ${CMAKE_SOURCE_DIR}/../versions.toml")
endfunction()

# Reads `key = "value"` out of versions.toml, ignoring comment lines so a note
# that merely mentions a version can never be mistaken for the pin itself.
function(canary_read_pin out_var key)
  file(STRINGS "${CANARY_VERSIONS_TOML}" lines)
  foreach(line IN LISTS lines)
    string(REGEX REPLACE "^[ \t]*#.*$" "" line "${line}")
    if(line MATCHES "^[ \t]*${key}[ \t]*=[ \t]*\"([^\"]+)\"")
      set(${out_var} "${CMAKE_MATCH_1}" PARENT_SCOPE)
      return()
    endif()
  endforeach()
  message(FATAL_ERROR "Key '${key}' not found in ${CANARY_VERSIONS_TOML}.")
endfunction()

canary_find_versions_toml(CANARY_VERSIONS_TOML)
message(STATUS "Canary: reading pinned versions from ${CANARY_VERSIONS_TOML}")
canary_read_pin(CANARY_JUCE_VERSION juce)
canary_read_pin(CANARY_CLAP_EXT_VERSION clap_juce_extensions)
message(STATUS "Canary: JUCE ${CANARY_JUCE_VERSION}, clap-juce-extensions ${CANARY_CLAP_EXT_VERSION}")

project(Canary VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
  # universal2. Overridable so a developer can do a fast single-arch local build.
  set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "" FORCE)
endif()

include(FetchContent)

# FETCHCONTENT_BASE_DIR is set by the runner image to a persistent named volume,
# so JUCE is cloned once per machine and not once per build. Proving that this
# actually works is what the Stage C duration comparison is for.
FetchContent_Declare(JUCE
  GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
  GIT_TAG        ${CANARY_JUCE_VERSION}
  GIT_SHALLOW    TRUE
  GIT_PROGRESS   TRUE)
FetchContent_MakeAvailable(JUCE)

# Pinned by commit SHA (see versions.toml for why there is no usable tag).
# GIT_SHALLOW is deliberately off here: a shallow clone cannot check out an
# arbitrary commit, only a branch or tag tip.
FetchContent_Declare(clap-juce-extensions
  GIT_REPOSITORY https://github.com/free-audio/clap-juce-extensions.git
  GIT_TAG        ${CANARY_CLAP_EXT_VERSION}
  GIT_SHALLOW    FALSE
  GIT_PROGRESS   TRUE)
FetchContent_MakeAvailable(clap-juce-extensions)

# --- plugin formats --------------------------------------------------------
#
# VST3, Standalone and CLAP everywhere. AU is macOS only. AAX is deliberately
# absent from the canary: it needs the proprietary Avid SDK, and the whole point
# of the canary is that verification never depends on it.
set(CANARY_FORMATS VST3 Standalone)
if(APPLE)
  list(APPEND CANARY_FORMATS AU)
endif()

juce_add_plugin(Canary
  COMPANY_NAME              "EION Studios"
  BUNDLE_ID                 "com.eionstudios.canary"
  PLUGIN_MANUFACTURER_CODE  Eion
  PLUGIN_CODE               Cnry
  FORMATS                   ${CANARY_FORMATS}
  PRODUCT_NAME              "Canary"
  IS_SYNTH                  FALSE
  NEEDS_MIDI_INPUT          FALSE
  NEEDS_MIDI_OUTPUT         FALSE
  IS_MIDI_EFFECT            FALSE
  EDITOR_WANTS_KEYBOARD_FOCUS FALSE
  COPY_PLUGIN_AFTER_BUILD   FALSE
  VST3_CATEGORIES           "Fx" "Filter"
  AU_MAIN_TYPE              "kAudioUnitType_Effect")

# CLAP is added on top of the existing plugin target by clap-juce-extensions.
clap_juce_extensions_plugin(TARGET Canary
  CLAP_ID              "com.eionstudios.canary"
  CLAP_FEATURES        audio-effect utility filter
  CLAP_MANUAL_URL      "https://github.com/AA-EION/runner-forge-canary"
  CLAP_SUPPORT_URL     "https://github.com/AA-EION/runner-forge-canary/issues")

target_sources(Canary PRIVATE
  Source/PluginProcessor.cpp
  Source/PluginEditor.cpp)

# JUCE 8 no longer has a splash screen, so JUCE_DISPLAY_SPLASH_SCREEN is not set
# here: passing it makes JUCE emit a "flag is ignored" #pragma message on every
# translation unit, which buries real warnings.
target_compile_definitions(Canary PUBLIC
  JUCE_WEB_BROWSER=0
  JUCE_USE_CURL=0
  JUCE_VST3_CAN_REPLACE_VST2=0)

target_link_libraries(Canary PRIVATE
  juce::juce_audio_utils
  PUBLIC
  juce::juce_recommended_config_flags
  juce::juce_recommended_warning_flags)

# --- tests -----------------------------------------------------------------
#
# A console app linked against the plugin's shared code, so the tests exercise
# the same objects the plugin ships rather than a copy.
# A plain executable rather than juce_add_console_app: the console-app helper
# defines JUCE_STANDALONE_APPLICATION=1 while the plugin target defines it as
# JucePlugin_Build_Standalone, and linking both produces a "redefined" warning on
# every translation unit. Linking Canary_SharedCode gives the tests the exact
# object code the plugin ships, with one consistent set of definitions.
add_executable(CanaryTests Source/Tests.cpp)

# Linking the `Canary` target (not `Canary_SharedCode`) is deliberate: JUCE links
# the modules into SharedCode PRIVATEly, so SharedCode's interface carries no
# include directories. `Canary` carries the includes, the JucePlugin_* definitions
# and the shared object code together.
# `Canary` supplies the shared object code and the JucePlugin_* definitions;
# juce::juce_audio_utils supplies the module include directories, which `Canary`
# does not re-export because JUCE links the modules into it PRIVATEly.
target_link_libraries(CanaryTests PRIVATE
  Canary
  juce::juce_audio_utils
  juce::juce_recommended_config_flags
  juce::juce_recommended_warning_flags)

set_target_properties(CanaryTests PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/tests")

enable_testing()
add_test(NAME CanaryTests COMMAND CanaryTests)

# Where the packaging scripts look for build output.
message(STATUS "Canary: formats = ${CANARY_FORMATS} (+ CLAP)")
