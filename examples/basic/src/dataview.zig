const napi = @import("napi");

pub fn create_dataview(env: napi.Env) !napi.DataView {
    var view = try napi.DataView.New(env, 4);
    try view.setUint32(0, 0x12345678, true);
    return view;
}

pub fn get_dataview_length(view: napi.DataView) usize {
    return view.byteLength();
}

pub fn get_dataview_first_byte(view: napi.DataView) u8 {
    if (view.byteLength() == 0) {
        return 0;
    }
    return view.asConstSlice()[0];
}

pub fn get_dataview_uint32_le(view: napi.DataView) !u32 {
    return try view.getUint32(0, true);
}
