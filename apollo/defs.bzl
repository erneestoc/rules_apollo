"""Public API of rules_apollo."""

load("//apollo/private:operations.bzl", _apollo_operations = "apollo_operations")
load(
    "//apollo/private:providers.bzl",
    _ApolloCliInfo = "ApolloCliInfo",
    _ApolloOperationsInfo = "ApolloOperationsInfo",
    _ApolloSchemaInfo = "ApolloSchemaInfo",
    _ApolloTestMocksInfo = "ApolloTestMocksInfo",
)
load("//apollo/private:schema.bzl", _apollo_schema = "apollo_schema")
load(
    "//apollo/private:test_mocks.bzl",
    _apollo_mock_partition_test = "apollo_mock_partition_test",
    _apollo_mock_partition_update = "apollo_mock_partition_update",
    _apollo_test_mocks = "apollo_test_mocks",
)
load("//apollo/private:toolchain.bzl", _apollo_toolchain = "apollo_toolchain")

apollo_schema = _apollo_schema
apollo_operations = _apollo_operations
apollo_test_mocks = _apollo_test_mocks
apollo_mock_partition_test = _apollo_mock_partition_test
apollo_mock_partition_update = _apollo_mock_partition_update
apollo_toolchain = _apollo_toolchain

ApolloCliInfo = _ApolloCliInfo
ApolloSchemaInfo = _ApolloSchemaInfo
ApolloOperationsInfo = _ApolloOperationsInfo
ApolloTestMocksInfo = _ApolloTestMocksInfo
