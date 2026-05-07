import { assertEqual } from "./assert";

type NativeAddon = ESObject;

export function testFunctionsAndClasses(native: NativeAddon) {
  assertEqual(native.basic_function(19, 23), 42, "basic_function");

  const createdFunction = native.create_function();
  assertEqual(createdFunction(19, 23), 42, "create_function");
  assertEqual(native.call_function((left: number, right: number) => left + right + 1), 4, "call_function");
  assertEqual(native.call_function_with_reference((left: number, right: number) => left * right), 2, "call_function_with_reference");

  const classValue = new native.TestClass("Lin", 9);
  assertEqual(classValue.name, "Lin", "class.name");
  assertEqual(classValue.age, 9, "class.age");

  assertEqual(native.TestWithInitClass.hello, "Hello", "class static value");
  const initClassValue = new native.TestWithInitClass(11, "Init");
  assertEqual(initClassValue.name, "Init", "class init.name");
  assertEqual(initClassValue.age, 11, "class init.age");

  assertEqual(native.TestWithoutInitClass.hello, "Hello", "class without init static value");

  const factoryClassValue = native.TestFactoryClass.initWithFactory(13, "Factory");
  assertEqual(factoryClassValue.name, "Factory", "class factory.name");
  assertEqual(factoryClassValue.age, 13, "class factory.age");
  assertEqual(factoryClassValue.format(), "TestFactory { name = Factory, age = 13 }", "class factory format");

  const constructedFactory = new native.TestFactoryClass("Ctor", 14);
  assertEqual(constructedFactory.name, "Ctor", "class factory constructor.name");
  assertEqual(constructedFactory.age, 14, "class factory constructor.age");
  assertEqual(constructedFactory.format(), "TestFactory { name = Ctor, age = 14 }", "class factory constructor format");
}
