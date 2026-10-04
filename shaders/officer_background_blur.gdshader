shader_type canvas_item;

// Blur the original scene, retaining its colours behind the paper interface.
void fragment() {
	vec2 step_size = TEXTURE_PIXEL_SIZE * 7.0;
	vec4 colour = vec4(0.0);
	float total = 0.0;
	for (int x = -3; x <= 3; x++) {
		for (int y = -3; y <= 3; y++) {
			float weight = exp(-float(x*x + y*y) / 5.0);
			colour += texture(TEXTURE, clamp(UV + vec2(float(x), float(y)) * step_size, vec2(0.0), vec2(1.0))) * weight;
			total += weight;
		}
	}
	COLOR = vec4((colour.rgb / total) * 0.68, 1.0);
}
