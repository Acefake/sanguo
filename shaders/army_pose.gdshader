shader_type spatial;
render_mode cull_disabled;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D pose_positions : filter_nearest, repeat_disable;
uniform sampler2D pose_normals : filter_nearest, repeat_disable;
uniform float animation_clock = 0.0;
uniform int pose_rows = 1;
uniform bool mounted_palette = false;
uniform bool reference_archer = false;
uniform vec4 cloth_color : source_color = vec4(0.73,0.65,0.39,1.0);
varying float uniform_height;
uniform int pose_start = 0;
uniform int pose_count = 1;
uniform float pose_rate = 0.0;
uniform int previous_start = 0;
uniform int previous_count = 1;
uniform float previous_rate = 0.0;
uniform float transition_at = -1.0;
vec3 pose_sample(sampler2D atlas, int frame, int index) {
 int width = textureSize(atlas, 0).x;
 return texelFetch(atlas, ivec2(index % width, frame * pose_rows + index / width), 0).xyz;
}
void vertex() {
 uniform_height = pose_sample(pose_positions, 0, VERTEX_ID).y;
 if (mounted_palette) uniform_height = (uniform_height - 0.85) / 1.05;
 float frame = mod(animation_clock * pose_rate * (0.92 + INSTANCE_CUSTOM.y * 0.16) + INSTANCE_CUSTOM.x * float(pose_count), float(pose_count));
 int a = pose_start + int(floor(frame));
 int b = pose_start + (int(floor(frame)) + 1) % pose_count;
 float t = fract(frame);
 float activity = pose_start == 9 ? mix(0.45, 1.0, INSTANCE_CUSTOM.z) : 1.0;
 vec3 animated_position = mix(pose_sample(pose_positions, a, VERTEX_ID), pose_sample(pose_positions, b, VERTEX_ID), t);
 vec3 animated_normal = normalize(mix(pose_sample(pose_normals, a, VERTEX_ID), pose_sample(pose_normals, b, VERTEX_ID), t));
 VERTEX = mix(pose_sample(pose_positions, 0, VERTEX_ID), animated_position, activity);
 NORMAL = normalize(mix(pose_sample(pose_normals, 0, VERTEX_ID), animated_normal, activity));
 if (animation_clock - transition_at < 0.18) {
 float previous_frame = mod(transition_at * previous_rate * (0.92 + INSTANCE_CUSTOM.y * 0.16) + INSTANCE_CUSTOM.x * float(previous_count), float(previous_count));
 int pa = previous_start + int(floor(previous_frame));
 int pb = previous_start + (int(floor(previous_frame)) + 1) % previous_count;
 float weight = previous_start == 9 ? mix(0.45, 1.0, INSTANCE_CUSTOM.z) : 1.0;
 vec3 previous_position = mix(pose_sample(pose_positions, 0, VERTEX_ID), mix(pose_sample(pose_positions, pa, VERTEX_ID),pose_sample(pose_positions, pb, VERTEX_ID),fract(previous_frame)), weight);
 vec3 previous_normal = mix(pose_sample(pose_normals, 0, VERTEX_ID), mix(pose_sample(pose_normals, pa, VERTEX_ID),pose_sample(pose_normals, pb, VERTEX_ID),fract(previous_frame)), weight);
 float blend = smoothstep(0.0, 0.18, animation_clock - transition_at);
 VERTEX = mix(previous_position, VERTEX, blend);
 NORMAL = normalize(mix(previous_normal, NORMAL, blend));
 }
}
void fragment() {
 vec4 tex = texture(albedo_texture, UV);
 ALBEDO = tex.rgb * COLOR.rgb;
 // Field uniforms use the reference's ochre cloth and red waist sash.
 // Horse coat and native texture detail remain sampled from the recovered atlas.
 if (reference_archer && UV.x < 0.5 && distance(COLOR.rgb,vec3(1.0)) > 0.1) {
  float light = dot(tex.rgb,vec3(0.299,0.587,0.114));
  ALBEDO = COLOR.rgb * (0.65 + light * 1.1);
 }
 if (!reference_archer && (!mounted_palette || (UV.x >= 0.5 && UV.y >= 0.5))) {
  float light = dot(tex.rgb,vec3(0.299,0.587,0.114));
  vec3 cloth = cloth_color.rgb * (0.55 + light * 2.0);
  // Keep native skin, armour, helmet and spear pixels readable. The previous
  // full-body 62% wash made the recovered UV texture look like plain clay.
  ALBEDO = mix(ALBEDO,cloth,0.12);
  float sash = smoothstep(0.93,0.97,uniform_height) * (1.0 - smoothstep(1.10,1.14,uniform_height));
  ALBEDO = mix(ALBEDO,vec3(0.40,0.065,0.033)*(0.7+light),sash*0.35);
 }
 ROUGHNESS = 0.82;
 METALLIC = 0.08;
}
