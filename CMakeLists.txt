cmake_minimum_required(VERSION 3.20)

set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0" CACHE STRING
    "Oldest macOS release supported by this experiment")

project(ec20_at_probe LANGUAGES OBJC)

add_executable(ec20-at-probe
    src/ec20_at_probe.m
)

target_compile_options(ec20-at-probe PRIVATE
    -fobjc-arc
    -fblocks
    -Wall
    -Wextra
    -Wpedantic
)

target_link_libraries(ec20-at-probe PRIVATE
    "-framework Foundation"
    "-framework IOKit"
    "-framework IOUSBHost"
)

enable_testing()
add_test(NAME ec20-at-probe-self-test COMMAND ec20-at-probe --self-test)
