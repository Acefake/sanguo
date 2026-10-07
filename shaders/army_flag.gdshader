shader_type spatial;
render_mode cull_disabled;
uniform sampler2D symbol : filter_linear_mipmap, repeat_disable;
uniform vec4 faction_color : source_color = vec4(0.3,0.6,0.3,1.0);
varying vec2 cloth_uv;
void vertex() {
 // Map both cloth surfaces consistently; their original atlas UVs differ.
 cloth_uv = vec2((VERTEX.z + 0.86) / 1.45 + 0.5, (1.39 - VERTEX.y) / 1.45 + 0.5);
}
void fragment() {
 float paint = texture(symbol,cloth_uv).a;
 ALBEDO = mix(faction_color.rgb,vec3(0.97,0.94,0.84),paint);
 ROUGHNESS = 0.92;
}
