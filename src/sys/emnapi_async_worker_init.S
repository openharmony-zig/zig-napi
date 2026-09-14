// Copyright (c) 2022 Toyoaki Nakamura. MIT licensed, see emnapi's LICENSE.
//
// Worker entry-point prologue for the `@emnapi/core` async work pool, copied
// verbatim from emnapi's `src/thread/async_worker_init.S`.
//
// `emnapi_async_worker_init(void* arg)` takes the block that
// `emnapi_async_worker_create` (`src/sys/wasm.zig`) allocated and installs the
// worker's stack and TLS base from it, so every pooled worker runs on its own
// stack instead of sharing the module's single stack region:
//
//   struct worker_args { void* stack_base; void* tls_base; };
//
// It must stay frameless assembly. A function with a prologue saves the
// incoming `__stack_pointer` and its epilogue restores it, which undoes the
// switch and leaves the worker running on the parent's stack — concurrent
// workers then overwrite each other's frames and the module traps in
// `__stack_chk_fail`. emnapi shipped this object inside the `emnapi-basic-mt`
// archive, which emnapi v2 no longer publishes for WASI.

#ifdef __wasm64__
#define PTR i64
#else
#define PTR i32
#endif

  .text

  .export_name  emnapi_async_worker_init, emnapi_async_worker_init

  .globaltype  __stack_pointer, PTR
  .globaltype  __tls_base, PTR

  .hidden  emnapi_async_worker_init
  .globl  emnapi_async_worker_init
  .type  emnapi_async_worker_init,@function

emnapi_async_worker_init:
  .functype  emnapi_async_worker_init (PTR) -> ()

  local.get   0
  PTR.load    0
  global.set  __stack_pointer

  local.get   0
#ifdef __wasm64__
  PTR.load    8
#else
  PTR.load    4
#endif
  global.set  __tls_base

  end_function
