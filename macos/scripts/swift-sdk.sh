#!/bin/zsh

# Sourced by the SwiftPM scripts so every build uses the same SDK selection.
leonbook_configure_swift_sdk() {
    local selected_sdk_path="${LEON_BOOK_SDK_PATH:-}"
    local default_sdk_version compatible_sdk_path

    if [[ -z "${selected_sdk_path}" ]]; then
        selected_sdk_path="$(xcrun --sdk macosx --show-sdk-path)"

        # CLT 27.0 omits the SwiftUIMacros plugin required by the new @State
        # macro. The retained 26.5 SDK still uses the compatible property wrapper.
        if [[ "${selected_sdk_path}" == */CommandLineTools/SDKs/* ]]; then
            default_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
            compatible_sdk_path="${selected_sdk_path:h}/MacOSX26.5.sdk"
            if [[ "${default_sdk_version}" == 27.0 && -d "${compatible_sdk_path}" ]]; then
                selected_sdk_path="${compatible_sdk_path}"
                print -- "[INFO] 使用 macOS 26.5 SDK，兼容 Command Line Tools 27.0 的 SwiftUI 构建。"
            fi
        fi
    fi

    SDK_ARGUMENTS=(--sdk "${selected_sdk_path}")
}

leonbook_configure_swift_sdk
