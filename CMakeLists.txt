cmake_minimum_required(VERSION 3.20)

set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0" CACHE STRING
    "Oldest macOS release supported by this experiment")

project(ec20_at_probe LANGUAGES OBJC)

add_library(ec20-usb-at STATIC
    src/EC20USBATTransport.m
)

target_include_directories(ec20-usb-at PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
)

target_compile_options(ec20-usb-at PRIVATE
    -fobjc-arc
    -fblocks
    -Wall
    -Wextra
    -Wpedantic
)

target_link_libraries(ec20-usb-at PUBLIC
    "-framework Foundation"
    "-framework IOKit"
    "-framework IOUSBHost"
)

add_library(ec20-ipc STATIC
    src/EC20IPCProtocol.m
)

target_include_directories(ec20-ipc PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
)

target_compile_options(ec20-ipc PRIVATE
    -fobjc-arc
    -fblocks
    -Wall
    -Wextra
    -Wpedantic
)

target_link_libraries(ec20-ipc PUBLIC
    "-framework Foundation"
)

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
    ec20-usb-at
)

add_executable(ec20-ipc-protocol-tests
    tests/ec20_ipc_protocol_tests.m
)

target_compile_options(ec20-ipc-protocol-tests PRIVATE
    -fobjc-arc
    -fblocks
    -Wall
    -Wextra
    -Wpedantic
)

target_link_libraries(ec20-ipc-protocol-tests PRIVATE
    ec20-ipc
)

enable_testing()
add_test(NAME ec20-at-probe-self-test COMMAND ec20-at-probe --self-test)
add_test(NAME ec20-ipc-protocol-self-test COMMAND ec20-ipc-protocol-tests)
