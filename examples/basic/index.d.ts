/**
 * Basic example module for zig-napi
 * OpenHarmony/HarmonyNext native module written in Zig
 */

// ============== Number Functions ==============

/**
 * Adds two 32-bit signed integers
 * @param left - The first integer
 * @param right - The second integer
 * @returns The sum of left and right
 */
export declare function test_i32(left: number, right: number): number;

/**
 * Adds two 32-bit floating-point numbers
 * @param left - The first float
 * @param right - The second float
 * @returns The sum of left and right
 */
export declare function test_f32(left: number, right: number): number;

/**
 * Adds two 32-bit unsigned integers
 * @param left - The first unsigned integer
 * @param right - The second unsigned integer
 * @returns The sum of left and right
 */
export declare function test_u32(left: number, right: number): number;

// ============== String Functions ==============

/**
 * Returns a greeting message
 * @param name - The name to greet
 * @returns A greeting string "Hello, {name}!"
 */
export declare function hello(name: string): string;

/**
 * A constant text string
 */
export declare const text: string;

// ============== Error Functions ==============

/**
 * Throws a test error
 * @throws {Error} Always throws an error with reason "test"
 */
export declare function throw_error(): void;

// ============== Worker Functions ==============

/**
 * Calculates fibonacci number asynchronously (fire and forget)
 * @param n - The fibonacci index
 */
export declare function fib(n: number): void;

/**
 * Calculates fibonacci number asynchronously with Promise
 * @param n - The fibonacci index
 * @returns A Promise that resolves when calculation is complete
 */
export declare function fib_async(n: number): Promise<void>;

// ============== Array Functions ==============

/**
 * Takes an array and returns it
 * @param array - An array of numbers
 * @returns The same array
 */
export declare function get_and_return_array(array: number[]): number[];

/**
 * Takes a tuple array and returns it
 * @param array - A tuple of [number, boolean, string]
 * @returns The same tuple
 */
export declare function get_named_array(
  array: [number, boolean, string]
): [number, boolean, string];

/**
 * Takes an ArrayList and returns it
 * @param array - An array of numbers
 * @returns The same array
 */
export declare function get_arraylist(array: number[]): number[];

// ============== Object Types ==============

/**
 * Full field object with all required fields
 */
export interface FullField {
  name: string;
  age: number;
  is_student: boolean;
}

/**
 * Object with optional fields
 */
export interface OptionalField {
  name: string;
  age?: number;
  is_student?: boolean;
}

/**
 * Object with nullable field
 */
export interface NullableField {
  name: string | null;
}

// ============== Object Functions ==============

/**
 * Takes a full field object and returns it
 * @param config - Object with name, age, and is_student
 * @returns The same object
 */
export declare function get_object(config: FullField): FullField;

/**
 * Takes an object with optional fields
 * @param config - Object with name (required), age and is_student (optional)
 * @returns Object with default values applied (age: 18, is_student: true)
 */
export declare function get_object_optional(
  config: OptionalField
): OptionalField;

/**
 * Takes an optional object and returns it
 * @param config - Object with optional fields
 * @returns The same object
 */
export declare function get_optional_object_and_return_optional(
  config: OptionalField
): OptionalField;

/**
 * Takes an object with nullable name field
 * @param config - Object with nullable name
 * @returns The same object
 */
export declare function get_nullable_object(
  config: NullableField
): NullableField;

/**
 * Returns a nullable object with null name
 * @returns Object with name set to null
 */
export declare function return_nullable(): NullableField;

// ============== Function Types ==============

/**
 * Callback function type that takes two numbers and returns a number
 */
export type CallbackFunction = (arg0: number, arg1: number) => number;

// ============== Function Functions ==============

/**
 * Calls the provided callback function with (1, 2)
 * @param cb - A callback function that takes two numbers and returns a number
 * @returns The result of calling cb(1, 2)
 */
export declare function call_function(cb: CallbackFunction): number;

/**
 * Adds two numbers
 * @param left - The first number
 * @param right - The second number
 * @returns The sum of left and right
 */
export declare function basic_function(left: number, right: number): number;

/**
 * Creates a new function that wraps basic_function
 * @returns A function that adds two numbers
 */
export declare function create_function(): CallbackFunction;

/**
 * Creates a native reference to the callback, reads it back, and calls it with (1, 2)
 * @param cb - A callback function that takes two numbers and returns a number
 * @returns The result of calling cb(1, 2)
 */
export declare function call_function_with_reference(cb: CallbackFunction): number;

// ============== Thread Safe Function ==============

/**
 * Calls the thread safe function from multiple threads
 * @param tsfn - A thread-safe callback function
 */
export declare function call_thread_safe_function(tsfn: CallbackFunction): void;

// ============== Class Types ==============

/**
 * Basic test class with name and age properties
 */
export declare class TestClass {
  constructor(name: string, age: number);
  name: string;
  age: number;
}

/**
 * Test class with custom init function
 * Constructor takes (age, name) instead of field order
 */
export declare class TestWithInitClass {
  constructor(age: number, name: string);
  name: string;
  age: number;
  static readonly hello: string;
}

/**
 * Test class without constructor (abstract-like)
 */
export declare class TestWithoutInitClass {
  private constructor();
  name: string;
  age: number;
  static readonly hello: string;
}

/**
 * Test class with factory method
 */
export declare class TestFactoryClass {
  constructor(age: number, name: string);
  name: string;
  age: number;
  /**
   * Formats the object as a string
   * @returns Formatted string representation
   */
  format(): string;
}

// ============== Log Functions ==============

/**
 * Tests hilog functionality (OpenHarmony logging)
 */
export declare function test_hilog(): void;

// ============== Buffer Functions ==============

/**
 * Creates a new buffer
 * @param size - The size of the buffer
 * @returns The new buffer
 */
export declare function create_buffer(): ArrayBuffer;

/**
 * Gets the buffer length
 * @param buffer - The buffer
 * @returns The buffer length
 */
export declare function get_buffer(buffer: ArrayBuffer): number;

/**
 * Gets the buffer as a string
 * @param buffer - The buffer
 * @returns The buffer as a string
 */
export declare function get_buffer_as_string(buffer: ArrayBuffer): string;

// ============== ArrayBuffer Functions ==============

/**
 * Creates a new array buffer
 * @param size - The size of the array buffer
 * @returns The new array buffer
 */
export declare function create_arraybuffer(): ArrayBuffer;

/**
 * Gets the array buffer length
 * @param arraybuffer - The array buffer
 * @returns The array buffer length
 */
export declare function get_arraybuffer(arraybuffer: ArrayBuffer): number;

/**
 * Gets the array buffer as a string
 * @param arraybuffer - The array buffer
 * @returns The array buffer as a string
 */
export declare function get_arraybuffer_as_string(
  arraybuffer: ArrayBuffer
): string;

// ============== TypedArray Functions ==============

/**
 * Creates a Uint8Array with 4 bytes: [1, 2, 3, 4]
 * @returns The created typed array
 */
export declare function create_uint8_typedarray(): Uint8Array;

/**
 * Gets the length of a Uint8Array
 * @param array - The typed array
 * @returns The element count
 */
export declare function get_uint8_typedarray_length(array: Uint8Array): number;

/**
 * Sums all items in a Float32Array
 * @param array - The typed array
 * @returns The sum of all elements
 */
export declare function sum_float32_typedarray(array: Float32Array): number;

// ============== DataView Functions ==============

/**
 * Creates a DataView with 4 bytes initialized to 0x78, 0x56, 0x34, 0x12
 * @returns The created data view
 */
export declare function create_dataview(): DataView;

/**
 * Gets the byte length of a DataView
 * @param view - The data view
 * @returns The byte length
 */
export declare function get_dataview_length(view: DataView): number;

/**
 * Gets the first byte of a DataView
 * @param view - The data view
 * @returns The first byte, or 0 if empty
 */
export declare function get_dataview_first_byte(view: DataView): number;

/**
 * Reads the first 4 bytes of a DataView as a little-endian uint32
 * @param view - The data view
 * @returns The uint32 value
 */
export declare function get_dataview_uint32_le(view: DataView): number;
