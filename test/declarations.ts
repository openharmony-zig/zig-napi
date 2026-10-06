import * as native from "../examples/basic/index";

const factory: native.ParityFactory = native.ParityFactory.create(42);
const factoryValue: number = native.parityFactoryInstance(factory);
// @ts-expect-error factories have no public constructor
new native.ParityFactory();
void factoryValue;
const counter = new native.MetadataCounter(42);
const count: number = counter.count;
const result: number = native.parityNamespaced(new native.parityTools.RenamedCounter(count));
// @ts-expect-error the public field is readonly
counter.count = result;
// @ts-expect-error the Zig field name is hidden
void counter.value;
// @ts-expect-error skipped fields are absent
void counter.secret;
const schema: native.parityTools.MetadataSchema = { count: result, missing: null };
const object = native.parityMetadataObject(schema);
// @ts-expect-error metadata applies to returned objects too
object.count = 1;
// @ts-expect-error nullable fields must retain their numeric type
native.parityMetadataObject({ count: 42, missing: "invalid" });
const tagged = native.parityTagged({ kind: "text", data: "owned" });
if (tagged.kind === "text") {
  const payload: string = tagged.data;
  void payload;
}
// @ts-expect-error tagged unions preserve their discriminant
native.parityTagged({ kind: "missing", data: "wrong" });
const iterator: IterableIterator<number> = native.parityIterator(3);
const asyncIterator: AsyncIterableIterator<number> = native.parityAsyncGenerator(3);
const iteration: Promise<IteratorResult<number>> = native.parityAsyncIteratorNext(asyncIterator);
const promise: Promise<number> = native.parityAwaitPromise(Promise.resolve(42));
const stream: ReadableStream<number> = native.parityNativeReadable(3);
const read: Promise<IteratorResult<number>> = native.parityRead(native.parityReadable(stream));
const weak = native.parityWeakClosure({});
weak();
const symbol: symbol = native.paritySymbolFor("registry");
type Assert<T extends true> = T;
type ZeroArgs = Assert<Parameters<typeof weak>["length"] extends 0 ? true : false>;
type TsfnReturn = Assert<
  ReturnType<Parameters<typeof native.parityTsfnAsync>[0]> extends number ? true : false
>;
void [iterator, iteration, promise, read, symbol];
export type DeclarationChecks = ZeroArgs | TsfnReturn;
