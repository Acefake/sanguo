shader_type spatial;
render_mode cull_disabled;

uniform sampler2D native_albedo : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D native_normal : hint_normal, filter_linear_mipmap_anisotropic;

void fragment() {
	// Preserve the recovered UV atlas; lift its unusually dark diffuse values.
	vec3 color = texture(native_albedo, UV).rgb;
	ALBEDO = clamp(pow(color, vec3(0.48)) * 1.45, vec3(0.035), vec3(0.92));
	METALLIC = 0.72;
	ROUGHNESS = 0.34;
	NORMAL_MAP = texture(native_normal, UV).rgb;
	NORMAL_MAP_DEPTH = 0.45;
}
