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
// Contact facing, one set per formation material (army_world_3d/animation.gd _publish_facing).
// Yaws are world space, atan(x, z), up to 4 fronts; a set of 0 fronts means the formation's own +Z.
// Each soldier takes the front nearest its offset from formation_origin and turns from its heading
// in facing_from to the one in facing_goal at turn_rate (rad/s of animation_clock).
uniform vec4 facing_from = vec4(0.0);
uniform int facing_from_count = 0;
uniform vec4 facing_goal = vec4(0.0);
uniform int facing_goal_count = 0;
uniform float facing_at = -100.0;
uniform float turn_rate = 3.5;
uniform vec2 formation_origin = vec2(0.0);
// Feet center in model space: soldiers turn around it.
uniform vec3 pivot = vec3(0.0);

// Integer `%` and `/` by a uniform divisor are avoided throughout: llvmpipe's JIT emits an illegal
// instruction for them on CPUs without AVX, which takes down the GL compatibility renderer.
vec3 pose_sample(sampler2D atlas, int frame, int index) {
 int width = textureSize(atlas, 0).x;
 int row = int((float(index) + 0.5) / float(width));
 return texelFetch(atlas, ivec2(index - row * width, frame * pose_rows + row), 0).xyz;
}

// The yaw in `yaws` whose direction best matches `offset` (unit or zero), or `fallback` for an empty set.
float nearest_front(vec4 yaws, int count, vec2 offset, float fallback, out float score) {
 score = -2.0;
 float yaw = fallback;
 for (int k = 0; k < 4; k++) {
  if (k >= count) break;
  float s = dot(offset, vec2(sin(yaws[k]), cos(yaws[k])));
  if (s > score) { score = s; yaw = yaws[k]; }
 }
 return yaw;
}

vec3 turn_y(vec3 v, float angle) {
 float c = cos(angle);
 float s = sin(angle);
 return vec3(v.x * c + v.z * s, v.y, v.z * c - v.x * s);
}

void vertex() {
 uniform_height = pose_sample(pose_positions, 0, VERTEX_ID).y;
 if (mounted_palette) uniform_height = (uniform_height - 0.85) / 1.05;
 vec3 world_pivot = (MODEL_MATRIX * vec4(pivot, 1.0)).xyz;
 float formation_yaw = atan(MODEL_MATRIX[2].x, MODEL_MATRIX[2].z);
 vec2 offset = world_pivot.xz - formation_origin;
 offset = dot(offset, offset) > 1e-8 ? normalize(offset) : vec2(0.0);
 float score;
 float from_score;
 float goal = nearest_front(facing_goal, facing_goal_count, offset, formation_yaw, score);
 float start = nearest_front(facing_from, facing_from_count, offset, formation_yaw, from_score);
 float limit = turn_rate * max(animation_clock - facing_at, 0.0);
 float yaw = start + clamp(mod(goal - start + PI, TAU) - PI, -limit, limit);
 // How squarely this soldier stands on its front: rear ranks swing at partial strength.
 float weight = facing_goal_count > 0 ? clamp(score, 0.0, 1.0) : INSTANCE_CUSTOM.z;

 float frame = mod(animation_clock * pose_rate * (0.92 + INSTANCE_CUSTOM.y * 0.16) + INSTANCE_CUSTOM.x * float(pose_count), float(pose_count));
 int a = pose_start + int(floor(frame));
 int b = int(floor(frame)) + 1 < pose_count ? a + 1 : pose_start;
 float t = fract(frame);
 float activity = pose_start == 9 ? mix(0.45, 1.0, weight) : 1.0;
 vec3 animated_position = mix(pose_sample(pose_positions, a, VERTEX_ID), pose_sample(pose_positions, b, VERTEX_ID), t);
 vec3 animated_normal = normalize(mix(pose_sample(pose_normals, a, VERTEX_ID), pose_sample(pose_normals, b, VERTEX_ID), t));
 VERTEX = mix(pose_sample(pose_positions, 0, VERTEX_ID), animated_position, activity);
 NORMAL = normalize(mix(pose_sample(pose_normals, 0, VERTEX_ID), animated_normal, activity));
 if (animation_clock - transition_at < 0.18) {
 float previous_frame = mod(transition_at * previous_rate * (0.92 + INSTANCE_CUSTOM.y * 0.16) + INSTANCE_CUSTOM.x * float(previous_count), float(previous_count));
 int pa = previous_start + int(floor(previous_frame));
 int pb = int(floor(previous_frame)) + 1 < previous_count ? pa + 1 : previous_start;
 float previous_weight = previous_start == 9 ? mix(0.45, 1.0, weight) : 1.0;
 vec3 previous_position = mix(pose_sample(pose_positions, 0, VERTEX_ID), mix(pose_sample(pose_positions, pa, VERTEX_ID),pose_sample(pose_positions, pb, VERTEX_ID),fract(previous_frame)), previous_weight);
 vec3 previous_normal = mix(pose_sample(pose_normals, 0, VERTEX_ID), mix(pose_sample(pose_normals, pa, VERTEX_ID),pose_sample(pose_normals, pb, VERTEX_ID),fract(previous_frame)), previous_weight);
 float blend = smoothstep(0.0, 0.18, animation_clock - transition_at);
 VERTEX = mix(previous_position, VERTEX, blend);
 NORMAL = normalize(mix(previous_normal, NORMAL, blend));
 }
 float local_yaw = yaw - formation_yaw;
 VERTEX = turn_y(VERTEX - pivot, local_yaw) + pivot;
 NORMAL = turn_y(NORMAL, local_yaw);
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
