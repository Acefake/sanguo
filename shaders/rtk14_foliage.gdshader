shader_type spatial;
render_mode cull_disabled, diffuse_burley, alpha_to_coverage;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool has_normal = false;
uniform float wind_strength = 0.025;
uniform float bend_height = 5.0;
void vertex() {
    vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    float weight = smoothstep(0.05, bend_height, VERTEX.y);
    VERTEX.x += sin(TIME * 1.1 + world.x * 0.13 + world.z * 0.17) * weight * wind_strength;
    VERTEX.z += cos(TIME * 0.8 + world.x * 0.11) * weight * wind_strength * 0.7;
}
void fragment() {
    vec4 leaf = texture(albedo_texture, UV);
    ALBEDO = leaf.rgb;
    ALPHA = leaf.a;
    ALPHA_SCISSOR_THRESHOLD = 0.35;
    ALPHA_ANTIALIASING_EDGE = 0.3;
    ALPHA_TEXTURE_COORDINATE = UV * vec2(textureSize(albedo_texture, 0));
    ROUGHNESS = 0.9;
    SPECULAR = 0.18;
    if (has_normal) { NORMAL_MAP = texture(normal_texture, UV).rgb; NORMAL_MAP_DEPTH = 0.6; }
    BACKLIGHT = leaf.rgb * 0.12;
}
