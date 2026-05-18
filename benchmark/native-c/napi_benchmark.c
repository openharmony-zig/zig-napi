#define _POSIX_C_SOURCE 199309L

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

#include "native_api.h"

static napi_value undefined_value(napi_env env) {
  napi_value result = NULL;
  napi_get_undefined(env, &result);
  return result;
}

static napi_value create_int32(napi_env env, int32_t value) {
  napi_value result = NULL;
  if (napi_create_int32(env, value, &result) != napi_ok) {
    return undefined_value(env);
  }
  return result;
}

static napi_value create_uint32(napi_env env, uint32_t value) {
  napi_value result = NULL;
  if (napi_create_uint32(env, value, &result) != napi_ok) {
    return undefined_value(env);
  }
  return result;
}

static napi_value create_double(napi_env env, double value) {
  napi_value result = NULL;
  if (napi_create_double(env, value, &result) != napi_ok) {
    return undefined_value(env);
  }
  return result;
}

static bool get_args(napi_env env, napi_callback_info info, size_t expected, napi_value* args) {
  size_t argc = expected;
  napi_value* argv = expected == 0 ? NULL : args;
  return napi_get_cb_info(env, info, &argc, argv, NULL, NULL) == napi_ok && argc >= expected;
}

static bool get_this_and_args(
    napi_env env,
    napi_callback_info info,
    size_t expected,
    napi_value* args,
    napi_value* this_arg) {
  size_t argc = expected;
  napi_value* argv = expected == 0 ? NULL : args;
  return napi_get_cb_info(env, info, &argc, argv, this_arg, NULL) == napi_ok && argc >= expected;
}

static napi_value bench_now_us(napi_env env, napi_callback_info info) {
  (void)info;
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
    return create_double(env, 0);
  }
  double us = ((double)ts.tv_sec * 1000000.0) + ((double)ts.tv_nsec / 1000.0);
  return create_double(env, us);
}

static napi_value napi_noop(napi_env env, napi_callback_info info) {
  (void)info;
  return undefined_value(env);
}

static napi_value napi_add_i32(napi_env env, napi_callback_info info) {
  napi_value args[2];
  if (!get_args(env, info, 2, args)) return undefined_value(env);

  int32_t left = 0;
  int32_t right = 0;
  if (napi_get_value_int32(env, args[0], &left) != napi_ok) return undefined_value(env);
  if (napi_get_value_int32(env, args[1], &right) != napi_ok) return undefined_value(env);
  return create_int32(env, left + right);
}

static napi_value napi_bool_identity(napi_env env, napi_callback_info info) {
  napi_value args[1];
  if (!get_args(env, info, 1, args)) return undefined_value(env);

  bool value = false;
  if (napi_get_value_bool(env, args[0], &value) != napi_ok) return undefined_value(env);

  napi_value result = NULL;
  if (napi_get_boolean(env, value, &result) != napi_ok) return undefined_value(env);
  return result;
}

static napi_value napi_string_len(napi_env env, napi_callback_info info) {
  napi_value args[1];
  if (!get_args(env, info, 1, args)) return undefined_value(env);

  size_t len = 0;
  if (napi_get_value_string_utf8(env, args[0], NULL, 0, &len) != napi_ok) {
    return undefined_value(env);
  }
  return create_uint32(env, (uint32_t)len);
}

static napi_value napi_object_read(napi_env env, napi_callback_info info) {
  napi_value args[1];
  if (!get_args(env, info, 1, args)) return undefined_value(env);

  napi_value count_value = NULL;
  napi_value flag_value = NULL;
  if (napi_get_named_property(env, args[0], "count", &count_value) != napi_ok) return undefined_value(env);
  if (napi_get_named_property(env, args[0], "flag", &flag_value) != napi_ok) return undefined_value(env);

  int32_t count = 0;
  bool flag = false;
  if (napi_get_value_int32(env, count_value, &count) != napi_ok) return undefined_value(env);
  if (napi_get_value_bool(env, flag_value, &flag) != napi_ok) return undefined_value(env);
  return create_int32(env, count + (flag ? 1 : 0));
}

static napi_value napi_array_sum(napi_env env, napi_callback_info info) {
  napi_value args[1];
  if (!get_args(env, info, 1, args)) return undefined_value(env);

  uint32_t len = 0;
  if (napi_get_array_length(env, args[0], &len) != napi_ok) return undefined_value(env);

  double total = 0;
  for (uint32_t i = 0; i < len; i++) {
    napi_value element = NULL;
    if (napi_get_element(env, args[0], i, &element) != napi_ok) return undefined_value(env);
    double value = 0;
    if (napi_get_value_double(env, element, &value) != napi_ok) return undefined_value(env);
    total += value;
  }
  return create_double(env, total);
}

static napi_value napi_call_function_bench(napi_env env, napi_callback_info info) {
  napi_value args[1];
  if (!get_args(env, info, 1, args)) return undefined_value(env);

  napi_value callback_args[2];
  callback_args[0] = create_int32(env, 19);
  callback_args[1] = create_int32(env, 23);

  napi_value this_arg = undefined_value(env);
  napi_value result = NULL;
  if (napi_call_function(env, this_arg, args[0], 2, callback_args, &result) != napi_ok) {
    return undefined_value(env);
  }
  return result;
}

static napi_value napi_new_arraybuffer(napi_env env, napi_callback_info info) {
  napi_value args[1];
  if (!get_args(env, info, 1, args)) return undefined_value(env);

  uint32_t len = 0;
  if (napi_get_value_uint32(env, args[0], &len) != napi_ok) return undefined_value(env);

  void* data = NULL;
  napi_value result = NULL;
  if (napi_create_arraybuffer(env, len, &data, &result) != napi_ok) return undefined_value(env);
  return result;
}

static napi_value napi_arraybuffer_length(napi_env env, napi_callback_info info) {
  napi_value args[1];
  if (!get_args(env, info, 1, args)) return undefined_value(env);

  void* data = NULL;
  size_t len = 0;
  if (napi_get_arraybuffer_info(env, args[0], &data, &len) != napi_ok) return undefined_value(env);
  return create_uint32(env, (uint32_t)len);
}

static napi_value napi_new_buffer(napi_env env, napi_callback_info info) {
  napi_value args[1];
  if (!get_args(env, info, 1, args)) return undefined_value(env);

  uint32_t len = 0;
  if (napi_get_value_uint32(env, args[0], &len) != napi_ok) return undefined_value(env);

  void* data = NULL;
  napi_value result = NULL;
  if (napi_create_buffer(env, len, &data, &result) != napi_ok) return undefined_value(env);
  return result;
}

static napi_value napi_buffer_length(napi_env env, napi_callback_info info) {
  napi_value args[1];
  if (!get_args(env, info, 1, args)) return undefined_value(env);

  void* data = NULL;
  size_t len = 0;
  if (napi_get_buffer_info(env, args[0], &data, &len) != napi_ok) return undefined_value(env);
  return create_uint32(env, (uint32_t)len);
}

static napi_value napi_new_uint8array(napi_env env, napi_callback_info info) {
  napi_value args[1];
  if (!get_args(env, info, 1, args)) return undefined_value(env);

  uint32_t len = 0;
  if (napi_get_value_uint32(env, args[0], &len) != napi_ok) return undefined_value(env);

  void* data = NULL;
  napi_value arraybuffer = NULL;
  if (napi_create_arraybuffer(env, len, &data, &arraybuffer) != napi_ok) return undefined_value(env);

  napi_value result = NULL;
  if (napi_create_typedarray(env, napi_uint8_array, len, arraybuffer, 0, &result) != napi_ok) {
    return undefined_value(env);
  }
  return result;
}

static napi_value napi_uint8array_sum(napi_env env, napi_callback_info info) {
  napi_value args[1];
  if (!get_args(env, info, 1, args)) return undefined_value(env);

  napi_typedarray_type type;
  size_t len = 0;
  void* data = NULL;
  napi_value arraybuffer = NULL;
  size_t byte_offset = 0;
  if (napi_get_typedarray_info(env, args[0], &type, &len, &data, &arraybuffer, &byte_offset) != napi_ok) {
    return undefined_value(env);
  }
  if (data == NULL) return undefined_value(env);

  const uint8_t* values = (const uint8_t*)data;
  uint32_t total = 0;
  for (size_t i = 0; i < len; i++) {
    total += values[i];
  }
  return create_uint32(env, total);
}

static napi_value napi_new_dataview(napi_env env, napi_callback_info info) {
  napi_value args[1];
  if (!get_args(env, info, 1, args)) return undefined_value(env);

  uint32_t len = 0;
  if (napi_get_value_uint32(env, args[0], &len) != napi_ok) return undefined_value(env);

  void* data = NULL;
  napi_value arraybuffer = NULL;
  if (napi_create_arraybuffer(env, len, &data, &arraybuffer) != napi_ok) return undefined_value(env);

  napi_value result = NULL;
  if (napi_create_dataview(env, len, arraybuffer, 0, &result) != napi_ok) return undefined_value(env);
  return result;
}

static napi_value napi_dataview_length(napi_env env, napi_callback_info info) {
  napi_value args[1];
  if (!get_args(env, info, 1, args)) return undefined_value(env);

  size_t len = 0;
  void* data = NULL;
  napi_value arraybuffer = NULL;
  size_t byte_offset = 0;
  if (napi_get_dataview_info(env, args[0], &len, &data, &arraybuffer, &byte_offset) != napi_ok) {
    return undefined_value(env);
  }
  return create_uint32(env, (uint32_t)len);
}

typedef struct {
  int32_t value;
} NapiBenchClassData;

static void napi_class_finalize(napi_env env, void* data, void* hint) {
  (void)env;
  (void)hint;
  free(data);
}

static NapiBenchClassData* unwrap_class(napi_env env, napi_value this_arg) {
  void* data = NULL;
  if (napi_unwrap(env, this_arg, &data) != napi_ok || data == NULL) return NULL;
  return (NapiBenchClassData*)data;
}

static napi_value napi_class_constructor(napi_env env, napi_callback_info info) {
  napi_value args[1];
  napi_value this_arg = NULL;
  if (!get_this_and_args(env, info, 1, args, &this_arg)) return NULL;

  int32_t value = 0;
  napi_get_value_int32(env, args[0], &value);

  NapiBenchClassData* instance = (NapiBenchClassData*)malloc(sizeof(NapiBenchClassData));
  if (instance == NULL) return NULL;
  instance->value = value;

  if (napi_wrap(env, this_arg, instance, napi_class_finalize, NULL, NULL) != napi_ok) {
    free(instance);
    return NULL;
  }
  return this_arg;
}

static napi_value napi_class_getter(napi_env env, napi_callback_info info) {
  napi_value this_arg = NULL;
  if (!get_this_and_args(env, info, 0, NULL, &this_arg)) return undefined_value(env);
  NapiBenchClassData* instance = unwrap_class(env, this_arg);
  if (instance == NULL) return undefined_value(env);
  return create_int32(env, instance->value);
}

static napi_value napi_class_setter(napi_env env, napi_callback_info info) {
  napi_value args[1];
  napi_value this_arg = NULL;
  if (!get_this_and_args(env, info, 1, args, &this_arg)) return undefined_value(env);
  NapiBenchClassData* instance = unwrap_class(env, this_arg);
  if (instance == NULL) return undefined_value(env);
  napi_get_value_int32(env, args[0], &instance->value);
  return undefined_value(env);
}

static napi_value napi_class_add(napi_env env, napi_callback_info info) {
  napi_value args[1];
  napi_value this_arg = NULL;
  if (!get_this_and_args(env, info, 1, args, &this_arg)) return undefined_value(env);
  NapiBenchClassData* instance = unwrap_class(env, this_arg);
  if (instance == NULL) return undefined_value(env);

  int32_t delta = 0;
  if (napi_get_value_int32(env, args[0], &delta) != napi_ok) return undefined_value(env);
  instance->value += delta;
  return create_int32(env, instance->value);
}

static napi_status define_function(napi_env env, napi_value exports, const char* name, napi_callback callback) {
  napi_value fn = NULL;
  napi_status status = napi_create_function(env, name, NAPI_AUTO_LENGTH, callback, NULL, &fn);
  if (status != napi_ok) return status;
  return napi_set_named_property(env, exports, name, fn);
}

static napi_status define_class(napi_env env, napi_value exports) {
  napi_property_descriptor properties[] = {
      {"value", NULL, NULL, napi_class_getter, napi_class_setter, NULL, napi_default, NULL},
      {"add", NULL, napi_class_add, NULL, NULL, NULL, napi_default, NULL},
  };

  napi_value constructor = NULL;
  napi_status status = napi_define_class(
      env,
      "NapiBenchClass",
      NAPI_AUTO_LENGTH,
      napi_class_constructor,
      NULL,
      sizeof(properties) / sizeof(properties[0]),
      properties,
      &constructor);
  if (status != napi_ok) return status;
  return napi_set_named_property(env, exports, "NapiBenchClass", constructor);
}

static napi_value init(napi_env env, napi_value exports) {
  define_function(env, exports, "bench_now_us", bench_now_us);
  define_function(env, exports, "napi_noop", napi_noop);
  define_function(env, exports, "napi_add_i32", napi_add_i32);
  define_function(env, exports, "napi_bool_identity", napi_bool_identity);
  define_function(env, exports, "napi_string_len", napi_string_len);
  define_function(env, exports, "napi_object_read", napi_object_read);
  define_function(env, exports, "napi_array_sum", napi_array_sum);
  define_function(env, exports, "napi_call_function", napi_call_function_bench);
  define_function(env, exports, "napi_new_arraybuffer", napi_new_arraybuffer);
  define_function(env, exports, "napi_arraybuffer_length", napi_arraybuffer_length);
  define_function(env, exports, "napi_new_buffer", napi_new_buffer);
  define_function(env, exports, "napi_buffer_length", napi_buffer_length);
  define_function(env, exports, "napi_new_uint8array", napi_new_uint8array);
  define_function(env, exports, "napi_uint8array_sum", napi_uint8array_sum);
  define_function(env, exports, "napi_new_dataview", napi_new_dataview);
  define_function(env, exports, "napi_dataview_length", napi_dataview_length);
  define_class(env, exports);
  return exports;
}

NAPI_MODULE(napi_benchmark, init)
