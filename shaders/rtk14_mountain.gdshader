shader_type spatial;
render_mode cull_disabled;

uniform sampler2D source_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D source_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D source_parameters : filter_linear_mipmap, repeat_enable;
uniform bool has_normal = false;
uniform bool has_parameters = false;
varying float native_tangent_hand;

void vertex() {
    native_tangent_hand = COLOR.a * 2.0 - 1.0;
}

void fragment() {
    ALBEDO = texture(source_albedo, UV).rgb;
    if (has_normal) {
        vec3 ts = normalize(texture(source_normal, UV).rgb * 2.0 - 1.0);
        vec3 n = normalize(NORMAL);
        vec3 t = normalize(TANGENT);
        // PB2-Gbi uses the source binormal for X and source tangent for Y.
        // Native DXBC computes cross(tangent, normal), in this order.
        vec3 b = normalize(cross(t, n)) * native_tangent_hand;
        NORMAL = normalize(b * ts.x + t * ts.y + n * ts.z);
    }
    ROUGHNESS = 0.96;
    SPECULAR = 0.12;
    if (has_parameters) {
        vec4 parameters = texture(source_parameters, UV);
        ROUGHNESS = parameters.a;
        // Godot's scalar dielectric F0 approximates the original colored F0.
        SPECULAR = clamp(dot(parameters.rgb, vec3(0.333333)) / 0.08, 0.0, 1.0);
    }
}
