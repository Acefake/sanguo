shader_type canvas_item;
uniform sampler2D fade_wing : filter_linear;
uniform float edge_width = 0.09;

void fragment() {
	vec4 paper = texture(TEXTURE, UV);
	float edge = min(UV.x, 1.0 - UV.x);
	float opacity = 1.0;
	if (edge < edge_width) {
		// The original atlas contains the transparent-to-paper alpha ramp.
		opacity = clamp(texture(fade_wing, vec2(edge / edge_width * 0.72, 0.5)).a / 0.937, 0.0, 1.0);
	}
	COLOR = vec4(paper.rgb, paper.a * opacity);
}
