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

add_library(ec20-pty STATIC
    src/EC20PTYBridge.m
)

target_include_directories(ec20-pty PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
)

target_compile_options(ec20-pty PRIVATE
    -fobjc-arc
    -fblocks
    -Wall
    -Wextra
    -Wpedantic
)

target_link_libraries(ec20-pty PUBLIC
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

add_executable(ec20d
    src/ec20d.m
)

target_compile_options(ec20d PRIVATE
    -fobjc-arc
    -fblocks
    -Wall
    -Wextra
    -Wpedantic
)

target_link_libraries(ec20d PRIVATE
    ec20-ipc
    ec20-pty
    ec20-usb-at
)

add_executable(ec20ctl
    src/ec20ctl.m
)

target_compile_options(ec20ctl PRIVATE
    -fobjc-arc
    -fblocks
    -Wall
    -Wextra
    -Wpedantic
)

target_link_libraries(ec20ctl PRIVATE
    ec20-ipc
)

add_executable(ec20-pty-smoke
    tests/ec20_pty_smoke.m
)

target_compile_options(ec20-pty-smoke PRIVATE
    -Wall
    -Wextra
    -Wpedantic
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
add_test(NAME ec20d-self-test COMMAND ec20d --self-test)
add_test(NAME ec20ctl-self-test COMMAND ec20ctl --self-test)
add_test(
    NAME ec20d-mock-integration
    COMMAND "${CMAKE_COMMAND}" -E env
        "EC20D_BIN=$<TARGET_FILE:ec20d>"
        "EC20CTL_BIN=$<TARGET_FILE:ec20ctl>"
        /bin/sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/ec20d_mock_integration.sh"
)
set_tests_properties(ec20d-mock-integration PROPERTIES TIMEOUT 20)
add_test(
    NAME ec20d-pty-mock-integration
    COMMAND "${CMAKE_COMMAND}" -E env
        "EC20D_BIN=$<TARGET_FILE:ec20d>"
        "EC20CTL_BIN=$<TARGET_FILE:ec20ctl>"
        "EC20_PTY_SMOKE_BIN=$<TARGET_FILE:ec20-pty-smoke>"
        /bin/sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/ec20d_pty_integration.sh"
)
set_tests_properties(ec20d-pty-mock-integration PROPERTIES TIMEOUT 20)

# Keep the core build usable without Go, while automatically exercising the
# exact serial package used by Vohive whenever a Go toolchain is available.
find_program(EC20_GO_EXECUTABLE NAMES go)
if(EC20_GO_EXECUTABLE)
    add_test(
        NAME ec20d-vohive-serial-integration
        COMMAND "${CMAKE_COMMAND}" -E env
            "EC20D_BIN=$<TARGET_FILE:ec20d>"
            "EC20CTL_BIN=$<TARGET_FILE:ec20ctl>"
            "GO_BIN=${EC20_GO_EXECUTABLE}"
            /bin/sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/ec20d_vohive_serial_integration.sh"
    )
    set_tests_properties(ec20d-vohive-serial-integration PROPERTIES TIMEOUT 30)

    add_test(
        NAME ec20d-vohive-manager-integration
        COMMAND "${CMAKE_COMMAND}" -E env
            "EC20D_BIN=$<TARGET_FILE:ec20d>"
            "EC20CTL_BIN=$<TARGET_FILE:ec20ctl>"
            "GO_BIN=${EC20_GO_EXECUTABLE}"
            "VOHIVE_DIR=${CMAKE_CURRENT_SOURCE_DIR}/third_party/vohive"
            /bin/sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/ec20d_vohive_manager_integration.sh"
    )
    set_tests_properties(ec20d-vohive-manager-integration PROPERTIES TIMEOUT 45)

    add_test(
        NAME vohive-darwin-modem-safety-unit
        COMMAND "${CMAKE_COMMAND}" -E env
            "GOWORK=off"
            "${EC20_GO_EXECUTABLE}" test -count=1
                -run "^(TestSerialPortLease.*|TestIMEIProbeCannotOpenManagerLeasedPort|TestSerialATCannotOpenManagerLeasedPort|TestDarwin.*|TestIsRetryableSerialOpenErr|TestProbeIMEICached.*)$"
                ./internal/modem
    )
    set_tests_properties(vohive-darwin-modem-safety-unit PROPERTIES
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/third_party/vohive"
        TIMEOUT 60
    )

    add_test(
        NAME vohive-darwin-provider-unit
        COMMAND "${CMAKE_COMMAND}" -E env
            "GOWORK=off"
            "${EC20_GO_EXECUTABLE}" test -count=1
                ./internal/platform/ec20d
                ./cmd/vohive-darwin-probe
    )
    set_tests_properties(vohive-darwin-provider-unit PROPERTIES
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/third_party/vohive"
        TIMEOUT 60
    )

    add_test(
        NAME vohive-darwin-device-provider-unit
        COMMAND "${CMAKE_COMMAND}" -E env
            "GOWORK=off"
            "${EC20_GO_EXECUTABLE}" test -count=1
                -run "^(TestEC20DHardwareProvider.*|TestNewEC20DHardwareProvider.*|TestNewPoolWithHardwareProvider.*|TestCollectRescanHardwareUsesProviderSnapshot|TestRescanHardwareProviderErrorDoesNotEvictWorkers|TestRescanHardwareProviderTimeoutReleasesLockForRetry|TestHardwareProviderCanceledContextDoesNotScan|TestAuthoritativeEmptyProviderSnapshotEvictsOfflineWorker|TestWithNilHardwareProviderKeepsLegacyMode|TestResolveCompatibleModemATPort.*|TestProbeIMEICached.*|TestHandleDeviceMgmtDiscoveredUsesPoolHardwareProvider|TestHandleDeviceMgmtDiscoveredProviderWithIMEIUsesAttachmentScopedEnrichment|TestHandleDeviceMgmtDiscoveredProviderEmptySnapshotIsAuthoritative|TestHandleDeviceMgmtDiscoveredReportsProviderFailure|TestHandleDeviceMgmtDiscoveredPropagatesRequestCancellationToProvider)$"
                ./internal/modem
                ./internal/device
                ./internal/api
    )
    set_tests_properties(vohive-darwin-device-provider-unit PROPERTIES
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/third_party/vohive"
        TIMEOUT 120
    )

    add_test(
        NAME vohive-darwin-provider-integration
        COMMAND "${CMAKE_COMMAND}" -E env
            "EC20D_BIN=$<TARGET_FILE:ec20d>"
            "GO_BIN=${EC20_GO_EXECUTABLE}"
            "VOHIVE_DIR=${CMAKE_CURRENT_SOURCE_DIR}/third_party/vohive"
            /bin/sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/vohive_darwin_provider_integration.sh"
    )
    set_tests_properties(vohive-darwin-provider-integration PROPERTIES TIMEOUT 60)

    add_test(
        NAME vohive-darwin-web-integration
        COMMAND "${CMAKE_COMMAND}" -E env
            "EC20D_BIN=$<TARGET_FILE:ec20d>"
            "GO_BIN=${EC20_GO_EXECUTABLE}"
            "VOHIVE_DIR=${CMAKE_CURRENT_SOURCE_DIR}/third_party/vohive"
            /bin/sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/vohive_darwin_web_integration.sh"
    )
    set_tests_properties(vohive-darwin-web-integration PROPERTIES TIMEOUT 120)
endif()
