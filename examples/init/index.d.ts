/**
 * Init example module for zig-napi
 * OpenHarmony/HarmonyNext native module written in Zig
 * Uses NODE_API_MODULE_WITH_INIT pattern
 */

// ============== Number Functions (pub exports) ==============

/**
 * Adds two 32-bit signed integers
 * @param left - The first integer
 * @param right - The second integer
 * @returns The sum of left and right
 */
export function test_i32(left: number, right: number): number;

/**
 * Adds two 32-bit floating-point numbers
 * @param left - The first float
 * @param right - The second float
 * @returns The sum of left and right
 */
export function test_f32(left: number, right: number): number;

/**
 * Adds two 32-bit unsigned integers
 * @param left - The first unsigned integer
 * @param right - The second unsigned integer
 * @returns The sum of left and right
 */
export function test_u32(left: number, right: number): number;

// ============== Init Exports ==============

/**
 * Adds two 64-bit floating-point numbers
 * @param left - The first number
 * @param right - The second number
 * @returns The sum of left and right
 */
export function add(left: number, right: number): number;

/**
 * Returns a greeting message
 * @param name - The name to greet
 * @returns A greeting string "Hello, {name}!"
 */
export function hello(name: string): string;

/**
 * A constant text string "Hello"
 */
export const text: string;

/**
 * Calculates fibonacci number asynchronously (fire and forget)
 * @param n - The fibonacci index
 */
export function fib(n: number): void;

/**
 * Calculates fibonacci number asynchronously with Promise
 * @param n - The fibonacci index
 * @returns A Promise that resolves when calculation is complete
 */
export function fib_async(n: number): Promise<void>;

/**
 * Takes an array of numbers and returns it
 * @param array - An array of numbers
 * @returns The same array
 */
export function get_and_return_array(array: number[]): number[];

/**
 * Takes a tuple array and returns it
 * @param array - A tuple of [number, boolean, string]
 * @returns The same tuple
 */
export function get_named_array(array: [number, boolean, string]): [number, boolean, string];

/**
 * Takes an ArrayList and returns it
 * @param array - An array of numbers
 * @returns The same array
 */
export function get_arraylist(array: number[]): number[];

/**
 * Throws a test error
 * @throws {Error} Always throws an error with reason "test"
 */
export function throw_error(): void;

// ============== Module Export ==============

declare const hello: {
  // Number (pub exports)
  test_i32: typeof test_i32;
  test_f32: typeof test_f32;
  test_u32: typeof test_u32;

  // Init exports
  add: typeof add;
  hello: typeof hello;
  text: typeof text;
  fib: typeof fib;
  fib_async: typeof fib_async;
  get_and_return_array: typeof get_and_return_array;
  get_named_array: typeof get_named_array;
  get_arraylist: typeof get_arraylist;
  throw_error: typeof throw_error;
};

export default hello;
