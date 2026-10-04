shader_type spatial;
render_mode cull_disabled;
uniform sampler2D wave_normal_0 : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D wave_normal_1 : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D shore_texture : filter_linear, repeat_disable;
uniform bool clip_to_shore = false;
// Period, flow and tint are reconstruction settings: native control points
// and whole-map runtime water material constants remain unresolved.
uniform vec2 wave_period = vec2(20.0, 20.0);
uniform vec2 flow_speed = vec2(0.03, 0.04);
uniform vec3 water_tint : source_color = vec3(0.20, 0.19, 0.17);
varying vec3 world_position;

vec3 unpack_wave(vec4 packed) {
    // SWATER DXBC reconstructs X from R*A and Y from G (DXT5nm).
    vec2 xy = vec2(packed.r * packed.a, packed.g) * 2.0 - 1.0;
    return vec3(xy.x, sqrt(max(0.0, 1.0 - dot(xy, xy))), xy.y);
}

void vertex() {
    world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
    if (clip_to_shore) {
        vec2 mask_uv = (world_position.xz + vec2(0.5)) / vec2(2049.0);
        if (texture(shore_texture, mask_uv).r < 0.45) discard;
    }
    vec2 uv = world_position.xz / wave_period;
    vec3 n0 = unpack_wave(texture(wave_normal_0, uv + vec2(0.0, TIME * flow_speed.x)));
    vec3 n1 = unpack_wave(texture(wave_normal_1, uv * vec2(1.0, 2.0) + vec2(0.0, TIME * flow_speed.y)));
    vec3 water_normal = normalize(n0 + n1);
    NORMAL = normalize((VIEW_MATRIX * vec4(water_normal, 0.0)).xyz);
    ALBEDO = water_tint;
    ROUGHNESS = 0.18;
    SPECULAR = 0.25;
}
