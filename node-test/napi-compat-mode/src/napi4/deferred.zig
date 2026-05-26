const napi = @import("napi");

fn doubleExecute(input: i32) i32 {
    return input * 2;
}

pub fn doubleAsync(value: i32) napi.Async(i32, .single) {
    return napi.Async(i32, .single).from(value, doubleExecute);
}
