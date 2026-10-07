shader_type spatial;
render_mode cull_disabled;
uniform sampler2D albedo_texture : source_color, hint_default_white;
uniform vec4 tint : source_color = vec4(1.0);
uniform vec3 breach_center;
uniform vec3 breach_forward = vec3(0.0, 0.0, 1.0);
uniform float breach_width = 2.8;
uniform bool breach_open = true;
varying vec3 world_point;
void vertex() { world_point = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
 vec3 relative = world_point - breach_center;
 vec3 right = cross(vec3(0.0, 1.0, 0.0), breach_forward);
 if (breach_open && abs(dot(relative, right)) < breach_width * 0.5 && abs(dot(relative, breach_forward)) < 1.8 && relative.y > -0.4 && relative.y < 3.5) { discard; }
 vec4 surface = texture(albedo_texture, UV) * tint;
 ALBEDO = surface.rgb;
 ROUGHNESS = 0.88;
}
