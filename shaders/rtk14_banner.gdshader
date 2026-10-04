shader_type spatial;
render_mode cull_disabled;
uniform sampler2D banner_texture : source_color, filter_linear_mipmap;
void vertex() {
    float weight = UV.x * UV.x;
    VERTEX.z += (sin(UV.x * 8.0 - TIME * 2.2) * 0.12 + sin(UV.y * 5.0 + TIME) * 0.04) * weight;
}
void fragment() {
    vec4 cloth = texture(banner_texture, UV);
    ALBEDO = cloth.rgb;
    ALPHA = cloth.a;
    ALPHA_SCISSOR_THRESHOLD = 0.4;
    ROUGHNESS = 0.98;
}
