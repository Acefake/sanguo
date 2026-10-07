shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;
uniform sampler2D image : filter_linear, repeat_disable;
uniform float opacity = 0.0;
void fragment() {
	float core = pow(texture(image, UV).r, 2.0);
	float taper = smoothstep(0.0, 0.35, UV.y) * (1.0 - smoothstep(0.78, 1.0, UV.y));
	ALBEDO = vec3(0.93, 0.97, 1.0);
	ALPHA = core * taper * opacity;
}
