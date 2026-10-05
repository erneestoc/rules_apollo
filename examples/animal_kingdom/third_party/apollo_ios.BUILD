load("@build_bazel_rules_swift//swift:swift_library.bzl", "swift_library")

_SWIFT_6 = ["-swift-version", "6"]

# Apollo uses `package` access across its modules, as in its Package.swift.

swift_library(
    name = "ApolloAPI",
    srcs = glob(["Sources/ApolloAPI/**/*.swift"]),
    copts = _SWIFT_6,
    package_name = "apollo-ios",
    module_name = "ApolloAPI",
    visibility = ["//visibility:public"],
)

swift_library(
    name = "Apollo",
    srcs = glob(["Sources/Apollo/**/*.swift"]),
    copts = _SWIFT_6,
    package_name = "apollo-ios",
    module_name = "Apollo",
    visibility = ["//visibility:public"],
    deps = [":ApolloAPI"],
)

swift_library(
    name = "ApolloTestSupport",
    testonly = True,
    srcs = glob(["Sources/ApolloTestSupport/**/*.swift"]),
    copts = _SWIFT_6,
    package_name = "apollo-ios",
    module_name = "ApolloTestSupport",
    visibility = ["//visibility:public"],
    deps = [
        ":Apollo",
        ":ApolloAPI",
    ],
)
