# AnimalKingdom example

A modular app with one schema module and two feature modules, each with its own test mocks:

| Target | Module | Contains |
|---|---|---|
| `//graphql:AnimalKingdomAPI` | `AnimalKingdomAPI` | Schema types, generated from every `.graphql` file |
| `//Features/Pets:PetsGraphQL` | `PetsGraphQL` | Pets operations, and the `PetDetails` fragment |
| `//Features/Animals:AnimalsGraphQL` | `AnimalsGraphQL` | Animals operations; uses `PetDetails` from `PetsGraphQL` |
| `//graphql:AnimalKingdomAPIMocks` | `AnimalKingdomAPIMocks` | Mocks both features use, plus the `MockObject` typealiases |
| `//Features/Pets:PetsTestSupport` | `PetsTestSupport` | `Mutation` mock (only Pets references it) |
| `//Features/Animals:AnimalsTestSupport` | `AnimalsTestSupport` | Nothing. Animals alone selects `Height`, but the base's `Dog` mock names it, so the base owns it |

```sh
bazel test //...          # codegen, compile, link and run //App, the mock tests, the partition test
bazel run //graphql:mock_partition_test_update   # recompute the base mocks' types/exclude_types
bazel build //graphql:AnimalKingdomAPI_apollo --output_groups=operation_manifest
```

The GraphQL files are the AnimalKingdom fixture from
[apollo-ios](https://github.com/apollographql/apollo-ios) (MIT).
