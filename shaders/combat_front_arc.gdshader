shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

uniform vec4 tint : source_color = vec4(0.95, 0.98, 1.0, 0.8);
uniform float phase = 0.0;
uniform sampler2D image : source_color, filter_linear_mipmap, repeat_disable;
// Four terrain corners, relative to the formation's origin.
uniform vec4 ground_heights = vec4(0.0);
varying vec2 fan_uv;

void vertex() {
 vec2 corner = VERTEX.xz * 0.5 + 0.5;
 float along = corner.y;
	fan_uv = vec2(corner.x, along);
 float swell = sin(clamp(phase / 0.68, 0.0, 1.0) * 3.14159265);
 VERTEX.x *= 0.9 + swell * 0.1;
 VERTEX.z = mix(-0.20, 1.15, along) + swell * 0.15;
 VERTEX.y = mix(mix(ground_heights.x, ground_heights.y, corner.x),
                mix(ground_heights.z, ground_heights.w, corner.x), corner.y)
                + 1.0 + sin(along * 3.14159265) * 0.4;
}

void fragment() {
 // Original white fan texture, opened in world space toward the contacted army.
 vec4 stroke = texture(image, fan_uv);
 float fade = 1.0 - smoothstep(0.72, 1.0, phase);
 ALBEDO = stroke.rgb * tint.rgb;
 EMISSION = stroke.rgb * tint.rgb * 1.3;
 ALPHA = stroke.a * tint.a * fade;
}
