import AnimalKingdomAPI
import AnimalsGraphQL
import PetsGraphQL

// Types from three generated modules: operations, a fragment owned by another
// framework, and schema types.
print(AllAnimalsQuery.operationName)
print(PetDetails.fragmentDefinition.description.hasPrefix("fragment PetDetails"))
print(AnimalKingdomAPI.Objects.Dog.typename)
