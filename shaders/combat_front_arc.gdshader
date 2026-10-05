shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

uniform vec4 tint : source_color = vec4(0.72, 0.88, 1.0, 0.8);
uniform float phase = 0.0;
// Four terrain corners, relative to the formation's origin.
uniform vec4 ground_heights = vec4(0.0);
varying vec2 formation_point;

void vertex() {
 formation_point = VERTEX.xz * 1.45;
 vec2 corner = VERTEX.xz * 0.5 + 0.5;
 VERTEX.y = mix(mix(ground_heights.x, ground_heights.y, corner.x),
                mix(ground_heights.z, ground_heights.w, corner.x), corner.y) + 1.6;
}

void fragment() {
 float radius = length(formation_point);
 float angle = atan(formation_point.x, formation_point.y);
 float progress = clamp(phase / 0.68, 0.0, 1.0);
 float front = mix(0.48, 1.28, progress);
 float sector = 1.0 - smoothstep(0.85, 1.03, abs(angle));
 float arc_distance = abs(radius - front);
 float arc = (1.0 - smoothstep(0.024, 0.072, arc_distance)) * sector;
 float glow = exp(-arc_distance * 20.0) * sector * 0.3;
 float trails = 0.0;
 // Curved strokes originate inside the army and spread to its fighting edge.
 for (int branch = -1; branch <= 1; branch++) {
  float bend = float(branch) * (0.24 + radius * 0.46);
  float distance = abs(angle - bend) * max(radius, 0.2);
  float line = 1.0 - smoothstep(0.014, 0.046, distance);
  float length_mask = smoothstep(0.25, 0.45, radius) * (1.0 - smoothstep(front - 0.04, front + 0.02, radius));
  trails += line * length_mask * 0.65;
 }
 float fade = 1.0 - smoothstep(0.72, 1.0, phase);
 ALBEDO = tint.rgb;
 EMISSION = tint.rgb * 0.7;
 ALPHA = clamp(arc + glow + trails, 0.0, 1.0) * tint.a * fade;
}
